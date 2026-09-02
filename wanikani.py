#!/usr/bin/env python3
"""WaniKani bridge for the io.github.aphelion-studios.omakani Omarchy plugin.

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
import hashlib
import http.client
import json
import math
import os
import re
import socket
import ssl
import subprocess
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
USER_AGENT = "omarchy-omakani/0.2"
TIMEOUT = 10
# Ceiling for one call including its failover attempts.
DEADLINE = 30

# Bump when the cached record shape changes so stale caches are refetched.
CACHE_VERSION = 2

UPCOMING_DAYS = 5
CRITICAL_THRESHOLD = 75          # percentage_correct below this -> critical
RECENT_WINDOW_DAYS = 30
RECENT_MISTAKE_HOURS = 24        # website's Recent Mistakes look-back
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
    return Path(base) / "omakani"


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
    for name in ("subjects", "assignments", "review_stats", "level_progressions", "notify"):
        try:
            (directory / (name + ".json")).unlink()
        except OSError:
            pass


# ------------------------------------------------------------ notifications

def load_notify_state():
    try:
        with open(cache_dir() / "notify.json", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def save_notify_state(state):
    directory = cache_dir()
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "notify.json"
    temporary = path.with_name("notify.json.tmp")
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(state, handle)
    os.replace(temporary, path)


def detect_notifications(payload, args, scope):
    """Compare the fresh figures against the last-seen snapshot and return the
    events that just crossed. Silent until the first snapshot exists; silent
    while on vacation (but the snapshot still tracks, so returning is quiet)."""
    state = load_notify_state()
    seeded = state.get("seeded") is True
    quiet = (not seeded) or payload.get("vacation") is True
    events = []

    if scope == "summary":
        reviews = int(payload.get("reviewsNow") or 0)
        lessons = int(payload.get("lessonsNow") or 0)
        level = int(payload.get("level") or 0)
        if not quiet:
            threshold = int(getattr(args, "notify_reviews", 0) or 0)
            if threshold > 0 and int(state.get("reviewsNow") or 0) < threshold <= reviews:
                events.append({"id": "reviews", "text": "%d reviews waiting" % reviews})
            if getattr(args, "notify_lessons", False) \
                    and int(state.get("lessonsNow") or 0) == 0 and lessons > 0:
                events.append({"id": "lessons",
                               "text": "%d new %s to learn"
                               % (lessons, "lesson" if lessons == 1 else "lessons")})
            if getattr(args, "notify_levelup", False) \
                    and level > int(state.get("level") or 0) > 0:
                events.append({"id": "levelup", "text": "You reached level %d" % level})
        state["reviewsNow"] = reviews
        state["lessonsNow"] = lessons
        state["level"] = level

    elif scope == "dashboard":
        burned = int((payload.get("extraStudy") or {}).get("burnedItems") or 0)
        if not quiet and getattr(args, "notify_burns", False):
            gained = burned - int(state.get("burnedItems") or 0)
            if gained > 0:
                events.append({"id": "burns",
                               "text": "%d %s burned" % (gained, "item" if gained == 1 else "items")})
        state["burnedItems"] = burned

    state["seeded"] = True
    save_notify_state(state)
    return events


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
        # IPv4 first: getaddrinfo hands back AAAA ahead of A here, and a box
        # whose IPv6 route to Cloudflare is dead then burns ~1s per address
        # failing over -- ~2s of dead weight on every single API call.
        infos.sort(key=lambda info: 0 if info[0] == socket.AF_INET else 1)
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

    def post(self, path, body, _retry=True):
        """POST JSON to a path under /v2 -- only /reviews uses this. Fails over
        while the request has NOT gone out yet; once it's on the wire we never
        retry (a review that might have landed must not be sent twice) -- the
        caller re-checks the assignment instead."""
        payload = json.dumps(body).encode("utf-8")
        headers = {
            "Authorization": "Bearer " + self.token,
            "Wanikani-Revision": API_REVISION,
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": USER_AGENT,
        }
        candidates = []
        if self.address is not None:
            candidates.append(self.address)
        candidates.extend(a for a in self.addresses if a != self.address)

        failure = None
        while candidates:
            candidate = candidates.pop(0)
            try:
                self._close()
                self.connection = self._open(*candidate)
                self.address = candidate
                self.connection.request("POST", API_BASE + path, payload, headers)
            except (OSError, http.client.HTTPException) as error:
                self._close()
                failure = error
                continue  # request never left -- safe to try the next address

            try:
                response = self.connection.getresponse()
                raw = response.read().decode("utf-8", "replace")
            except (OSError, http.client.HTTPException) as error:
                self._close()
                raise ApiError("the review was sent but WaniKani did not answer "
                               "(%s); re-check before retrying" % describe(error)) from error

            self.requests += 1
            if response.status == 429 and _retry:
                delay = response.getheader("Retry-After")
                try:
                    delay = max(1, min(15, int(delay)))
                except (TypeError, ValueError):
                    delay = 2
                time.sleep(delay)
                return self.post(path, body, _retry=False)
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


def recent_mistakes(review_stats, assignment_by_subject, subjects_by_id):
    """The website's Recent Mistakes: items answered wrong in a review in the
    last 24 h and not yet recovered. Reconstructed without a review log --
    a wrong answer bumps the statistic's data_updated_at and breaks that
    component's
    current streak (the follow-up correct answer that ends the review then
    starts a new streak of 1). So inside the window, a component that has ever
    been missed (`*_incorrect > 0`) and whose current streak is back down to
    <= 1 is a miss you haven't yet re-passed. A streak still <= 1 with zero
    lifetime incorrects is just a brand-new item's first review -- not a
    mistake. Radicals have no reading, so only their meaning streak counts.
    (Matches the math-man-123/wanikani-recent-mistakes heuristic.)"""
    cutoff = now_utc() - timedelta(hours=RECENT_MISTAKE_HOURS)
    rows = []
    for stat in review_stats:
        data = data_of(stat)
        if data.get("hidden"):
            continue
        # review_statistic's `data` carries no updated_at -- the modification
        # stamp lives on the envelope as data_updated_at, and WK bumps it on
        # every review of the item.
        updated = parse_stamp((stat or {}).get("data_updated_at"))
        if not updated or updated < cutoff:
            continue
        subject_id = data.get("subject_id")
        is_radical = (subjects_by_id.get(subject_id) or {}).get("object") == "radical"
        missed_meaning = ((data.get("meaning_incorrect") or 0) > 0
                          and (data.get("meaning_current_streak") or 0) <= 1)
        missed_reading = (not is_radical
                          and (data.get("reading_incorrect") or 0) > 0
                          and (data.get("reading_current_streak") or 0) <= 1)
        if not (missed_meaning or missed_reading):
            continue
        if (data_of(assignment_by_subject.get(subject_id)).get("srs_stage") or 0) < 1:
            continue
        rows.append(subject_row(subjects_by_id.get(subject_id), subject_id, iso(updated)))
    rows.sort(key=lambda row: row["at"], reverse=True)
    return rows


def extra_study(assignments, review_stats, assignment_by_subject, subjects_by_id):
    recent_lessons = []
    burned = []
    for assignment in assignments:
        data = data_of(assignment)
        if data.get("burned_at"):
            burned.append(data.get("subject_id"))
        if data.get("started_at") and not data.get("passed_at"):
            recent_lessons.append(data.get("subject_id"))
    mistakes = recent_mistakes(review_stats, assignment_by_subject, subjects_by_id)
    return {
        "recentLessons": len(recent_lessons),
        "recentLessonIds": recent_lessons,
        "recentMistakes": len(mistakes),
        "recentMistakeItems": mistakes[:RECENT_LIST_CAP],
        "recentMistakeIds": [m.get("id") for m in mistakes if m.get("id")],
        "burnedItems": len(burned),
        "burnedItemIds": burned,
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
        "extraStudy": extra_study(assignments, review_stats, assignment_by_subject, subjects),
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
    payload = summarize(config, Api(token))
    payload["notifications"] = detect_notifications(payload, args, "summary")
    return payload


def cmd_dashboard(args):
    config = load_config()
    token = api_token(config)
    if not token:
        return unconfigured()
    payload = build_dashboard(config, Api(token))
    payload["notifications"] = detect_notifications(payload, args, "dashboard")
    return payload


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


def cmd_browse(args):
    """Every subject on one level, from the slim cache -- id, characters,
    primary meaning, ordered radicals -> kanji -> vocabulary, each tagged
    with its unlock / SRS state so the browser can tell locked items apart.
    The full detail arrives lazily via `detail`."""
    config = load_config()
    token = api_token(config)
    if not token:
        return unconfigured()
    api = Api(token)
    subjects, _ = sync_collection(api, "subjects", "/subjects", slim_subject)
    assignments_by_id, _ = sync_collection(api, "assignments", "/assignments")
    assignment_by_subject = {}
    for assignment in assignments_by_id.values():
        assignment_by_subject[data_of(assignment).get("subject_id")] = assignment

    level = int(args.level or 0)
    order = {"radical": 0, "kanji": 1, "vocabulary": 2, "kana_vocabulary": 2}
    rows = []
    progress = {key: {"passed": 0, "unlocked": 0, "total": 0}
                for key in ("radicals", "kanji", "vocabulary")}
    for subject in subjects.values():
        data = data_of(subject)
        if data.get("level") != level or data.get("hidden_at"):
            continue
        a_data = data_of(assignment_by_subject.get(subject.get("id")))
        stage = a_data.get("srs_stage") or 0
        unlocked = bool(a_data.get("unlocked_at"))
        passed = bool(a_data.get("passed_at")) or stage >= 5
        burned = bool(a_data.get("burned_at"))
        key = type_key(subject.get("object"))
        progress[key]["total"] += 1
        if unlocked:
            progress[key]["unlocked"] += 1
        if passed:
            progress[key]["passed"] += 1
        meanings = data.get("meanings") or []
        primary = next((m.get("meaning") for m in meanings if m.get("primary")),
                       meanings[0].get("meaning") if meanings else "")
        rows.append({
            "id": subject.get("id"),
            "object": subject.get("object"),
            "characters": data.get("characters") or "",
            "meaning": primary or "",
            "slug": data.get("slug") or "",
            "unlocked": unlocked,
            "passed": passed,
            "burned": burned,
            "srsStage": stage,
        })
    # the website orders each section alphabetically by primary meaning,
    # ignoring spaces / punctuation ("Afternoon Sun" before "After This")
    def meaning_key(row):
        text = (row.get("meaning") or row.get("slug") or "").lower()
        return "".join(ch for ch in text if ch.isalnum())
    rows.sort(key=lambda row: (order.get(row["object"], 3), meaning_key(row)))
    return {"ok": True, "configured": True, "error": "", "level": level,
            "subjects": rows, "progress": progress,
            "requests": api.requests, "fetchedAt": iso(now_utc())}


def cmd_search(args):
    """Subjects matching a query, across every level. Matches the query against
    each subject's characters, slug and every meaning; ranks exact > prefix >
    substring, then radical > kanji > vocab, then by level. Cheap: it reuses
    the same delta-synced slim `subjects` cache the browser already builds."""
    config = load_config()
    token = api_token(config)
    if not token:
        return unconfigured()
    api = Api(token)
    subjects, _ = sync_collection(api, "subjects", "/subjects", slim_subject)
    assignments_by_id, _ = sync_collection(api, "assignments", "/assignments")
    assignment_by_subject = {}
    for assignment in assignments_by_id.values():
        assignment_by_subject[data_of(assignment).get("subject_id")] = assignment

    query = (args.query or "").strip().lower()
    if not query:
        return {"ok": True, "configured": True, "error": "", "query": "", "results": []}

    order = {"radical": 0, "kanji": 1, "vocabulary": 2, "kana_vocabulary": 2}
    hits = []
    for subject in subjects.values():
        data = data_of(subject)
        if data.get("hidden_at"):
            continue
        chars = data.get("characters") or ""
        slug = (data.get("slug") or "")
        meanings = data.get("meanings") or []
        m_texts = [str(m.get("meaning") or "") for m in meanings]
        primary = next((m.get("meaning") for m in meanings if m.get("primary")),
                       m_texts[0] if m_texts else "")
        score = None
        for hay in [chars, slug] + m_texts:
            low = hay.lower()
            if not low:
                continue
            cand = 0 if low == query else 1 if low.startswith(query) \
                else 2 if query in low else None
            if cand is not None and (score is None or cand < score):
                score = cand
        if score is None:
            continue
        a_data = data_of(assignment_by_subject.get(subject.get("id")))
        hits.append({
            "id": subject.get("id"),
            "object": subject.get("object"),
            "characters": chars,
            "meaning": primary or "",
            "level": data.get("level") or 0,
            "unlocked": bool(a_data.get("unlocked_at")),
            "passed": bool(a_data.get("passed_at")) or (a_data.get("srs_stage") or 0) >= 5,
            "srsStage": a_data.get("srs_stage") or 0,
            "_score": score,
        })

    hits.sort(key=lambda row: (
        row["_score"], order.get(row["object"], 3), row["level"],
        (row["meaning"] or "").lower()))
    hits = hits[:100]
    for row in hits:
        row.pop("_score", None)
    return {"ok": True, "configured": True, "error": "", "query": query,
            "results": hits, "requests": api.requests, "fetchedAt": iso(now_utc())}


def http_get_bytes(url, headers=None, _hops=3):
    """Plain HTTPS GET returning the body bytes. Resolves the host and prefers
    IPv4: http.client (and urllib) try a stalled AAAA for ~8s before falling
    back on this box, which made every fetch feel broken (curl, which does
    happy-eyeballs, is instant). Follows a couple of redirects."""
    parsed = urllib.parse.urlparse(url)
    host = parsed.hostname
    port = parsed.port or 443
    hdrs = {"User-Agent": USER_AGENT}
    if headers:
        hdrs.update(headers)
    try:
        infos = socket.getaddrinfo(host, port, socket.AF_UNSPEC, socket.SOCK_STREAM)
    except OSError as error:
        raise ApiError("could not resolve %s: %s" % (host, error)) from error
    infos.sort(key=lambda i: 0 if i[0] == socket.AF_INET else 1)   # IPv4 first

    last = None
    for family, _, _, _, sockaddr in infos:
        raw = socket.socket(family, socket.SOCK_STREAM)
        raw.settimeout(TIMEOUT)
        try:
            raw.connect(sockaddr)
            secure = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
            connection = http.client.HTTPSConnection(host, port, timeout=TIMEOUT)
            connection.sock = secure
            try:
                target = parsed.path + (("?" + parsed.query) if parsed.query else "")
                connection.request("GET", target or "/", headers=hdrs)
                response = connection.getresponse()
                body = response.read()
                if response.status in (301, 302, 303, 307, 308) and _hops > 0:
                    loc = response.getheader("Location")
                    if loc:
                        return http_get_bytes(urllib.parse.urljoin(url, loc),
                                              headers, _hops - 1)
                if response.status != 200:
                    raise ApiError("GET %s -> HTTP %d" % (url, response.status),
                                   response.status)
                return body
            finally:
                connection.close()
        except (OSError, ssl.SSLError) as error:
            last = error
            try:
                raw.close()
            except OSError:
                pass
    raise ApiError("GET %s failed: %s" % (url, last or "no route"))


def fetch_file(url, dest):
    """Download a public file (a pronunciation-audio clip) straight to `dest`,
    written atomically. files.wanikani.com is a plain CloudFront/S3 origin."""
    blob = http_get_bytes(url)
    dest.parent.mkdir(parents=True, exist_ok=True)
    temporary = dest.with_name(dest.name + ".tmp")
    with open(temporary, "wb") as handle:
        handle.write(blob)
    os.replace(temporary, dest)


# --------------------------------------------------------- radical mnemonics

# WaniKani's illustrated radical images ("Bat wing extended to your right...")
# aren't in the API -- only the plain character renderings are. They ARE on
# the public radical pages though (`<wk-mnemonic-image src="...">`), served
# from the same open CDN as the audio. `radical-images` scrapes them once
# into the cache; it's your own subscribed content, kept local, not
# redistributed. Polite: one page at a time, with a delay.

RADICAL_UA = ("Mozilla/5.0 (X11; Linux x86_64) omakani/%s (personal client)"
              % USER_AGENT.split("/")[-1])
MNEMONIC_DIR_NAME = "radical_mnemonics"


def _web_bytes(url):
    return http_get_bytes(url, headers={"User-Agent": RADICAL_UA})


def flatten_style_svg(text):
    """Inline a `<style>` sheet's simple class rules (`fill`, `opacity`,
    `stroke*`) as attributes on the elements that use them, then drop the
    <style>/<defs> -- QtSvg ignores CSS class selectors, so without this the
    illustration renders flat black."""
    rules = {}
    for block in re.findall(r"<style[^>]*>(.*?)</style>", text, flags=re.S):
        for sel, body in re.findall(r"\.([A-Za-z0-9_-]+)\s*\{([^}]*)\}", block):
            props = {}
            for name, value in re.findall(r"([a-z-]+)\s*:\s*([^;]+)", body):
                value = value.strip().rstrip(";").strip()
                if value.startswith("."):
                    value = "0" + value            # ".5" -> "0.5" for QtSvg
                props[name.strip()] = value
            rules[sel] = props

    def attrs_for(classlist):
        merged = {}
        for name in classlist.split():
            merged.update(rules.get(name, {}))
        return " ".join('%s="%s"' % (k, v) for k, v in merged.items())

    def repl(match):
        a = attrs_for(match.group(1))
        return (" " + a) if a else ""

    text = re.sub(r'\s*class="([^"]*)"', repl, text)
    text = re.sub(r"<defs>\s*</defs>", "", text, flags=re.S)
    text = re.sub(r"<style[^>]*>.*?</style>", "", text, flags=re.S)
    return text


def cmd_radical_images(args):
    """Scrape every radical's illustrated mnemonic image from its public
    wanikani.com page into cache/radical_mnemonics/<id>.svg, plus an
    index.json (id -> alt text). Resumable: re-run to fill gaps, --force to
    redo. Run it once from a terminal; the app only reads the cache."""
    config = load_config()
    token = api_token(config)
    if not token:
        return unconfigured()
    api = Api(token)
    subjects, _ = sync_collection(api, "subjects", "/subjects", slim_subject)
    radicals = [s for s in subjects.values()
                if s.get("object") == "radical" and not data_of(s).get("hidden_at")]
    radicals.sort(key=lambda s: data_of(s).get("level") or 0)

    out_dir = cache_dir() / MNEMONIC_DIR_NAME
    out_dir.mkdir(parents=True, exist_ok=True)
    index_path = out_dir / "index.json"
    try:
        index = json.loads(index_path.read_text(encoding="utf-8"))
    except Exception:
        index = {}

    force = bool(getattr(args, "force", False))
    delay = max(0.0, float(getattr(args, "delay", 0.4) or 0.4))
    tag_re = re.compile(r"<wk-mnemonic-image\b([^>]*)>")
    src_re = re.compile(r'src="([^"]+)"')
    alt_re = re.compile(r'aria-label="([^"]*)"')

    total = len(radicals)
    fetched = skipped = no_image = failed = 0
    for i, subject in enumerate(radicals):
        rid = str(subject.get("id"))
        svg_path = out_dir / (rid + ".svg")
        if not force and rid in index and (index[rid].get("none") or svg_path.exists()):
            skipped += 1
            continue
        url = data_of(subject).get("document_url")
        if not url:
            failed += 1
            continue
        try:
            html = _web_bytes(url).decode("utf-8", "replace")
            tag = tag_re.search(html)
            src = src_re.search(tag.group(1)) if tag else None
            if not src:
                index[rid] = {"none": True}
                no_image += 1
            else:
                blob = _web_bytes(src.group(1))
                body = blob.decode("utf-8", "replace")
                if "<svg" not in body:
                    failed += 1
                else:
                    svg_path.write_text(flatten_style_svg(body), encoding="utf-8")
                    alt = alt_re.search(tag.group(1))
                    index[rid] = {"alt": alt.group(1) if alt else ""}
                    fetched += 1
        except Exception:
            failed += 1
        if (i + 1) % 20 == 0:
            index_path.write_text(json.dumps(index), encoding="utf-8")
            sys.stderr.write("  %d / %d  (got %d, skip %d, none %d, fail %d)\n"
                             % (i + 1, total, fetched, skipped, no_image, failed))
        if delay:
            time.sleep(delay)

    index_path.write_text(json.dumps(index), encoding="utf-8")
    return {"ok": True, "configured": True, "error": "", "total": total,
            "fetched": fetched, "skipped": skipped, "noImage": no_image,
            "failed": failed, "cacheDir": str(out_dir)}


def radical_mnemonic(subject_id):
    """(path, alt) for a radical's scraped mnemonic image, or ("", "")."""
    out_dir = cache_dir() / MNEMONIC_DIR_NAME
    svg_path = out_dir / (str(subject_id) + ".svg")
    if not svg_path.exists():
        return "", ""
    alt = ""
    try:
        index = json.loads((out_dir / "index.json").read_text(encoding="utf-8"))
        alt = str((index.get(str(subject_id)) or {}).get("alt") or "")
    except Exception:
        pass
    return str(svg_path), alt


