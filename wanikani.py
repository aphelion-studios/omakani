#!/usr/bin/env python3
"""WaniKani bridge for the io.github.aphelion-studios.omawanikani Omarchy plugin.

Every subcommand prints exactly one JSON object on stdout and exits 0, even when
WaniKani refuses the call, so the QML side has a single shape to parse and only
has to look at ``ok`` / ``error``. The API token is read here -- from a 0600
config file or ``$WANIKANI_API_TOKEN`` -- and never travels through argv, where
``ps`` would show it to every user on the machine.

Two read commands:

* ``summary``   -- cheap. One ``/user`` + one ``/summary``. The counts, the
                   next-review countdown, vacation state. Safe to poll often.
* ``dashboard`` -- syncs the on-disk caches of subjects / assignments / review
                   statistics / level progressions (delta fetches via
                   ``updated_after`` once warm) and derives the whole dashboard:
                   Item Spread, Level Progress, Upcoming Reviews, Critical
                   Condition, recent unlocks / burns, Extra Study counts.

Usable by hand while developing the plugin::

    ./wanikani.py summary | jq
    ./wanikani.py dashboard | jq
    printf '%s\\n' "$TOKEN" | ./wanikani.py set-token
    ./wanikani.py clear-token
"""

from __future__ import annotations

import argparse
import http.client
import json
import math
import os
import socket
import ssl
import sys
import time
import urllib.parse
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from time import monotonic

HOST = "api.wanikani.com"
API_BASE = "/v2"
API_ROOT = "https://" + HOST + API_BASE
API_REVISION = "20170710"
USER_AGENT = "omarchy-omawanikani/0.2"
TIMEOUT = 10
# Ceiling for one call including its failover attempts.
DEADLINE = 30

# Bump when the cached record shape changes so stale caches are refetched.
CACHE_VERSION = 2

UPCOMING_DAYS = 5
CRITICAL_THRESHOLD = 75          # percentage_correct below this -> critical
RECENT_WINDOW_DAYS = 30
RECENT_LIST_CAP = 30
CRITICAL_LIST_CAP = 60

# SRS stage -> Item Spread bucket. Stage 0 (not started) is left out.
SPREAD_BUCKETS = {
    1: "apprentice", 2: "apprentice", 3: "apprentice", 4: "apprentice",
    5: "guru", 6: "guru",
    7: "master",
    8: "enlightened",
    9: "burned",
}
TYPE_KEYS = {"radical": "radicals", "kanji": "kanji",
             "vocabulary": "vocabulary", "kana_vocabulary": "vocabulary"}


class ApiError(Exception):
    """A WaniKani call that failed in a way worth showing the user."""

    def __init__(self, message, code=None):
        super().__init__(message)
        self.code = code


# ----------------------------------------------------------------- config

def config_path():
    base = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base) / "omarchy" / "wanikani.json"


def cache_dir():
    base = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(base) / "omawanikani"


