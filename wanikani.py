#!/usr/bin/env python3
"""WaniKani bridge for the io.github.aphelion-studios.omawanikani Omarchy plugin.

Every subcommand prints exactly one JSON object on stdout and exits 0, even when
WaniKani refuses the call, so the QML side has a single shape to parse and only
has to look at ``ok`` / ``error``. The API token is read here -- from a 0600
config file or ``$WANIKANI_API_TOKEN`` -- and never travels through argv, where
``ps`` would show it to every user on the machine.

Usable by hand while developing the plugin::

    ./wanikani.py summary | jq
    printf '%s\\n' "$TOKEN" | ./wanikani.py set-token
    ./wanikani.py clear-token
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import socket
import ssl
import sys
from datetime import datetime, timezone
from pathlib import Path
from time import monotonic

HOST = "api.wanikani.com"
API_BASE = "/v2"
API_REVISION = "20170710"
USER_AGENT = "omarchy-omawanikani/0.1"
TIMEOUT = 8
# Ceiling for one call including its failover attempts: enough for every
# resolved address to get a turn, and no more.
DEADLINE = 28


class ApiError(Exception):
    """A WaniKani call that failed in a way worth showing the user."""

    def __init__(self, message, code=None):
        super().__init__(message)
        self.code = code


# ----------------------------------------------------------------- config

def config_path():
    base = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base) / "omarchy" / "wanikani.json"


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


# -------------------------------------------------------------------- http

class Api:
    """HTTP/1.1 client for one run of one subcommand.

    Not urllib: api.wanikani.com sits behind Cloudflare and resolves to
    several addresses, and a network that cannot reach one of them gets a
    connection that opens and then answers nothing. So we resolve the host
    ourselves, fail over to the next address when one stops answering, and
    keep the connection that worked for the rest of the run.
    """

    def __init__(self, token):
        self.token = token
        self.addresses = self._resolve()
        self.connection = None
        self.address = None

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

    def get(self, path):
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
                # A broken reused connection is usually a keep-alive the server
                # closed, not a bad route: retry the same address once. A
                # timeout is the opposite -- move on immediately.
                if reused and not is_timeout(error):
                    candidates.insert(0, candidate)
                continue
            return decode(response.status, raw)

        raise ApiError("WaniKani did not answer (%s)" % describe(failure))


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


# --------------------------------------------------------------------- time

def now_utc():
    return datetime.now(timezone.utc)


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


def iso(moment):
    if moment is None:
        return ""
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ------------------------------------------------------------------ payload

def base_payload():
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
        "upcomingReviews": 0,
        "forecast": [],
        "fetchedAt": "",
    }


def summarize(config, api):
    user = (api.get("/user") or {}).get("data") or {}
    summary = (api.get("/summary") or {}).get("data") or {}

    now = now_utc()

    lessons_now = 0
    for bucket in summary.get("lessons") or []:
        at = parse_stamp(bucket.get("available_at"))
        if at is None or at <= now:
            lessons_now += len(bucket.get("subject_ids") or [])

    reviews_now = 0
    upcoming = 0
    forecast = []
    for bucket in summary.get("reviews") or []:
        at = parse_stamp(bucket.get("available_at"))
        amount = len(bucket.get("subject_ids") or [])
        if at is None or at <= now:
            reviews_now += amount
        else:
            upcoming += amount
            forecast.append({"at": iso(at), "count": amount})

    next_reviews_at = parse_stamp(summary.get("next_reviews_at"))

    payload = base_payload()
    payload.update({
        "configured": True,
        "username": str(user.get("username") or ""),
        "level": int(user.get("level") or 0),
        "vacation": user.get("current_vacation_started_at") is not None,
        "reviewsNow": reviews_now,
        "lessonsNow": lessons_now,
        # "now" when reviews are already waiting; the API's next_reviews_at is
        # null in that case anyway.
        "nextReviewsAt": "" if reviews_now > 0 else iso(next_reviews_at),
        "upcomingReviews": upcoming,
        "forecast": forecast,
        "fetchedAt": iso(now),
    })
    return payload


def unconfigured(note=""):
    payload = base_payload()
    payload["note"] = note
    return payload


# ---------------------------------------------------------------- commands

def cmd_summary(args):
    config = load_config()
    token = api_token(config)
    if not token:
        return unconfigured()
    return summarize(config, Api(token))


def cmd_set_token(args):
    token = sys.stdin.readline().strip()
    if not token:
        payload = base_payload()
        payload["ok"] = False
        payload["error"] = "No API token received"
        return payload

    # Validated before it is written, so a typo never gets stored and then
    # blamed on WaniKani at the next refresh.
    config = load_config()
    payload = summarize(config, Api(token))
    config["apiToken"] = token
    save_config(config)
    payload["note"] = "Connected as %s" % (payload["username"] or "your WaniKani account")
    return payload


def cmd_clear_token(args):
    config = load_config()
    config.pop("apiToken", None)
    save_config(config)
    return unconfigured("API token removed")


def build_parser():
    parser = argparse.ArgumentParser(description="WaniKani bridge for the Omarchy shell")
    commands = parser.add_subparsers(dest="command", required=True)

    summary = commands.add_parser("summary", help="review / lesson counts, forecast, level")
    summary.set_defaults(handler=cmd_summary)

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
        payload = base_payload()
        payload["ok"] = False
        payload["error"] = str(error)
        # A rejected token is not a "configured" state; anything else keeps
        # whatever token is on disk so the panel still offers a retry.
        payload["configured"] = bool(api_token(load_config())) and error.code != 401
    except Exception as error:  # a traceback on stdout would break the parser
        payload = base_payload()
        payload["ok"] = False
        payload["error"] = "WaniKani helper failed: %s" % (error,)
    json.dump(payload, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