# -------------------------------------------------------------- audio playback

# A fresh `mpv` per clip has to open the PipeWire/ALSA device cold, and the
# first ~100 ms of the clip is gone before the sink is running. Keep one idle
# mpv alive with its device warm and feed it clips over its JSON IPC socket.
#
# "Warm" needs two things: --audio-stream-silence keeps the sink running (it
# writes silence) instead of tearing the device down at EOF / while idle, and
# a looping silent lavfi source loaded at spawn opens the sink straight away
# so even the very first real clip of a session starts clean.

_MPV_SILENCE = "av://lavfi:anullsrc=r=48000:cl=stereo"

def _mpv_socket_path():
    base = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    return os.path.join(base, "omakani-mpv.sock")


def _mpv_send(obj):
    """Send one IPC command; True on success."""
    sock_path = _mpv_socket_path()
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(1.0)
            s.connect(sock_path)
            s.sendall((json.dumps(obj) + "\n").encode("utf-8"))
        return True
    except OSError:
        return False


def _mpv_spawn():
    sock_path = _mpv_socket_path()
    try:
        os.unlink(sock_path)
    except OSError:
        pass
    try:
        subprocess.Popen(
            ["mpv", "--idle=yes", "--no-config", "--no-terminal", "--no-video",
             "--vo=null", "--no-ytdl", "--ao=pipewire,pulse,alsa",
             "--really-quiet", "--force-window=no",
             "--keep-open=yes", "--keep-open-pause=no",
             "--audio-stream-silence=yes",
             "--audio-buffer=0.15", "--input-ipc-server=" + sock_path,
             _MPV_SILENCE],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, start_new_session=True)
    except FileNotFoundError:
        return False
    for _ in range(60):
        if _mpv_send({"command": ["get_version"]}):
            return True
        time.sleep(0.03)
    return False


