#!/usr/bin/env python3
"""Write device facts into ServiceRadar over the public API.

Stands in for the external configuration validator that owns the third factor
of a composite service check. A composite check combines what several agents
can reach (vantage points) with what the device is *configured* to be (this).
Without the fact, a check can say a device is unreachable but not that it is
unreachable *because it is configured to be* -- the difference between the
`isolated_verified` and `isolated_unenforced` verdicts.

Auth is OAuth2 client credentials. `PATCH /api/devices/:uid/metadata` sits on
the session/bearer pipeline, not the `X-API-Key` pipeline, so an `X-API-Key`
token will NOT work here -- mint an OAuth client and use its client_id/secret.

Facts are booleans. The composite check resolver casts nothing else, so a
non-boolean value resolves `unknown` forever rather than failing loudly.

Usage:

    export SR_CLIENT_ID=... SR_CLIENT_SECRET=...
    ./device_fact_writer.py --uid 'sr:e7c8f7cd-...' --fact acl_enforced=true

    # every device matching an SRQL scope
    ./device_fact_writer.py --query 'in:devices hostname:lab%' \\
        --fact acl_enforced=true --limit 25

Exits non-zero if any write fails.
"""

from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_BASE_URL = "https://serviceradar.k8s-farm.carverauto.dev"

# Set by main() from --ca-bundle / --insecure. A module global rather than a
# parameter threaded through every call: this is a single-purpose script and
# the TLS posture is fixed for the whole run.
_SSL_CONTEXT: ssl.SSLContext | None = None


class ApiError(Exception):
    pass


def _request(
    method: str,
    url: str,
    *,
    body: dict | None = None,
    form: dict | None = None,
    token: str | None = None,
    timeout: int = 30,
) -> dict:
    """One HTTP call returning decoded JSON.

    Kept deliberately small: the point of this tool is to be a readable
    reference for the fact-writing contract, not to grow an HTTP layer.
    """
    headers = {"Accept": "application/json"}
    data = None

    if form is not None:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"

    if token:
        headers["Authorization"] = f"Bearer {token}"

    req = urllib.request.Request(url, data=data, headers=headers, method=method)

    try:
        with urllib.request.urlopen(req, timeout=timeout, context=_SSL_CONTEXT) as resp:
            payload = resp.read().decode()
            return json.loads(payload) if payload else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")
        # Surface the server's own error text. A bare "HTTP 401" sends the
        # operator hunting through logs for something already in the response.
        raise ApiError(f"{method} {url} -> HTTP {exc.code}: {detail.strip()}") from exc
    except urllib.error.URLError as exc:
        raise ApiError(f"{method} {url} -> {exc.reason}") from exc


def get_token(base_url: str, client_id: str, client_secret: str) -> str:
    """Exchange client credentials for a bearer token."""
    result = _request(
        "POST",
        f"{base_url}/oauth/token",
        form={
            "grant_type": "client_credentials",
            "client_id": client_id,
            "client_secret": client_secret,
        },
    )

    token = result.get("access_token")
    if not token:
        raise ApiError(f"no access_token in token response: {result}")
    return token


def resolve_uids(base_url: str, token: str, query: str, limit: int) -> list[str]:
    """Resolve an SRQL query to device uids via the query API."""
    result = _request(
        "POST",
        f"{base_url}/api/query",
        body={"query": query, "limit": limit},
        token=token,
    )

    rows = result.get("results") or result.get("data") or []
    uids = [row["uid"] for row in rows if isinstance(row, dict) and row.get("uid")]

    if not uids:
        raise ApiError(f"query matched no devices with a uid: {query}")
    return uids


def write_facts(base_url: str, token: str, uid: str, facts: dict) -> dict:
    """PATCH one device's facts. Server stamps provenance; do not send timestamps."""
    return _request(
        "PATCH",
        f"{base_url}/api/devices/{urllib.parse.quote(uid, safe='')}/metadata",
        body={"facts": facts},
        token=token,
    )


