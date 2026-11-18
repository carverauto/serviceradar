#!/usr/bin/env python3
"""Watch ServiceRadar's self-hosted Rekor log for release-key signatures no signing run explains.

The log (https://rekor.serviceradar.cloud) holds only ServiceRadar's entries, so every run reads
all of them, recomputes the RFC 6962 root and compares it with the signed tree head, which must
verify under the pinned docs/sigstore/rekor.pub. That proves the log is append-only between runs
without consistency proofs. Every `hashedrekord` entry signed by the release key (docs/cosign.pub)
in the whole log is then decided, once; the decision is kept in the checkpoint state, so an entry
a ledger explained stays explained after that run and its ledger artifact age out:

  * pending while a run of a release-key signing workflow that was active at the entry's
    integrated time is still in progress (its ledger is uploaded only when it ends);
  * explained when its payload hash is in the signing ledger of such a run, or the entry is
    listed in docs/sigstore/rekor-acknowledged-entries.json;
  * unexplained otherwise: one GitHub issue per entry UUID and a Discord post.

An issue whose entry later becomes explained is closed. The blindness canary alerts when a
ledgered entry from a run that ended more than two scan intervals ago is not among the entries
the monitor saw. Any failure (log unreachable, signature or root mismatch, a rewritten tree, a
changed log key, missing state) exits non-zero after opening an issue, so it cannot pass quietly.

openspec/changes/restore-signature-tlog-receipts, design.md Decisions 5 and 7.
"""

import argparse
import base64
import hashlib
import io
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

REKOR_URL = "https://rekor.serviceradar.cloud"
GITHUB_API = "https://api.github.com"
# Every workflow that signs with hashivault://cosign-release writes a signing ledger.
SIGNING_WORKFLOWS = (
    "release.yml",
    "publish-oci.yml",
    "wasm-plugins.yml",
    "native-addons.yml",
    "external-wasm-plugin.yml",
    "publish-dockerfile-image.yml",
)
LEDGER_ARTIFACT_PREFIX = "signing-ledger-"
MONITOR_WORKFLOW = "rekor-signing-monitor.yml"
STATE_ARTIFACT = "rekor-signing-monitor-state"
SCAN_INTERVAL = timedelta(hours=1)
# A run's ledger can explain only entries integrated while it ran; look back far enough to find
# every run that could still be in progress or recently ended.
RUN_LOOKBACK = timedelta(days=3)
ISSUE_LABELS = ["security", "signing-monitor"]
WEBHOOK_ENV = "CI_FAILURE_DISCORD_WEBHOOK_URL"
TIMEOUT_SECONDS = 30
BATCH = 10
STATE_VERSION = 1


class MonitorFailure(Exception):
    """The monitor cannot vouch for the log; this run must fail and alert."""


def parse_time(text):
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def pem_der(pem_text):
    lines = [line.strip() for line in pem_text.strip().splitlines()]
    if lines[0] != "-----BEGIN PUBLIC KEY-----" or lines[-1] != "-----END PUBLIC KEY-----":
        raise MonitorFailure("not a single PEM public key")
    return base64.b64decode("".join(lines[1:-1]), validate=True)


def merkle_root(leaves):
    """RFC 6962 Merkle tree hash over leaf hashes (the empty tree is SHA-256 of nothing)."""
    if not leaves:
        return hashlib.sha256(b"").digest()
    level = list(leaves)
    # Iterative form of MTH: split at the largest power of two below n, recursively.
    def mth(items):
        if len(items) == 1:
            return items[0]
        k = 1
        while k * 2 < len(items):
            k *= 2
        return hashlib.sha256(b"\x01" + mth(items[:k]) + mth(items[k:])).digest()
    return mth(level)


def verify_signature(pem_path, payload, signature):
    """ECDSA P-256/SHA-256 verification through openssl, the only crypto the runner needs."""
    with tempfile.TemporaryDirectory() as directory:
        sig_path = Path(directory) / "sig"
        data_path = Path(directory) / "data"
        sig_path.write_bytes(signature)
        data_path.write_bytes(payload)
        result = subprocess.run(
            ["openssl", "dgst", "-sha256", "-verify", str(pem_path), "-signature", str(sig_path), str(data_path)],
            capture_output=True,
        )
        return result.returncode == 0


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, url):
        return None