def mpv_ensure():
    """Bring the idle mpv up if it isn't already; keep the device warm so the
    next clip starts clean."""
    if _mpv_send({"command": ["get_version"]}):
        return True
    return _mpv_spawn()


def mpv_play(path):
    if not _mpv_send({"command": ["loadfile", str(path), "replace"]}):
        if not _mpv_spawn():
            return False
        _mpv_send({"command": ["loadfile", str(path), "replace"]})
    # unpause in case a previous clip left it paused at EOF
    _mpv_send({"command": ["set_property", "pause", False]})
    return True


def audio_pool(audios, voice, reading=""):
    """A subject's `pronunciation_audios`, ordered best-first for `voice`
    ('kyoko' / 'kenichi' / 'random' / '' = any), mp3 ahead of webm. When
    `reading` is given (a kana string), clips for that pronunciation are
    kept and the rest dropped -- so a multi-reading word (近々 = ちかぢか /
    きんきん) only ever plays back the reading that was just answered."""
    want = (voice or "").lower()
    reading = (reading or "").strip()

    if reading:
        matched = [a for a in audios
                   if str((a.get("metadata") or {}).get("pronunciation") or "").strip()
                   == reading]
        if matched:
            audios = matched

    named = [a for a in audios if (a.get("metadata") or {}).get("voice_actor_name")]
    if want == "random" and named:
        import random
        actors = sorted({(a["metadata"]["voice_actor_name"]) for a in named})
        want = random.choice(actors).lower()

    def score(clip):
        meta = clip.get("metadata") or {}
        actor = str(meta.get("voice_actor_name") or "").lower()
        voice_miss = 0 if (not want or actor == want) else 1
        format_rank = 0 if clip.get("content_type") == "audio/mpeg" else 1
        return (voice_miss, format_rank)

    return sorted(audios, key=score)


