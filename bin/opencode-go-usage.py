#!/usr/bin/env python3
"""OpenCode Go budget check: authoritative blocked-state probe.

There is NO key-based "percent used" API for OpenCode Go (usage percent exists only behind
the cookie-auth web console). What IS authoritative and long-lived, straight from the
gateway source (packages/console/app/src/routes/zen/util/handler.ts):

  - Every request is quota-checked server-side BEFORE forwarding. Over any window
    ($12/5h rolling, $30/weekly, $60/monthly) the gateway returns HTTP 429 with a
    `retry-after` header (seconds until reset) and JSON
    {error: {type: "GoUsageLimitError", ...}, metadata: {limitName: "5 hour"|"weekly"|"monthly"}}.
  - A blocked request is rejected before billing, so probing while blocked costs nothing.

So this script PROBES (authoritative): sends a 1-token request to the cheapest model using the
API key read live from ~/.local/share/opencode/auth.json (survives /connect key rotation).
-> gateway.blocked = true/false; when blocked: window name + reset_in_sec.

Output: one JSON object; `gateway` is the ground truth.
Exit 0 = not blocked, 2 = blocked, 1 = probe failed (see warnings).
"""

import json
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

GATEWAY = "https://opencode.ai/zen/go/v1"
PROBE_MODEL = "deepseek-v4-flash"  # cheapest; auto-falls-back to the models list if gone
AUTH_JSON = Path.home() / ".local/share/opencode/auth.json"


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


def main():
    warnings = []
    key = api_key(warnings)
    gateway = probe(key, warnings) if key else None
    out = {
        "gateway": gateway,  # authoritative: blocked yes/no (+ window/reset when blocked)
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