class Http:
    """JSON over HTTPS. The GitHub token goes only to the GitHub API, never to a redirect target."""

    def __init__(self, token=None, github_api=GITHUB_API):
        self.token = token
        self.github_api = github_api.rstrip("/")
        self.opener = urllib.request.build_opener(NoRedirect)

    def request(self, url, method="GET", payload=None, accept="application/json", raw=False, redirects=3,
                send_token=True):
        headers = {"Accept": accept, "User-Agent": "rekor-signing-monitor/1"}
        data = None
        if payload is not None:
            data = json.dumps(payload).encode()
            headers["Content-Type"] = "application/json"
        if send_token and self.token and url.startswith(self.github_api + "/"):
            headers["Authorization"] = f"Bearer {self.token}"
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=TIMEOUT_SECONDS) as response:
                body = response.read()
        except urllib.error.HTTPError as error:
            location = error.headers.get("Location")
            error.close()
            if error.code in (301, 302, 303, 307, 308) and redirects > 0 and location:
                # A redirect (an artifact's pre-signed download) never receives the token.
                return self.request(location, accept=accept, raw=raw, redirects=redirects - 1, send_token=False)
            raise
        if raw:
            return body
        return json.loads(body) if body else None


class Rekor:
    def __init__(self, http, url):
        self.http = http
        self.url = url.rstrip("/")

    def log_info(self):
        return self.http.request(f"{self.url}/api/v1/log")

    def public_key(self):
        return self.http.request(f"{self.url}/api/v1/log/publicKey", accept="application/x-pem-file", raw=True).decode()

    def entries(self, size):
        """Every entry, by log index, as (leaf hash, uuid, entry)."""
        found = {}
        for start in range(0, size, BATCH):
            indexes = list(range(start, min(start + BATCH, size)))
            reply = self.http.request(f"{self.url}/api/v1/log/entries/retrieve", "POST", {"logIndexes": indexes})
            for item in reply:
                for uuid, entry in item.items():
                    body = base64.b64decode(entry["body"], validate=True)
                    found[entry["logIndex"]] = (hashlib.sha256(b"\x00" + body).digest(), uuid, entry)
        if sorted(found) != list(range(size)):
            raise MonitorFailure(f"the log returned {len(found)} entries for a tree of size {size}")
        return [found[index] for index in range(size)]


def verify_tree_head(info, rekor_key_path):
    """Check the signed tree head under the pinned key and return (size, root hex)."""
    note, _, signature_block = info["signedTreeHead"].partition("\n\n")
    lines = note.split("\n")
    if len(lines) < 3:
        raise MonitorFailure("malformed signed tree head")
    size, root = int(lines[1]), base64.b64decode(lines[2]).hex()
    if size != info["treeSize"] or root != info["rootHash"]:
        raise MonitorFailure("the signed tree head does not match the reported tree")
    verified = False
    for line in signature_block.strip().split("\n"):
        encoded = line.rsplit(" ", 1)[-1]
        signature = base64.b64decode(encoded)
        if verify_signature(rekor_key_path, (note + "\n").encode(), signature[4:]):
            verified = True
    if not verified:
        raise MonitorFailure("the signed tree head does not verify under docs/sigstore/rekor.pub")
    return size, root


def release_key_entries(entries, release_der):
    """(log index, uuid, payload sha256, integrated time) of each entry signed by the release key."""
    matches = []
    for index, (_leaf, uuid, entry) in enumerate(entries):
        body = json.loads(base64.b64decode(entry["body"]))
        if body.get("kind") != "hashedrekord":
            continue
        spec = body.get("spec") or {}
        key_b64 = ((spec.get("signature") or {}).get("publicKey") or {}).get("content", "")
        try:
            der = pem_der(base64.b64decode(key_b64).decode())
        except (ValueError, UnicodeDecodeError, MonitorFailure):
            continue
        if der != release_der:
            continue
        digest = ((spec.get("data") or {}).get("hash") or {}).get("value")
        matches.append({"log_index": index, "uuid": uuid, "payload_sha256": digest,
                        "integrated_time": entry["integratedTime"]})
    return matches


