#!/usr/bin/env python3
"""OpenCode Go budget check: authoritative blocked-state probe + local burn-rate trend.

There is NO key-based "percent used" API for OpenCode Go (usage percent exists only behind
the cookie-auth web console). What IS authoritative and long-lived, straight from the
gateway source (packages/console/app/src/routes/zen/util/handler.ts):

  - Every request is quota-checked server-side BEFORE forwarding. Over any window
    ($12/5h rolling, $30/weekly, $60/monthly) the gateway returns HTTP 429 with a
    `retry-after` header (seconds until reset) and JSON
    {error: {type: "GoUsageLimitError", ...}, metadata: {limitName: "5 hour"|"weekly"|"monthly"}}.
  - A blocked request is rejected before billing, so probing while blocked costs nothing.

So this script:
  1. PROBE (authoritative): sends a 1-token request to the cheapest model using the API key
     read live from ~/.local/share/opencode/auth.json (survives /connect key rotation).
     -> gateway.blocked = true/false; when blocked: window name + reset_in_sec.
  2. TREND (estimate): sums nominal cost from the local opencode SQLite log over 5h/7d/30d
     lookbacks. This is a this-machine-only trend indicator whose absolute percentages are
     known to overstate vs. server metering — use it for pacing/downshifting decisions only.

Output: one JSON object. Trust `gateway`; treat `local_trend` as directional.
Exit 0 = not blocked, 2 = blocked, 1 = probe failed (see warnings).
"""

import json
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

GATEWAY = "https://opencode.ai/zen/go/v1"
PROBE_MODEL = "deepseek-v4-flash"  # cheapest; auto-falls-back to the models list if gone
AUTH_JSON = Path.home() / ".local/share/opencode/auth.json"
DB_PATH = Path.home() / ".local/share/opencode/opencode.db"
LIMITS_USD = {"5h": 12.0, "weekly": 30.0, "monthly": 60.0}
LOOKBACK_SEC = {"5h": 5 * 3600, "weekly": 7 * 86400, "monthly": 30 * 86400}


def api_key(warnings):
    try:
        key = json.loads(AUTH_JSON.read_text()).get("opencode-go", {}).get("key", "")
        if not key:
            warnings.append("no opencode-go key in auth.json — run /connect inside opencode")
        return key
    except (OSError, ValueError) as e:
        warnings.append(f"cannot read {AUTH_JSON}: {e}")
        return ""


def request(url, key, payload=None):
    """Return (status_code, headers, body_text). Never raises on HTTP error codes."""
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            # Cloudflare 403s (error 1010) the default urllib UA; curl's passes.
            "User-Agent": "curl/8.7.1",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=45) as resp:
            return resp.status, dict(resp.headers), resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read().decode("utf-8", "replace")


def pick_model(key, warnings):
    status, _, body = request(f"{GATEWAY}/models", key)
    if status != 200:
        warnings.append(f"models list returned {status}")
        return None
    try:
        ids = [m["id"] for m in json.loads(body).get("data", [])]
    except (ValueError, KeyError, TypeError):
        warnings.append("could not parse models list")
        return None
    if PROBE_MODEL in ids:
        return PROBE_MODEL
    flash = [i for i in ids if "flash" in i or "mini" in i or "lite" in i]
    return (flash or ids or [None])[0]


def probe(key, warnings):
    """Authoritative blocked-state check against the Go gateway."""
    payload = {
        "model": PROBE_MODEL,
        "max_tokens": 1,
        "messages": [{"role": "user", "content": "hi"}],
    }
    status, headers, body = request(f"{GATEWAY}/chat/completions", key, payload)

    # Model retired after a catalog/subscription change -> re-resolve and retry once.
    if status in (400, 401, 404) and re.search(r"model", body, re.I):
        model = pick_model(key, warnings)
        if model and model != PROBE_MODEL:
            payload["model"] = model
            status, headers, body = request(f"{GATEWAY}/chat/completions", key, payload)

    if status == 200:
        return {"blocked": False, "checked_via": payload["model"]}
    if status == 429:
        try:
            err = json.loads(body)
        except ValueError:
            err = {}
        etype = (err.get("error") or {}).get("type", "")
        reset = headers.get("retry-after") or headers.get("Retry-After")
        result = {
            "blocked": True,
            "error_type": etype or "unknown-429",
            "window": (err.get("metadata") or {}).get("limitName"),
            "reset_in_sec": int(reset) if reset and reset.isdigit() else None,
            "message": (err.get("error") or {}).get("message", "")[:300],
        }
        if "UsageLimitError" not in etype:
            warnings.append("429 without UsageLimitError type — provider rate limit, not quota?")
        return result
    warnings.append(f"probe got unexpected HTTP {status}: {body[:200]}")
    return None


def local_trend(warnings):
    """This-machine burn-rate estimate. Directional only — overstates vs. server metering."""
    if not DB_PATH.exists():
        warnings.append(f"local opencode db not found at {DB_PATH}")
        return None
    try:
        conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True, timeout=5)
        now_ms = int(time.time() * 1000)
        windows = {}
        for win, sec in LOOKBACK_SEC.items():
            rows = conn.execute(
                """SELECT json_extract(data,'$.modelID'),
                          COUNT(*), COALESCE(SUM(json_extract(data,'$.cost')),0)
                   FROM message
                   WHERE json_extract(data,'$.role')='assistant'
                     AND json_extract(data,'$.providerID')='opencode-go'
                     AND time_created >= ?
                   GROUP BY 1""",
                (now_ms - sec * 1000,),
            ).fetchall()
            cost = sum(r[2] for r in rows)
            windows[win] = {
                "est_percent": round(100 * cost / LIMITS_USD[win], 1),
                "est_cost_usd": round(cost, 2),
                "limit_usd": LIMITS_USD[win],
                "requests": sum(r[1] for r in rows),
                "by_model": {r[0]: {"requests": r[1], "cost_usd": round(r[2], 2)} for r in rows},
            }
        conn.close()
        windows["note"] = (
            "rolling lookbacks at list prices — the provider uses fixed billing cycles, "
            "so weekly/monthly overstate (can read >100% while the gateway is green); "
            "directional pacing signal only, `gateway` is the ground truth"
        )
        return windows
    except sqlite3.Error as e:
        warnings.append(f"local db read failed: {e}")
        return None


def main():
    warnings = []
    key = api_key(warnings)
    gateway = probe(key, warnings) if key else None
    out = {
        "gateway": gateway,  # authoritative: blocked yes/no (+ window/reset when blocked)
        "local_trend": local_trend(warnings),  # directional estimate, this machine only
        "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "warnings": warnings,
    }
    json.dump(out, sys.stdout, indent=1)
    print()
    if gateway is None:
        sys.exit(1)
    sys.exit(2 if gateway["blocked"] else 0)


if __name__ == "__main__":
    main()