def cmd_audio(args):
    """Local file path for a subject's pronunciation audio, downloading and
    caching it under cache/audio/ (keyed by URL) on first use. Vocabulary
    only -- radicals and kanji carry no audio."""
    config = load_config()
    token = api_token(config)
    if not token:
        return unconfigured()
    try:
        sid = str(int(args.subject))
    except (TypeError, ValueError):
        payload = base_summary()
        payload["ok"] = False
        payload["error"] = "audio needs a numeric subject id"
        return payload

    api = Api(token)
    cache = load_cache("detail")
    items = dict(cache.get("items") or {}) if cache.get("v") == CACHE_VERSION else {}
    subject = items.get(sid)
    if not subject:
        fresh, _ = api.collection("/subjects?ids=" + sid)
        for resource in fresh:
            if resource.get("id") is not None:
                items[str(resource["id"])] = resource
        save_cache("detail", {"v": CACHE_VERSION, "items": items})
        subject = items.get(sid)

    audios = data_of(subject).get("pronunciation_audios") or []
    if not audios:
        payload = base_summary()
        payload["ok"] = False
        payload["configured"] = True
        payload["error"] = "no pronunciation audio for that subject"
        return payload

    chosen = audio_pool(audios, getattr(args, "voice", ""),
                        getattr(args, "reading", ""))[0]
    url = chosen["url"]
    extension = ".mp3" if chosen.get("content_type") == "audio/mpeg" else ".webm"
    dest = (cache_dir() / "audio"
            / (hashlib.sha1(url.encode("utf-8")).hexdigest() + extension))
    if not dest.exists() or dest.stat().st_size == 0:
        fetch_file(url, dest)

    played = mpv_play(dest)
    meta = chosen.get("metadata") or {}
    return {"ok": True, "configured": True, "error": "" if played
            else "couldn't reach mpv",
            "path": str(dest), "url": url, "played": played,
            "voiceActor": meta.get("voice_actor_name") or "",
            "gender": meta.get("gender") or "",
            "contentType": chosen.get("content_type") or "",
            "requests": api.requests, "fetchedAt": iso(now_utc())}