class GitHub:
    def __init__(self, http, api, repository):
        self.http = http
        self.api = api.rstrip("/")
        self.repository = repository

    def runs(self, workflow, since):
        created = urllib.parse.quote(f">={since:%Y-%m-%dT%H:%M:%SZ}")
        runs, page = [], 1
        while True:
            reply = self.http.request(f"{self.api}/repos/{self.repository}/actions/workflows/{workflow}/runs"
                                      f"?created={created}&per_page=100&page={page}")
            runs.extend(reply.get("workflow_runs", []))
            if len(reply.get("workflow_runs", [])) < 100:
                return runs
            page += 1

    def ledger_lines(self, run_id):
        reply = self.http.request(f"{self.api}/repos/{self.repository}/actions/runs/{run_id}/artifacts?per_page=100")
        lines = []
        for artifact in reply.get("artifacts", []):
            if not artifact["name"].startswith(LEDGER_ARTIFACT_PREFIX) or artifact.get("expired"):
                continue
            archive = self.http.request(artifact["archive_download_url"], accept="application/zip", raw=True)
            with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
                for name in bundle.namelist():
                    for raw in bundle.read(name).decode().splitlines():
                        if raw.strip():
                            lines.append(json.loads(raw))
        return lines

    def latest_state(self):
        """The checkpoint the newest successful monitor run kept, or None."""
        reply = self.http.request(f"{self.api}/repos/{self.repository}/actions/workflows/{MONITOR_WORKFLOW}/runs"
                                  "?status=success&per_page=20")
        for run in reply.get("workflow_runs", []):
            artifacts = self.http.request(f"{self.api}/repos/{self.repository}/actions/runs/{run['id']}/artifacts")
            for artifact in artifacts.get("artifacts", []):
                if artifact["name"] == STATE_ARTIFACT and not artifact.get("expired"):
                    archive = self.http.request(artifact["archive_download_url"], accept="application/zip", raw=True)
                    with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
                        return bundle.read("state.json")
        return None

    def open_issues(self):
        reply = self.http.request(f"{self.api}/repos/{self.repository}/issues?labels=signing-monitor&state=open&per_page=100")
        return [issue for issue in reply if "pull_request" not in issue]

    def open_issue(self, title, body):
        return self.http.request(f"{self.api}/repos/{self.repository}/issues", "POST",
                                 {"title": title, "body": body, "labels": ISSUE_LABELS})

    def close_issue(self, number, comment):
        self.http.request(f"{self.api}/repos/{self.repository}/issues/{number}/comments", "POST", {"body": comment})
        self.http.request(f"{self.api}/repos/{self.repository}/issues/{number}", "PATCH", {"state": "closed"})


def signing_runs(github, now):
    runs = []
    for workflow in SIGNING_WORKFLOWS:
        for run in github.runs(workflow, now - RUN_LOOKBACK):
            # created_at, not run_started_at: a re-run attempt restarts the latter, and an earlier
            # attempt's entries must still fall inside the run's window.
            started = parse_time(run["created_at"])
            ended = parse_time(run["updated_at"]) if run["status"] == "completed" else None
            runs.append({"id": run["id"], "workflow": workflow, "started": started, "ended": ended,
                         "url": run.get("html_url", "")})
    return runs


def decide(matches, runs, ledgers, acknowledged, decided):
    """Split the release-key entries not already explained into explained, pending and unexplained."""
    explained, pending, unexplained = {}, [], []
    for match in matches:
        # Only a ledger match is kept for good; an acknowledgement counts while it is listed.
        if decided.get(match["uuid"], {}).get("status") == "explained":
            continue
        when = datetime.fromtimestamp(match["integrated_time"], timezone.utc)
        active = [run for run in runs if run["started"] <= when and (run["ended"] is None or run["ended"] >= when)]
        if match["uuid"] in acknowledged:
            explained[match["uuid"]] = ("acknowledged", f"acknowledged: {acknowledged[match['uuid']]}")
            continue
        if any(run["ended"] is None for run in active):
            pending.append(match)
            continue
        explaining = [run for run in active
                      if match["payload_sha256"] in {line.get("payload_sha256") for line in ledgers.get(run["id"], [])}]
        if explaining:
            explained[match["uuid"]] = ("ledger", f"signing run {explaining[0]['url'] or explaining[0]['id']}")
        else:
            unexplained.append(match)
    return explained, pending, unexplained