def parse_fact(raw: str) -> tuple[str, bool]:
    """Parse `key=true` / `key=false`.

    Booleans only, and rejected here rather than at the server: a string
    "true" is accepted by the API but resolves `unknown` in every composite
    check forever, which is far harder to notice than an argument error.
    """
    if "=" not in raw:
        raise argparse.ArgumentTypeError(f"expected key=true or key=false, got {raw!r}")

    key, _, value = raw.partition("=")
    key = key.strip()
    value = value.strip().lower()

    if not key:
        raise argparse.ArgumentTypeError(f"empty fact key in {raw!r}")
    if value not in ("true", "false"):
        raise argparse.ArgumentTypeError(
            f"fact {key!r} must be true or false, got {value!r} -- "
            "composite checks cast booleans only"
        )

    return key, value == "true"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Write boolean device facts into ServiceRadar.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--base-url",
        default=os.environ.get("SR_BASE_URL", DEFAULT_BASE_URL),
        help=f"ServiceRadar base URL (default: {DEFAULT_BASE_URL})",
    )
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--uid", help="device uid to write to")
    target.add_argument("--query", help="SRQL scope selecting devices to write to")
    parser.add_argument(
        "--fact",
        action="append",
        required=True,
        type=parse_fact,
        metavar="KEY=BOOL",
        help="fact to write, repeatable (e.g. acl_enforced=true)",
    )
    parser.add_argument(
        "--limit", type=int, default=50, help="max devices when using --query"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="resolve targets and print what would be written, then stop",
    )
    parser.add_argument(
        "--ca-bundle",
        default=os.environ.get("SR_CA_BUNDLE"),
        help="PEM bundle for the deployment's CA (internal deployments are "
        "usually signed by a private CA that is not in the system trust store)",
    )
    parser.add_argument(
        "--insecure",
        action="store_true",
        help="skip TLS verification. Lab use only -- it sends the client "
        "secret and every fact to whoever answers the address",
    )
    args = parser.parse_args()

    global _SSL_CONTEXT
    if args.insecure:
        if args.ca_bundle:
            print("error: --insecure and --ca-bundle are mutually exclusive", file=sys.stderr)
            return 2
        print("WARNING: TLS verification disabled", file=sys.stderr)
        _SSL_CONTEXT = ssl._create_unverified_context()
    elif args.ca_bundle:
        try:
            _SSL_CONTEXT = ssl.create_default_context(cafile=args.ca_bundle)
        except OSError as exc:
            print(f"error: could not load CA bundle {args.ca_bundle}: {exc}", file=sys.stderr)
            return 2

    client_id = os.environ.get("SR_CLIENT_ID")
    client_secret = os.environ.get("SR_CLIENT_SECRET")
    if not client_id or not client_secret:
        print(
            "SR_CLIENT_ID and SR_CLIENT_SECRET must be set "
            "(OAuth client credentials, not an X-API-Key token)",
            file=sys.stderr,
        )
        return 2

    base_url = args.base_url.rstrip("/")
    facts = dict(args.fact)

    try:
        token = get_token(base_url, client_id, client_secret)
        uids = [args.uid] if args.uid else resolve_uids(
            base_url, token, args.query, args.limit
        )
    except ApiError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    print(f"{len(uids)} device(s); facts: {json.dumps(facts)}")

    if args.dry_run:
        for uid in uids:
            print(f"  would write {uid}")
        return 0

    failures = 0
    for uid in uids:
        try:
            result = write_facts(base_url, token, uid, facts)
            written = result.get("data", {}).get("facts", {})
            print(f"  ok   {uid} -> {json.dumps(written)}")
        except ApiError as exc:
            failures += 1
            print(f"  FAIL {uid}: {exc}", file=sys.stderr)

    if failures:
        print(f"{failures} of {len(uids)} writes failed", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