def cmd_preload_audio(args):
    """Download every pronunciation clip for a batch of subjects into the
    audio cache, so the first `p` in a session plays instantly. Best-effort:
    a clip that won't download is skipped. Resolves URLs from the local
    subject cache, hitting /subjects only for anything not already there."""
    config = load_config()
    token = api_token(config)
    if not token:
        return unconfigured()
    ids = [str(int(x)) for x in args.ids
           if str(x).strip().lstrip("-").isdigit()]
    if not ids:
        return {"ok": True, "configured": True, "error": "",
                "fetched": 0, "cached": 0, "skipped": 0}

    mpv_ensure()   # warm the audio device before the first p of the session
    api = Api(token)
    cache = load_cache("detail")
    items = dict(cache.get("items") or {}) if cache.get("v") == CACHE_VERSION else {}
    missing = [i for i in ids if i not in items]
    if missing:
        try:
            fresh, _ = api.collection("/subjects?ids=" + ",".join(missing))
            for resource in fresh:
                if resource.get("id") is not None:
                    items[str(resource["id"])] = resource
            save_cache("detail", {"v": CACHE_VERSION, "items": items})
        except ApiError:
            pass

    # collect the clips playback might actually use: mp3 only (audio_pool
    # ranks mp3 ahead of webm), both voice actors, one file each
    wanted = []           # (url, dest)
    cached = 0
    for sid in ids:
        for clip in data_of(items.get(sid)).get("pronunciation_audios") or []:
            if clip.get("content_type") != "audio/mpeg":
                continue
            url = clip.get("url")
            if not url:
                continue
            dest = (cache_dir() / "audio"
                    / (hashlib.sha1(url.encode("utf-8")).hexdigest() + ".mp3"))
            if dest.exists() and dest.stat().st_size > 0:
                cached += 1
            else:
                wanted.append((url, dest))

    fetched = skipped = 0
    if wanted:
        from concurrent.futures import ThreadPoolExecutor

        def grab(pair):
            try:
                fetch_file(pair[0], pair[1])
                return True
            except (ApiError, OSError, socket.error):
                return False

        with ThreadPoolExecutor(max_workers=8) as pool:
            for ok in pool.map(grab, wanted):
                if ok:
                    fetched += 1
                else:
                    skipped += 1

    return {"ok": True, "configured": True, "error": "",
            "fetched": fetched, "cached": cached, "skipped": skipped,
            "requests": api.requests}