def blind_spots(matches, runs, ledgers, log_id, first_time, now):
    """Ledgered entries in this log, from runs that ended two intervals ago, the scan never saw."""
    seen = {match["log_index"] for match in matches}
    missing = []
    for run in runs:
        if run["ended"] is None or now - run["ended"] < 2 * SCAN_INTERVAL:
            continue
        for line in ledgers.get(run["id"], []):
            if line.get("event") != "logged" or line.get("log_id") != log_id:
                continue
            if line.get("integrated_time", 0) < first_time:
                continue
            if line["log_index"] not in seen:
                missing.append({"run": run["url"] or run["id"], "log_index": line["log_index"],
                                "subject": line.get("subject")})
    return missing


def post_discord(http, environ, content):
    webhook = environ.get(WEBHOOK_ENV, "")
    if not webhook:
        print(f"{WEBHOOK_ENV} is not set: Discord was not notified", file=sys.stderr)
        return False
    try:
        http.request(webhook, "POST", {"content": content[:2000], "allowed_mentions": {"parse": []}})
    except (urllib.error.URLError, OSError) as error:
        # The URL is a credential: name the failure, never the URL.
        print(f"the Discord notification was not delivered ({getattr(error, 'code', None) or type(error).__name__})",
              file=sys.stderr)
        return False
    return True