def load_config():
    try:
        with open(config_path(), encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def save_config(config):
    path = config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    # 0600 from creation, not after: the token it holds can read every
    # assignment in the account and, with write scopes, move real SRS state.
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(config, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(temporary, path)
    os.chmod(path, 0o600)


def api_token(config):
    return str(config.get("apiToken") or os.environ.get("WANIKANI_API_TOKEN") or "").strip()


# ------------------------------------------------------------------- cache

def load_cache(name):
    try:
        with open(cache_dir() / (name + ".json"), encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def save_cache(name, payload):
    directory = cache_dir()
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / (name + ".json")
    temporary = path.with_name(path.name + ".tmp")
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, separators=(",", ":"))
    os.replace(temporary, path)


def wipe_cache():
    directory = cache_dir()
    for name in ("subjects", "assignments", "review_stats", "level_progressions"):
        try:
            (directory / (name + ".json")).unlink()
        except OSError:
            pass


# -------------------------------------------------------------------- http

class Api:
    """HTTP/1.1 client for one run of one subcommand.

    Not urllib: api.wanikani.com sits behind Cloudflare and resolves to several
    addresses; a network that cannot reach one of them gets a connection that
    opens and then answers nothing. So we resolve the host ourselves, fail over
    to the next address when one stops answering, and keep the connection that
    worked for the rest of the run.
    """

    def __init__(self, token):
        self.token = token
        self.addresses = self._resolve()
        self.connection = None
        self.address = None
        self.requests = 0

    @staticmethod
    def _resolve():
        try:
            infos = socket.getaddrinfo(HOST, 443, socket.AF_UNSPEC, socket.SOCK_STREAM)
        except OSError as error:
            raise ApiError("Could not resolve %s: %s" % (HOST, error)) from error
        ordered = []
        for info in infos:
            address = (info[0], info[4])
            if address not in ordered:
                ordered.append(address)
        if not ordered:
            raise ApiError("Could not resolve %s" % HOST)
        return ordered

    def _open(self, family, sockaddr):
        raw = socket.socket(family, socket.SOCK_STREAM)
        raw.settimeout(TIMEOUT)
        raw.connect(sockaddr)
        context = ssl.create_default_context()
        secure = context.wrap_socket(raw, server_hostname=HOST)
        connection = http.client.HTTPSConnection(HOST, 443, timeout=TIMEOUT)
        connection.sock = secure
        return connection

    def _close(self):
        if self.connection is not None:
            try:
                self.connection.close()
            except OSError:
                pass
        self.connection = None

    def get(self, path, _retry=True):
        """GET a path under /v2 (leading slash, may carry a query string)."""
        headers = {
            "Authorization": "Bearer " + self.token,
            "Wanikani-Revision": API_REVISION,
            "Accept": "application/json",
            "User-Agent": USER_AGENT,
        }
        candidates = []
        if self.address is not None:
            candidates.append(self.address)
        candidates.extend(a for a in self.addresses if a != self.address)

        failure = None
        expiry = monotonic() + DEADLINE
        while candidates and monotonic() < expiry:
            candidate = candidates.pop(0)
            reused = self.connection is not None and self.address == candidate
            try:
                if not reused:
                    self._close()
                    self.connection = self._open(*candidate)
                    self.address = candidate
                self.connection.request("GET", API_BASE + path, None, headers)
                response = self.connection.getresponse()
                raw = response.read().decode("utf-8", "replace")
            except (OSError, http.client.HTTPException) as error:
                self._close()
                failure = error
                if reused and not is_timeout(error):
                    candidates.insert(0, candidate)
                continue

            self.requests += 1
            if response.status == 429 and _retry:
                delay = response.getheader("Retry-After")
                try:
                    delay = max(1, min(15, int(delay)))
                except (TypeError, ValueError):
                    delay = 2
                time.sleep(delay)
                return self.get(path, _retry=False)
            return decode(response.status, raw)

        raise ApiError("WaniKani did not answer (%s)" % describe(failure))

    def collection(self, path):
        """Follow pages.next_url and return (items, data_updated_at)."""
        items = []
        stamp = None
        cursor = path
        while cursor:
            body = self.get(cursor) or {}
            stamp = body.get("data_updated_at") or stamp
            items.extend(body.get("data") or [])
            nxt = ((body.get("pages") or {}).get("next_url")) or ""
            cursor = nxt[len(API_ROOT):] if nxt.startswith(API_ROOT) else None
        return items, stamp


def is_timeout(error):
    return isinstance(error, (TimeoutError, socket.timeout))


def describe(error):
    if error is None:
        return "no route answered"
    if is_timeout(error):
        return "timed out after %ds" % TIMEOUT
    return str(error) or error.__class__.__name__


def decode(status, raw):
    if status == 401:
        raise ApiError("WaniKani rejected the API token", 401)
    if status == 429:
        raise ApiError("WaniKani rate limit reached, try again shortly", 429)
    if status >= 400:
        detail = ""
        try:
            parsed = json.loads(raw)
            if isinstance(parsed, dict):
                detail = str(parsed.get("error") or "").strip()
        except ValueError:
            detail = ""
        raise ApiError(detail or ("WaniKani returned HTTP %d" % status), status)
    if not raw.strip():
        return None
    try:
        return json.loads(raw)
    except ValueError as error:
        raise ApiError("Could not parse the WaniKani response") from error


def slim_subject(resource):
    """Keep only the subject fields the dashboard reads. The full record (with
    every mnemonic and audio URL) is ~25 MB across ~9k rows; the dashboard needs
    a fiftieth of that. Phase 4 (lessons / reviews) will want the rest."""
    data = resource.get("data") or {}
    return {
        "id": resource.get("id"),
        "object": resource.get("object"),
        "data": {
            "characters": data.get("characters"),
            "slug": data.get("slug"),
            "meanings": data.get("meanings"),
            "level": data.get("level"),
            "document_url": data.get("document_url"),
            "hidden_at": data.get("hidden_at"),
        },
    }


def sync_collection(api, name, path, transform=None):
    """Delta-sync a collection into its cache, return (items_by_id, was_cold).

    The cache dict is keyed by stringified id (JSON object keys are strings);
    callers that look up by numeric id should re-key on the way out.
    """
    cache = load_cache(name)
    if cache.get("v") != CACHE_VERSION:
        cache = {}
    items = cache.get("items")
    items = dict(items) if isinstance(items, dict) else {}
    was_cold = not items
    since = cache.get("data_updated_at")

    query = path
    if since:
        joiner = "&" if "?" in query else "?"
        query = query + joiner + "updated_after=" + urllib.parse.quote(since)

    fresh, stamp = api.collection(query)
    for resource in fresh:
        rid = resource.get("id")
        if rid is not None:
            items[str(rid)] = transform(resource) if transform else resource

    save_cache(name, {"v": CACHE_VERSION, "data_updated_at": stamp or since, "items": items})
    return {resource.get("id"): resource for resource in items.values()}, was_cold


# --------------------------------------------------------------------- time

def now_utc():
    return datetime.now(timezone.utc)


def local_now():
    return now_utc().astimezone()


def parse_stamp(value):
    text = str(value or "").strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        moment = datetime.fromisoformat(text)
    except ValueError:
        return None
    return moment if moment.tzinfo else moment.replace(tzinfo=timezone.utc)


def local_stamp(value):
    moment = parse_stamp(value)
    return moment.astimezone() if moment else None


def iso(moment):
    if moment is None:
        return ""
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def hour_label(hour):
    suffix = "AM" if hour < 12 else "PM"
    twelve = hour % 12 or 12
    return "%d %s" % (twelve, suffix)


# ---------------------------------------------------------------- derive

def data_of(resource):
    return (resource or {}).get("data") or {}


def type_key(obj):
    return TYPE_KEYS.get(obj or "", "vocabulary")


def subject_row(subject, subject_id, at=""):
    data = data_of(subject)
    meanings = data.get("meanings") or []
    primary = next((m.get("meaning") for m in meanings if m.get("primary")),
                   meanings[0].get("meaning") if meanings else "")
    return {
        "id": subject_id,
        "type": type_key((subject or {}).get("object")),
        "characters": data.get("characters") or "",
        "meaning": primary or "",
        "level": data.get("level") or 0,
        "url": data.get("document_url") or "",
        "at": at,
    }


def item_spread(assignments):
    spread = {bucket: {"radicals": 0, "kanji": 0, "vocabulary": 0}
              for bucket in ("apprentice", "guru", "master", "enlightened", "burned")}
    for assignment in assignments:
        data = data_of(assignment)
        if data.get("hidden"):
            continue
        bucket = SPREAD_BUCKETS.get(data.get("srs_stage") or 0)
        if not bucket:
            continue
        spread[bucket][type_key(data.get("subject_type"))] += 1
    return spread


def level_progress(subjects_by_id, assignment_by_subject, level):
    progress = {key: {"passed": 0, "total": 0}
                for key in ("radicals", "kanji", "vocabulary")}
    for subject in subjects_by_id.values():
        data = data_of(subject)
        if data.get("level") != level or data.get("hidden_at"):
            continue
        key = type_key(subject.get("object"))
        progress[key]["total"] += 1
        assignment = assignment_by_subject.get(subject.get("id"))
        if (data_of(assignment).get("srs_stage") or 0) >= 5:
            progress[key]["passed"] += 1
    kanji = progress["kanji"]
    threshold = math.ceil(kanji["total"] * 0.9)
    progress["kanjiToLevelUp"] = max(0, threshold - kanji["passed"])
    return progress


def projected_level_up(level_progressions, level):
    durations = []
    current_started = None
    for progression in level_progressions:
        data = data_of(progression)
        started = parse_stamp(data.get("started_at"))
        passed = parse_stamp(data.get("passed_at"))
        if data.get("level") == level and started:
            current_started = started
        if started and passed and passed > started:
            durations.append((passed - started).total_seconds())
    if not current_started or not durations:
        return ""
    durations.sort()
    median = durations[len(durations) // 2]
    return iso(current_started + timedelta(seconds=median))


def upcoming_reviews(assignments, reviews_now):
    now = local_now()
    today = now.date()
    horizon = today + timedelta(days=UPCOMING_DAYS)

    by_day = defaultdict(list)
    for assignment in assignments:
        data = data_of(assignment)
        stage = data.get("srs_stage") or 0
        if stage < 1 or stage > 8 or data.get("hidden"):
            continue
        moment = local_stamp(data.get("available_at"))
        if not moment or moment <= now or moment.date() >= horizon:
            continue
        by_day[moment.date()].append(moment)

    cumulative = reviews_now
    days = []
    day = today
    while day < horizon:
        moments = sorted(by_day.get(day, []))
        by_hour = defaultdict(int)
        for moment in moments:
            by_hour[moment.hour] += 1
        running = cumulative
        hours = []
        for hour in sorted(by_hour):
            running += by_hour[hour]
            hours.append({"hour": hour, "label": hour_label(hour),
                          "count": by_hour[hour], "cumulative": running})
        cumulative += len(moments)
        days.append({
            "date": day.isoformat(),
            "label": day.strftime("%a"),
            "labelLong": day.strftime("%A"),
            "count": len(moments),
            "cumulative": cumulative,
            "hours": hours,
        })
        day += timedelta(days=1)
    return days


def recent_items(assignments, subjects_by_id, field):
    cutoff = local_now() - timedelta(days=RECENT_WINDOW_DAYS)
    rows = []
    for assignment in assignments:
        moment = local_stamp(data_of(assignment).get(field))
        if not moment or moment < cutoff:
            continue
        rows.append((moment, data_of(assignment).get("subject_id")))
    rows.sort(reverse=True)
    return [subject_row(subjects_by_id.get(sid), sid, iso(moment))
            for moment, sid in rows[:RECENT_LIST_CAP]]


def critical_condition(review_stats, assignment_by_subject, subjects_by_id):
    rows = []
    for stat in review_stats:
        data = data_of(stat)
        if data.get("hidden"):
            continue
        percentage = data.get("percentage_correct")
        if percentage is None or percentage >= CRITICAL_THRESHOLD:
            continue
        subject_id = data.get("subject_id")
        stage = data_of(assignment_by_subject.get(subject_id)).get("srs_stage") or 0
        if stage < 1 or stage > 8:
            continue
        row = subject_row(subjects_by_id.get(subject_id), subject_id)
        row["percentage"] = percentage
        rows.append(row)
    rows.sort(key=lambda row: row["percentage"])
    return rows[:CRITICAL_LIST_CAP]


def extra_study(assignments):
    recent_lessons = []
    burned = 0
    for assignment in assignments:
        data = data_of(assignment)
        if data.get("burned_at"):
            burned += 1
        if data.get("started_at") and not data.get("passed_at"):
            recent_lessons.append(data.get("subject_id"))
    return {
        "recentLessons": len(recent_lessons),
        "recentLessonIds": recent_lessons,
        "burnedItems": burned,
        "recentMistakes": None,          # phase 2e
    }


# ------------------------------------------------------------------ payload

def base_summary():
    return {
        "ok": True,
        "configured": False,
        "error": "",
        "note": "",
        "username": "",
        "level": 0,
        "vacation": False,
        "reviewsNow": 0,
        "lessonsNow": 0,
        "nextReviewsAt": "",
        "fetchedAt": "",
    }


def summarize(config, api):
    user = data_of(api.get("/user"))
    summary = data_of(api.get("/summary"))
    now = now_utc()

    lessons_now = 0
    for bucket in summary.get("lessons") or []:
        at = parse_stamp(bucket.get("available_at"))
        if at is None or at <= now:
            lessons_now += len(bucket.get("subject_ids") or [])

    reviews_now = 0
    for bucket in summary.get("reviews") or []:
        at = parse_stamp(bucket.get("available_at"))
        if at is None or at <= now:
            reviews_now += len(bucket.get("subject_ids") or [])

    payload = base_summary()
    payload.update({
        "configured": True,
        "username": str(user.get("username") or ""),
        "level": int(user.get("level") or 0),
        "vacation": user.get("current_vacation_started_at") is not None,
        "reviewsNow": reviews_now,
        "lessonsNow": lessons_now,
        "nextReviewsAt": "" if reviews_now > 0
                         else iso(parse_stamp(summary.get("next_reviews_at"))),
        "fetchedAt": iso(now),
    })
    return payload


def build_dashboard(config, api):
    user = data_of(api.get("/user"))
    level = int(user.get("level") or 0)

    subjects, cold_subjects = sync_collection(api, "subjects", "/subjects", slim_subject)
    assignments_by_id, cold_assignments = sync_collection(api, "assignments", "/assignments")
    stats_by_id, _ = sync_collection(api, "review_stats", "/review_statistics")
    progressions_by_id, _ = sync_collection(api, "level_progressions", "/level_progressions")

    assignments = list(assignments_by_id.values())
    review_stats = list(stats_by_id.values())
    level_progressions = list(progressions_by_id.values())

    assignment_by_subject = {}
    for assignment in assignments:
        assignment_by_subject[data_of(assignment).get("subject_id")] = assignment

    now = local_now()
    reviews_now = 0
    for assignment in assignments:
        data = data_of(assignment)
        stage = data.get("srs_stage") or 0
        if stage < 1 or stage > 8 or data.get("hidden"):
            continue
        moment = local_stamp(data.get("available_at"))
        if moment and moment <= now:
            reviews_now += 1

    upcoming = upcoming_reviews(assignments, reviews_now)

    payload = {
        "ok": True,
        "configured": True,
        "error": "",
        "username": str(user.get("username") or ""),
        "level": level,
        "vacation": user.get("current_vacation_started_at") is not None,
        "reviewsNow": reviews_now,
        "coldStart": cold_subjects or cold_assignments,
        "itemSpread": item_spread(assignments),
        "levelProgress": level_progress(subjects, assignment_by_subject, level),
        "projectedLevelUp": projected_level_up(level_progressions, level),
        "upcoming": upcoming,
        "upcomingTotal": sum(day["count"] for day in upcoming),
        "recentlyUnlocked": recent_items(assignments, subjects, "unlocked_at"),
        "recentlyBurned": recent_items(assignments, subjects, "burned_at"),
        "criticalCondition": critical_condition(review_stats, assignment_by_subject, subjects),
        "extraStudy": extra_study(assignments),
        "counts": {"subjects": len(subjects), "assignments": len(assignments)},
        "requests": api.requests,
        "fetchedAt": iso(now_utc()),
    }
    return payload


def unconfigured(note=""):
    payload = base_summary()
    payload["note"] = note
    return payload


# ---------------------------------------------------------------- commands

def cmd_summary(args):
    config = load_config()
    token = api_token(config)
    if not token:
        return unconfigured()
    return summarize(config, Api(token))


def cmd_dashboard(args):
    config = load_config()
    token = api_token(config)
    if not token:
        return unconfigured()
    return build_dashboard(config, Api(token))


def cmd_set_token(args):
    token = sys.stdin.readline().strip()
    if not token:
        payload = base_summary()
        payload["ok"] = False
        payload["error"] = "No API token received"
        return payload

    # Validated before it is written, so a typo never gets stored and then
    # blamed on WaniKani at the next refresh. A new token also means a
    # different account may be in play -- start its caches fresh.
    config = load_config()
    payload = summarize(config, Api(token))
    config["apiToken"] = token
    save_config(config)
    wipe_cache()
    payload["note"] = "Connected as %s" % (payload["username"] or "your WaniKani account")
    return payload


def cmd_clear_token(args):
    config = load_config()
    config.pop("apiToken", None)
    save_config(config)
    wipe_cache()
    return unconfigured("API token removed")


def build_parser():
    parser = argparse.ArgumentParser(description="WaniKani bridge for the Omarchy shell")
    commands = parser.add_subparsers(dest="command", required=True)

    summary = commands.add_parser("summary", help="review / lesson counts, next-review countdown")
    summary.set_defaults(handler=cmd_summary)

    dashboard = commands.add_parser("dashboard", help="sync caches and derive the full dashboard")
    dashboard.set_defaults(handler=cmd_dashboard)

    set_token = commands.add_parser("set-token", help="read an API token from stdin and store it")
    set_token.set_defaults(handler=cmd_set_token)

    clear_token = commands.add_parser("clear-token", help="forget the stored API token")
    clear_token.set_defaults(handler=cmd_clear_token)

    return parser


def main(argv):
    args = build_parser().parse_args(argv)
    try:
        payload = args.handler(args)
    except ApiError as error:
        payload = base_summary()
        payload["ok"] = False
        payload["error"] = str(error)
        payload["configured"] = bool(api_token(load_config())) and error.code != 401
    except Exception as error:  # a traceback on stdout would break the parser
        payload = base_summary()
        payload["ok"] = False
        payload["error"] = "WaniKani helper failed: %s" % (error,)
    json.dump(payload, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