def cmd_detail(args):
    """Full subject records for the given ids -- mnemonics, readings, audio,
    context sentences, the component graph -- plus the user's own notes and
    synonyms. Cached to cache/detail.json; the requested set is always
    re-fetched (subjects rarely change and a lesson batch is one request)."""
    config = load_config()
    token = api_token(config)
    if not token:
        return unconfigured()
    ids = [str(int(x)) for x in args.ids
           if str(x).strip().lstrip("-").isdigit()]
    if not ids:
        payload = base_summary()
        payload["ok"] = False
        payload["error"] = "no subject ids given"
        return payload

    api = Api(token)
    cache = load_cache("detail")
    if cache.get("v") != CACHE_VERSION:
        cache = {}
    items = dict(cache.get("items") or {})

    # subject records (mnemonics, readings, the component graph) are effectively
    # immutable -- only hit /subjects for ids we've never cached. This is what
    # makes reopening a big batch (Recent Lessons) fast the second time.
    missing = [i for i in ids if i not in items]
    if missing:
        fresh, _ = api.collection("/subjects?ids=" + ",".join(missing))
        for resource in fresh:
            rid = resource.get("id")
            if rid is not None:
                items[str(rid)] = resource
        save_cache("detail", {"v": CACHE_VERSION, "items": items})

    notes = {}
    try:
        materials, _ = api.collection("/study_materials?subject_ids=" + ",".join(ids))
        for material in materials:
            data = data_of(material)
            notes[str(data.get("subject_id"))] = {
                "meaning_note": data.get("meaning_note"),
                "reading_note": data.get("reading_note"),
                "meaning_synonyms": data.get("meaning_synonyms") or [],
            }
    except ApiError:
        pass

    # the assignment carries the current SRS stage, which the review session
    # needs to show the "you moved to Guru" transition
    assignments = {}
    try:
        rows, _ = api.collection("/assignments?subject_ids=" + ",".join(ids))
        for row in rows:
            data = data_of(row)
            assignments[str(data.get("subject_id"))] = {
                "id": row.get("id"),
                "srs_stage": data.get("srs_stage"),
                "unlocked_at": data.get("unlocked_at"),
                "started_at": data.get("started_at"),
                "passed_at": data.get("passed_at"),
                "burned_at": data.get("burned_at"),
            }
    except ApiError:
        pass

    out = {}
    for sid in ids:
        subject = items.get(sid)
        if not subject:
            continue
        entry = dict(subject)
        entry["study_material"] = notes.get(sid) or {}
        entry["assignment"] = assignments.get(sid) or {}
        if entry.get("object") == "radical":
            path, alt = radical_mnemonic(sid)
            if path:
                entry["mnemonic_image_path"] = path
                entry["mnemonic_image_alt"] = alt
        out[sid] = entry

    return {"ok": True, "configured": True, "error": "", "subjects": out,
            "requests": api.requests, "fetchedAt": iso(now_utc())}