def run(args, environ, now):
    http = Http(environ.get("GITHUB_TOKEN"), args.github_api)
    rekor = Rekor(http, args.rekor_url)
    github = GitHub(http, args.github_api, environ["GITHUB_REPOSITORY"])
    rekor_key_text = Path(args.rekor_key).read_text()
    log_id = hashlib.sha256(pem_der(rekor_key_text)).hexdigest()
    release_der = pem_der(Path(args.release_key).read_text())

    served = rekor.public_key()
    if pem_der(served) != pem_der(rekor_key_text):
        raise MonitorFailure("the log serves a public key other than docs/sigstore/rekor.pub")

    info = rekor.log_info()
    size, root = verify_tree_head(info, args.rekor_key)
    entries = rekor.entries(size)
    if merkle_root([leaf for leaf, _uuid, _entry in entries]).hex() != root:
        raise MonitorFailure("the entries the log returned do not hash to its signed root")

    state_path = Path(args.state_in) if args.state_in else None
    if state_path and state_path.is_file():
        state = json.loads(state_path.read_text())
        if state.get("tree_id") != info["treeID"]:
            raise MonitorFailure(f"the log's tree changed from {state.get('tree_id')} to {info['treeID']}")
        previous = state["tree_size"]
        if previous > size:
            raise MonitorFailure(f"the log shrank from {previous} to {size} entries")
        if merkle_root([leaf for leaf, _uuid, _entry in entries[:previous]]).hex() != state["root_hash"]:
            raise MonitorFailure("the log rewrote entries the previous checkpoint covered")
    elif args.bootstrap:
        state = {"version": STATE_VERSION, "tree_id": info["treeID"], "first_tree_size": size,
                 "first_integrated_time": int(now.timestamp())}
    else:
        raise MonitorFailure("the previous checkpoint is missing; re-run with bootstrap only after review")

    matches = release_key_entries(entries, release_der)
    runs = signing_runs(github, now)
    ledgers = {run["id"]: github.ledger_lines(run["id"]) for run in runs if run["ended"] is not None}
    acknowledged = {item["uuid"]: f"{item['reason']} ({item['run']})"
                    for item in json.loads(Path(args.acknowledged).read_text()).get("entries", [])}
    first_time = state["first_integrated_time"]
    decided = state.setdefault("decisions", {})
    explained, pending, unexplained = decide(matches, runs, ledgers, acknowledged, decided)
    blind = blind_spots(matches, runs, ledgers, log_id, first_time, now)

    open_issues = github.open_issues()
    by_uuid = {}
    for issue in open_issues:
        for match in matches:
            if match["uuid"] in issue["title"]:
                by_uuid[match["uuid"]] = issue
    alerts = []
    for match in unexplained:
        if match["uuid"] in by_uuid:
            continue
        title = f"Unexplained release-key signature in Rekor: {match['uuid']}"
        body = (f"An entry in {args.rekor_url} is signed by the release key and no signing ledger or "
                f"acknowledgement explains it.\n\n- log index: {match['log_index']}\n- UUID: {match['uuid']}\n"
                f"- integrated: {datetime.fromtimestamp(match['integrated_time'], timezone.utc):%Y-%m-%d %H:%M:%S} UTC\n"
                f"- payload SHA-256: {match['payload_sha256']}\n"
                f"- entry: {args.rekor_url}/api/v1/log/entries/{match['uuid']}\n\n"
                "Treat this as possible misuse of the release key until a person explains it. A benign "
                "entry is acknowledged in docs/sigstore/rekor-acknowledged-entries.json in a reviewed PR.")
        github.open_issue(title, body)
        alerts.append(f"unexplained release-key entry {match['uuid']} (log index {match['log_index']})")
    for match in unexplained:
        decided[match["uuid"]] = {"status": "reported", "log_index": match["log_index"]}
    for uuid, (source, reason) in explained.items():
        decided[uuid] = {"status": "explained" if source == "ledger" else "acknowledged", "reason": reason}
        if uuid in by_uuid:
            github.close_issue(by_uuid[uuid]["number"], f"Explained by {reason}.")
    if blind:
        details = "\n".join(f"- log index {item['log_index']} ({item['subject']}) from {item['run']}" for item in blind)
        title = "Rekor signing monitor is blind to ledgered entries"
        if not any(issue["title"] == title for issue in open_issues):
            github.open_issue(title, "Ledgered signatures the monitor never saw in the log. The monitor or "
                                     f"the receipt is broken:\n\n{details}")
        alerts.append(f"blindness canary: {len(blind)} ledgered entr{'y' if len(blind) == 1 else 'ies'} not seen")

    state.update({"tree_size": size, "root_hash": root, "checked_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                  "pending": [match["uuid"] for match in pending]})
    Path(args.state_out).write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
    print(f"log size {size}; {len(matches)} release-key entries; {len(pending)} pending; "
          f"{len(unexplained)} unexplained; {len(blind)} blind")
    if alerts:
        post_discord(http, environ, "Rekor signing monitor:\n" + "\n".join(f"- {line}" for line in alerts))
    return 0


def main(argv, environ, now=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--rekor-url", default=REKOR_URL)
    parser.add_argument("--github-api", default=environ.get("GITHUB_API_URL", GITHUB_API))
    parser.add_argument("--rekor-key", default="docs/sigstore/rekor.pub")
    parser.add_argument("--release-key", default="docs/cosign.pub")
    parser.add_argument("--acknowledged", default="docs/sigstore/rekor-acknowledged-entries.json")
    parser.add_argument("--state-in")
    parser.add_argument("--state-out", required=True)
    parser.add_argument("--bootstrap", action="store_true",
                        help="start from the current log with no previous checkpoint (first run only)")
    parser.add_argument("--self-test", action="store_true", help="post a test alert to prove the alert path")
    parser.add_argument("--fetch-state", action="store_true",
                        help="write the newest successful run's checkpoint to --state-out, if there is one")
    args = parser.parse_args(argv)
    now = now or datetime.now(timezone.utc)
    http = Http(environ.get("GITHUB_TOKEN"), args.github_api)

    if args.fetch_state:
        state = GitHub(http, args.github_api, environ["GITHUB_REPOSITORY"]).latest_state()
        if state is not None:
            Path(args.state_out).write_bytes(state)
        print("previous checkpoint found" if state is not None else "no previous checkpoint")
        return 0
    if args.self_test:
        github = GitHub(http, args.github_api, environ["GITHUB_REPOSITORY"])
        issue = github.open_issue("Rekor signing monitor self-test", "Test alert from a manual dispatch. Close it.")
        delivered = post_discord(http, environ, f"Rekor signing monitor: self-test alert ({issue.get('html_url', '')}).")
        return 0 if delivered else 1
    try:
        return run(args, environ, now)
    except (MonitorFailure, urllib.error.URLError, OSError, ValueError, KeyError) as error:
        message = f"Rekor signing monitor failed: {type(error).__name__}: {error}"
        print(message, file=sys.stderr)
        try:
            github = GitHub(http, args.github_api, environ["GITHUB_REPOSITORY"])
            title = "Rekor signing monitor run failed"
            if not any(issue["title"] == title for issue in github.open_issues()):
                github.open_issue(title, f"{message}\n\nRun: {environ.get('RUN_URL', '')}")
        except (urllib.error.URLError, OSError, ValueError, KeyError) as issue_error:
            print(f"could not open the failure issue: {type(issue_error).__name__}", file=sys.stderr)
        post_discord(http, environ, message)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], os.environ))