def cmd_reviews(args):
    """The subject ids that are due for review right now, in queue order.
    The app pulls the detail it needs and runs the session; each finished
    item is sent back through `submit-review`."""
    config = load_config()
    token = api_token(config)
    if not token:
        return unconfigured()
    api = Api(token)
    summary = data_of(api.get("/summary"))
    now = now_utc()
    ids = []
    for bucket in summary.get("reviews") or []:
        at = parse_stamp(bucket.get("available_at"))
        if at is None or at <= now:
            ids.extend(bucket.get("subject_ids") or [])
    ids = list(dict.fromkeys(ids))
    return {"ok": True, "configured": True, "error": "",
            "subjectIds": ids, "count": len(ids),
            "requests": api.requests, "fetchedAt": iso(now_utc())}


def cmd_submit_review(args):
    """Record one finished review. `POST /reviews` moves real SRS state, so
    --dry-run returns exactly what WOULD be sent without touching the API.
    The engine passes the tallied wrong-answer counts for each component."""
    config = load_config()
    token = api_token(config)
    if not token:
        return unconfigured()
    try:
        review = {
            "subject_id": int(args.subject),
            "incorrect_meaning_answers": max(0, int(args.incorrect_meaning)),
            "incorrect_reading_answers": max(0, int(args.incorrect_reading)),
        }
    except (TypeError, ValueError):
        payload = base_summary()
        payload["ok"] = False
        payload["error"] = "submit-review needs numeric subject / counts"
        return payload

    if args.dry_run:
        return {"ok": True, "configured": True, "error": "", "dryRun": True,
                "wouldSend": {"review": review}, "requests": 0,
                "fetchedAt": iso(now_utc())}

    api = Api(token)
    try:
        result = api.post("/reviews", {"review": review}) or {}
    except ApiError as error:
        if error.code in (401, 403):
            payload = base_summary()
            payload["ok"] = False
            payload["configured"] = True  # the token still reads fine
            payload["error"] = (
                "This API token can't write reviews -- it's read-only. Make a "
                "new one at wanikani.com/settings/personal_access_tokens with "
                "the 'assignments:start' and 'reviews:create' permissions "
                "checked, then paste it in again.")
            return payload
        # A 422 about the time range / an assignment that is no longer
        # available means this subject has ALREADY been reviewed (its
        # available_at jumped to the future) -- the earlier POST landed. Don't
        # treat that as a session-stopping failure.
        text = str(error).lower()
        if error.code == 422 and (
                "time range" in text or "created_at" in text
                or "not available" in text or "already" in text):
            return {"ok": True, "configured": True, "error": "",
                    "dryRun": False, "alreadyRecorded": True,
                    "review": review, "requests": api.requests,
                    "fetchedAt": iso(now_utc())}
        raise
    data = result.get("data") or {}
    updated = (result.get("resources_updated") or {})
    assignment = data_of(updated.get("assignment"))
    return {"ok": True, "configured": True, "error": "", "dryRun": False,
            "review": review,
            "startingSrsStage": data.get("starting_srs_stage"),
            "endingSrsStage": data.get("ending_srs_stage"),
            "srsStage": assignment.get("srs_stage"),
            "availableAt": assignment.get("available_at"),
            "requests": api.requests, "fetchedAt": iso(now_utc())}


def cmd_lessons(args):
    """The subject ids waiting in the lesson queue, capped to --batch (the
    website's default is 5). The app pulls detail, walks the info cards and
    the quiz, then starts each subject through `start-lesson`."""
    config = load_config()
    token = api_token(config)
    if not token:
        return unconfigured()
    api = Api(token)
    summary = data_of(api.get("/summary"))
    now = now_utc()
    ids = []
    for bucket in summary.get("lessons") or []:
        at = parse_stamp(bucket.get("available_at"))
        if at is None or at <= now:
            ids.extend(bucket.get("subject_ids") or [])
    ids = list(dict.fromkeys(ids))
    total = len(ids)
    batch = getattr(args, "batch", 0) or 0
    if batch > 0:
        ids = ids[:batch]
    return {"ok": True, "configured": True, "error": "",
            "subjectIds": ids, "count": len(ids), "total": total,
            "requests": api.requests, "fetchedAt": iso(now_utc())}


def assignment_id_for(api, subject_id):
    """Resolve a subject id to its assignment id -- from the dashboard's
    assignments cache first, then a fresh lookup."""
    cache = load_cache("assignments")
    if cache.get("v") == CACHE_VERSION:
        for key, resource in (cache.get("items") or {}).items():
            if data_of(resource).get("subject_id") == subject_id:
                return resource.get("id")
    fresh, _ = api.collection("/assignments?subject_ids=" + str(subject_id))
    for resource in fresh:
        if data_of(resource).get("subject_id") == subject_id:
            return resource.get("id")
    return None


def cmd_start_lesson(args):
    """Mark one lesson done. `POST /assignments/{id}/start` moves the subject
    from the lesson queue into reviews (SRS stage 1). --dry-run sends nothing."""
    config = load_config()
    token = api_token(config)
    if not token:
        return unconfigured()
    try:
        subject_id = int(args.subject)
    except (TypeError, ValueError):
        payload = base_summary()
        payload["ok"] = False
        payload["error"] = "start-lesson needs a numeric subject id"
        return payload

    api = Api(token)
    assignment_id = assignment_id_for(api, subject_id)
    if assignment_id is None:
        payload = base_summary()
        payload["ok"] = False
        payload["configured"] = True
        payload["error"] = "no lesson assignment for subject %d" % subject_id
        return payload

    if args.dry_run:
        return {"ok": True, "configured": True, "error": "", "dryRun": True,
                "wouldSend": {"path": "/assignments/%d/start" % assignment_id,
                              "subjectId": subject_id},
                "requests": api.requests, "fetchedAt": iso(now_utc())}

    try:
        result = api.post("/assignments/%d/start" % assignment_id, {}) or {}
    except ApiError as error:
        if error.code in (401, 403):
            payload = base_summary()
            payload["ok"] = False
            payload["configured"] = True
            payload["error"] = (
                "This API token can't start lessons -- it's read-only. Make a "
                "new one at wanikani.com/settings/personal_access_tokens with "
                "the 'assignments:start' and 'reviews:create' permissions "
                "checked, then paste it in again.")
            return payload
        raise
    assignment = data_of(result.get("data"))
    return {"ok": True, "configured": True, "error": "", "dryRun": False,
            "subjectId": subject_id, "assignmentId": assignment_id,
            "srsStage": assignment.get("srs_stage"),
            "availableAt": assignment.get("available_at"),
            "requests": api.requests, "fetchedAt": iso(now_utc())}


def build_parser():
    parser = argparse.ArgumentParser(description="WaniKani bridge for the Omarchy shell")
    commands = parser.add_subparsers(dest="command", required=True)

    summary = commands.add_parser("summary", help="review / lesson counts, next-review countdown")
    summary.add_argument("--notify-reviews", type=int, default=0,
                         help="notify when reviews climb past N (0 = off)")
    summary.add_argument("--notify-lessons", action="store_true")
    summary.add_argument("--notify-levelup", action="store_true")
    summary.set_defaults(handler=cmd_summary)

    dashboard = commands.add_parser("dashboard", help="sync caches and derive the full dashboard")
    dashboard.add_argument("--notify-burns", action="store_true")
    dashboard.set_defaults(handler=cmd_dashboard)

    set_token = commands.add_parser("set-token", help="read an API token from stdin and store it")
    set_token.set_defaults(handler=cmd_set_token)

    browse = commands.add_parser("browse", help="every subject on a level (slim)")
    browse.add_argument("level", type=int)
    browse.set_defaults(handler=cmd_browse)

    detail = commands.add_parser("detail", help="full records for the given subject ids")
    detail.add_argument("ids", nargs="+")
    detail.set_defaults(handler=cmd_detail)

    search = commands.add_parser("search", help="subjects matching a query, across every level")
    search.add_argument("query")
    search.set_defaults(handler=cmd_search)

    audio = commands.add_parser("audio", help="cache a subject's pronunciation audio, print its path")
    audio.add_argument("subject", type=int)
    audio.add_argument("--voice", choices=["kyoko", "kenichi", "random"], default="")
    audio.add_argument("--reading", default="",
                       help="kana reading to play (multi-reading words); others dropped")
    audio.set_defaults(handler=cmd_audio)

    preload_audio = commands.add_parser(
        "preload-audio", help="download every clip for a batch of subjects into the cache")
    preload_audio.add_argument("ids", nargs="+")
    preload_audio.set_defaults(handler=cmd_preload_audio)

    reviews = commands.add_parser("reviews", help="subject ids due for review right now")
    reviews.set_defaults(handler=cmd_reviews)

    submit_review = commands.add_parser("submit-review", help="record one finished review (POST /reviews)")
    submit_review.add_argument("subject", type=int)
    submit_review.add_argument("--incorrect-meaning", type=int, default=0)
    submit_review.add_argument("--incorrect-reading", type=int, default=0)
    submit_review.add_argument("--dry-run", action="store_true",
                               help="show what would be sent, don't POST")
    submit_review.set_defaults(handler=cmd_submit_review)

    lessons = commands.add_parser("lessons", help="subject ids in the lesson queue")
    lessons.add_argument("--batch", type=int, default=0, help="cap to N (0 = all)")
    lessons.set_defaults(handler=cmd_lessons)

    start_lesson = commands.add_parser("start-lesson", help="mark one lesson done (POST /assignments/{id}/start)")
    start_lesson.add_argument("subject", type=int)
    start_lesson.add_argument("--dry-run", action="store_true",
                              help="show what would be sent, don't POST")
    start_lesson.set_defaults(handler=cmd_start_lesson)

    clear_token = commands.add_parser("clear-token", help="forget the stored API token")
    clear_token.set_defaults(handler=cmd_clear_token)

    radical_images = commands.add_parser(
        "radical-images",
        help="one-time scrape of radical mnemonic illustrations from the website")
    radical_images.add_argument("--force", action="store_true",
                                help="re-fetch even radicals already cached")
    radical_images.add_argument("--delay", type=float, default=0.4,
                                help="seconds between page fetches (default 0.4)")
    radical_images.set_defaults(handler=cmd_radical_images)

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
