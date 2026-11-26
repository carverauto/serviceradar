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
the monitor saw. A run is recorded as checked once every entry it ledgered was seen; each unseen
entry is kept in the checkpoint and reported (named on the open canary issue, or a new one, and
on Discord) every run until it is seen or its log index is acknowledged. Any failure (log unreachable, signature or root mismatch, a rewritten tree, a
changed log key, missing state) exits non-zero after opening an issue, so it cannot pass quietly.

openspec/changes/restore-signature-tlog-receipts, design.md Decisions 5 and 7.
"""

import argparse
import base64
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime, timedelta, timezone
from http.client import HTTPException
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
    # The media-worker CUDA workflow has left this repository. It stays listed so the
    # signatures its earlier runs made remain explained until LEDGER_RETENTION passes.
    "publish-media-worker-cuda.yml",
)
LEDGER_ARTIFACT_PREFIX = "signing-ledger-"
MONITOR_WORKFLOW = "rekor-signing-monitor.yml"
STATE_ARTIFACT = "rekor-signing-monitor-state"
SCAN_INTERVAL = timedelta(hours=1)
# A run's ledger can explain only entries integrated while it ran. GitHub re-runs a run only
# within 30 days of its creation and fails a job that waits on an environment for 30 days, so a run
# active at an entry's integrated time was created at most RUN_MARGIN before it.
RUN_MARGIN = timedelta(days=60)
# Signing-ledger artifacts are kept this long; the canary checks every run that ended within it.
LEDGER_RETENTION = timedelta(days=90)
MESSAGE_LIMIT = 2000
BRANCH = "staging"
SCAN_EVENTS = ("schedule", "workflow_dispatch")
MONITOR_LABEL = "signing-monitor"
ISSUE_LABELS = ["security", MONITOR_LABEL]
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


def certificate_public_key(pem_text):
    """The subject public key of a PEM certificate, as a PEM public key."""
    result = subprocess.run(["openssl", "x509", "-pubkey", "-noout"], input=pem_text.encode(), capture_output=True)
    if result.returncode != 0:
        raise MonitorFailure("an entry's certificate cannot be decoded")
    return result.stdout.decode()


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


# The REST API answers 415 to any Accept it does not serve, including application/zip on an
# artifact's archive_download_url; with this media type it redirects to the archive instead.
GITHUB_MEDIA_TYPE = "application/vnd.github+json"


def describe_request(method, url):
    """Method, host and path of a request for an error message: no query string (a pre-signed
    download carries its credential there) and no user info."""
    parts = urllib.parse.urlsplit(url)
    host = parts.hostname or ""
    if parts.port:
        host = f"{host}:{parts.port}"
    return f"{method} {parts.scheme}://{host}{parts.path}"


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
            error.msg = f"{error.msg} ({describe_request(method, url)})"
            raise
        except urllib.error.URLError as error:
            raise urllib.error.URLError(f"{error.reason} ({describe_request(method, url)})") from error
        except (OSError, HTTPException) as error:
            raise urllib.error.URLError(
                f"{type(error).__name__}: {error} ({describe_request(method, url)})") from error
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
            key_pem = base64.b64decode(key_b64).decode()
        except (ValueError, UnicodeDecodeError):
            continue
        if "-----BEGIN CERTIFICATE-----" in key_pem:
            key_pem = certificate_public_key(key_pem)
        try:
            der = pem_der(key_pem)
        except (ValueError, MonitorFailure):
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

    def pages(self, path, key=None):
        """Every item of a GitHub list, one page of 100 at a time."""
        separator = "&" if "?" in path else "?"
        page = 1
        while True:
            reply = self.http.request(f"{self.api}/repos/{self.repository}/{path}{separator}per_page=100&page={page}")
            items = reply if key is None else reply.get(key, [])
            yield from items
            if len(items) < 100:
                return
            page += 1

    def runs(self, workflow, since):
        created = urllib.parse.quote(f">={since:%Y-%m-%dT%H:%M:%SZ}")
        return list(self.pages(f"actions/workflows/{workflow}/runs?created={created}", "workflow_runs"))

    def cuda_release_deployed_from(self, run, branch):
        query = """
            query($suite: ID!, $attempts: Int!, $filter: CheckRunFilter!) {
              node(id: $suite) {
                ... on CheckSuite {
                  checkRuns(first: $attempts, filterBy: $filter) {
                    nodes { deployment { originalEnvironment ref { prefix name } } }
                  }
                }
              }
            }
        """
        reply = self.http.request(f"{self.api}/graphql", "POST", {
            "query": query, "variables": {
                "suite": run["check_suite_node_id"], "attempts": run["run_attempt"],
                "filter": {"checkName": "publish", "checkType": "ALL"},
            }})
        if reply.get("errors"):
            raise MonitorFailure(f"cannot read deployment for CUDA run {run['id']}: {reply['errors']}")
        for job in reply["data"]["node"]["checkRuns"]["nodes"]:
            deployment = job["deployment"]
            if (deployment and deployment["originalEnvironment"] == "release"
                    and deployment["ref"] == {"prefix": "refs/heads/", "name": branch}):
                return True
        return False

    def ledger_lines(self, run_id):
        lines = []
        for artifact in self.pages(f"actions/runs/{run_id}/artifacts", "artifacts"):
            if not artifact["name"].startswith(LEDGER_ARTIFACT_PREFIX) or artifact.get("expired"):
                continue
            archive = self.http.request(artifact["archive_download_url"], accept=GITHUB_MEDIA_TYPE, raw=True)
            with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
                for name in bundle.namelist():
                    for raw in bundle.read(name).decode().splitlines():
                        if raw.strip():
                            lines.append(json.loads(raw))
        return lines

    def latest_state(self):
        """The checkpoint the newest successful scan on staging kept, or None."""
        for run in self.pages(f"actions/workflows/{MONITOR_WORKFLOW}/runs?status=success", "workflow_runs"):
            if run.get("head_branch") != BRANCH or run.get("event") not in SCAN_EVENTS:
                continue
            for artifact in self.pages(f"actions/runs/{run['id']}/artifacts", "artifacts"):
                if artifact["name"] == STATE_ARTIFACT and not artifact.get("expired"):
                    archive = self.http.request(artifact["archive_download_url"], accept=GITHUB_MEDIA_TYPE, raw=True)
                    with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
                        return bundle.read("state.json")
        return None

    def open_issues(self):
        return [issue for issue in self.pages(f"issues?labels={MONITOR_LABEL}&state=open")
                if "pull_request" not in issue]

    def open_issue(self, title, body):
        try:
            self.http.request(f"{self.api}/repos/{self.repository}/labels/{MONITOR_LABEL}")
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
            self.http.request(f"{self.api}/repos/{self.repository}/labels", "POST",
                              {"name": MONITOR_LABEL, "color": "b60205",
                               "description": "Rekor signing monitor alerts"})
        return self.http.request(f"{self.api}/repos/{self.repository}/issues", "POST",
                                 {"title": title, "body": body, "labels": ISSUE_LABELS})

    def comment(self, number, body):
        self.http.request(f"{self.api}/repos/{self.repository}/issues/{number}/comments", "POST", {"body": body})

    def close_issue(self, number, comment):
        self.comment(number, comment)
        self.http.request(f"{self.api}/repos/{self.repository}/issues/{number}", "PATCH", {"state": "closed"})


def active_at(run, when):
    return run["started"] <= when and (run["ended"] is None or run["ended"] >= when)


def integrated(match):
    return datetime.fromtimestamp(match["integrated_time"], timezone.utc)


def needs_canary(run, first_checkpoint, now, checked):
    return (run["ended"] is not None and run["ended"] >= first_checkpoint
            and now - run["ended"] >= 2 * SCAN_INTERVAL
            and checked.get(str(run["id"]), 0) < int(run["ended"].timestamp()))


def signing_runs(github, since, is_relevant=None, cuda_no_release=None):
    runs = []
    for workflow in SIGNING_WORKFLOWS:
        for run in github.runs(workflow, since):
            # created_at, not run_started_at: a re-run attempt restarts the latter, and an earlier
            # attempt's entries must still fall inside the run's window.
            started = parse_time(run["created_at"])
            ended = parse_time(run["updated_at"]) if run["status"] == "completed" else None
            candidate = {"id": run["id"], "workflow": workflow, "started": started, "ended": ended,
                         "url": run.get("html_url", "")}
            if workflow == "publish-media-worker-cuda.yml":
                branch = run.get("head_branch") or ""
                if not re.fullmatch(r"staging|test/demo-test-[0-9]+", branch):
                    continue
                run_key = str(run["id"])
                ended_ts = int(ended.timestamp()) if ended is not None else None
                if (cuda_no_release is not None and ended_ts is not None
                        and cuda_no_release.get(run_key, 0) >= ended_ts):
                    continue
                if is_relevant is not None and not is_relevant(candidate):
                    continue
                if not github.cuda_release_deployed_from(run, branch):
                    if cuda_no_release is not None and ended_ts is not None:
                        cuda_no_release[run_key] = ended_ts
                    continue
                if cuda_no_release is not None:
                    cuda_no_release.pop(run_key, None)
            runs.append(candidate)
    return runs


def decide(matches, runs, ledgers, acknowledged, decided):
    """Split the release-key entries not already explained into explained, pending and unexplained."""
    explained, pending, unexplained = {}, [], []
    for match in matches:
        # Only a ledger match is kept for good; an acknowledgement counts while it is listed.
        if decided.get(match["uuid"], {}).get("status") == "explained":
            continue
        active = [run for run in runs if active_at(run, integrated(match))]
        explaining = [run for run in active if run["ended"] is not None
                      and match["payload_sha256"] in {line.get("payload_sha256") for line in ledgers.get(run["id"], [])}]
        if explaining:
            explained[match["uuid"]] = ("ledger", f"signing run {explaining[0]['url'] or explaining[0]['id']}")
        elif match["uuid"] in acknowledged:
            explained[match["uuid"]] = ("acknowledged", f"acknowledged: {acknowledged[match['uuid']]}")
        elif any(run["ended"] is None for run in active):
            pending.append(match)
        else:
            unexplained.append(match)
    return explained, pending, unexplained


def blind_spots(matches, runs, ledgers, log_id, first_time):
    """Ledgered entries in this log, from the given ended runs, the scan never saw."""
    seen = {match["log_index"] for match in matches}
    missing = []
    for run in runs:
        for line in ledgers.get(run["id"], []):
            if line.get("event") != "logged" or line.get("log_id") != log_id:
                continue
            if line.get("integrated_time", 0) < first_time:
                continue
            if line["log_index"] not in seen:
                missing.append({"run_id": run["id"], "run": run["url"] or run["id"],
                                "log_index": line["log_index"], "subject": line.get("subject")})
    return missing


def post_discord(http, environ, content):
    webhook = environ.get(WEBHOOK_ENV, "")
    if not webhook:
        print(f"{WEBHOOK_ENV} is not set: Discord was not notified", file=sys.stderr)
        return False
    try:
        http.request(webhook, "POST", {"content": content[:MESSAGE_LIMIT], "allowed_mentions": {"parse": []}})
    except (urllib.error.URLError, OSError, HTTPException) as error:
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
    acknowledged_items = json.loads(Path(args.acknowledged).read_text()).get("entries", [])
    acknowledged = {item["uuid"]: f"{item['reason']} ({item['run']})" for item in acknowledged_items}
    first_time = state["first_integrated_time"]
    decided = state.setdefault("decisions", {})
    undecided = [integrated(match) for match in matches
                 if decided.get(match["uuid"], {}).get("status") != "explained"]
    first_checkpoint = datetime.fromtimestamp(first_time, timezone.utc)
    canary_since = max(first_checkpoint - RUN_MARGIN, now - LEDGER_RETENTION)
    runs_since = min([canary_since] + [when - RUN_MARGIN for when in undecided])
    # An ended run is checked until all it ledgered was seen (again if a re-run ends later).
    checked = {run_id: ended for run_id, ended in state.get("canary_checked", {}).items()
               if ended >= (now - LEDGER_RETENTION).timestamp()}
    cuda_no_release_cutoff = min((now - LEDGER_RETENTION).timestamp(), runs_since.timestamp())
    cuda_no_release = {run_id: ended for run_id, ended in state.get("cuda_no_release", {}).items()
                       if ended >= cuda_no_release_cutoff}
    runs = signing_runs(
        github,
        runs_since,
        is_relevant=lambda run: (needs_canary(run, first_checkpoint, now, checked)
                                 or any(active_at(run, when) for when in undecided)),
        cuda_no_release=cuda_no_release,
    )
    canary_runs = [run for run in runs if needs_canary(run, first_checkpoint, now, checked)]
    ledgers = {run["id"]: github.ledger_lines(run["id"]) for run in runs
               if run["ended"] is not None
               and (run in canary_runs or any(active_at(run, when) for when in undecided))}
    explained, pending, unexplained = decide(matches, runs, ledgers, acknowledged, decided)
    blind = blind_spots(matches, canary_runs, ledgers, log_id, first_time)
    findings = state.get("canary_findings", {})
    for item in blind:
        findings.setdefault(f"{item['run_id']}:{item['log_index']}", item)
    resolved = {match["log_index"] for match in matches} | {item["log_index"] for item in acknowledged_items}
    cleared = {key: item for key, item in findings.items() if item["log_index"] in resolved}
    findings = {key: item for key, item in findings.items() if item["log_index"] not in resolved}

    open_issues = github.open_issues()
    by_uuid = {}
    for issue in open_issues:
        for match in matches:
            if match["uuid"] in issue["title"]:
                by_uuid[match["uuid"]] = issue
    alerts = []
    unalerted = [match for match in unexplained if not decided.get(match["uuid"], {}).get("alerted")]
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
    for uuid, (source, reason) in explained.items():
        decided[uuid] = {"status": "explained" if source == "ledger" else "acknowledged", "reason": reason}
        if uuid in by_uuid:
            github.close_issue(by_uuid[uuid]["number"], f"Explained by {reason}.")
    def describe(item):
        return f"ledgered log index {item['log_index']} ({item['subject']}) from {item['run']}"

    canary_lines = {key: f"{describe(item)} not seen" for key, item in sorted(findings.items())}
    title = "Rekor signing monitor is blind to ledgered entries"
    canary_issue = next((issue for issue in open_issues if issue["title"] == title), None)
    if canary_issue is not None:
        named = "\n".join(f"- {describe(item)}" for _key, item in sorted(cleared.items())
                          if item.get("issue") == canary_issue["number"])
        if not findings:
            github.close_issue(canary_issue["number"],
                               f"Every ledgered entry this issue names is now in the log or acknowledged:\n\n{named}")
            canary_issue = None
        elif named:
            github.comment(canary_issue["number"], f"Now in the log or acknowledged:\n\n{named}")
    if findings:
        unnamed = [key for key in canary_lines
                   if canary_issue is None or findings[key].get("issue") != canary_issue["number"]]
        details = "\n".join(f"- {canary_lines[key]}" for key in unnamed)
        if canary_issue is None:
            canary_issue = github.open_issue(title, "Ledgered signatures the monitor never saw in the log. The "
                                                    f"monitor or the receipt is broken:\n\n{details}")
        elif unnamed:
            github.comment(canary_issue["number"], f"More ledgered signatures the monitor never saw:\n\n{details}")
        for key in unnamed:
            findings[key]["issue"] = canary_issue["number"]
        alerts.append((f"blindness canary: {len(findings)} ledgered entr{'y' if len(findings) == 1 else 'ies'} "
                       "not seen", None))
    alerts += [(f"unexplained release-key entry {match['uuid']} (log index {match['log_index']})", match["uuid"])
               for match in unalerted]
    # Every unseen entry is posted every run; the longest-unposted go first, so all of them rotate in.
    alerts += [(canary_lines[key], key)
               for key in sorted(canary_lines, key=lambda key: findings[key].get("posted_at", ""))]
    content, sent = "Rekor signing monitor:", set()
    for line, tag in alerts:
        if len(content) + len(line) + 3 <= MESSAGE_LIMIT:
            content += f"\n- {line}"
            sent.add(tag)
    delivered = bool(alerts) and post_discord(http, environ, content)
    for match in unexplained:
        decided[match["uuid"]] = {"status": "reported", "log_index": match["log_index"],
                                  "alerted": (delivered and match["uuid"] in sent) or match not in unalerted}
    for key in findings:
        if delivered and key in sent:
            findings[key]["posted_at"] = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    missing_runs = {item["run_id"] for item in blind}
    checked.update({str(run["id"]): int(run["ended"].timestamp()) for run in canary_runs
                    if run["id"] not in missing_runs})
    state["canary_checked"] = checked
    state["cuda_no_release"] = cuda_no_release
    state["canary_findings"] = findings

    state.update({"tree_size": size, "root_hash": root, "checked_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                  "pending": [match["uuid"] for match in pending]})
    Path(args.state_out).write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
    print(f"log size {size}; {len(matches)} release-key entries; {len(pending)} pending; "
          f"{len(unexplained)} unexplained; {len(findings)} blind")
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

    if args.self_test:
        github = GitHub(http, args.github_api, environ["GITHUB_REPOSITORY"])
        issue = github.open_issue("Rekor signing monitor self-test", "Test alert from a manual dispatch. Close it.")
        delivered = post_discord(http, environ, f"Rekor signing monitor: self-test alert ({issue.get('html_url', '')}).")
        return 0 if delivered else 1
    try:
        if args.fetch_state:
            state = GitHub(http, args.github_api, environ["GITHUB_REPOSITORY"]).latest_state()
            if state is not None:
                Path(args.state_out).write_bytes(state)
            print("previous checkpoint found" if state is not None else "no previous checkpoint")
            return 0
        return run(args, environ, now)
    except Exception as error:
        message = f"Rekor signing monitor failed: {type(error).__name__}: {error}"
        print(message, file=sys.stderr)
        try:
            github = GitHub(http, args.github_api, environ["GITHUB_REPOSITORY"])
            title = "Rekor signing monitor run failed"
            if not any(issue["title"] == title for issue in github.open_issues()):
                github.open_issue(title, f"{message}\n\nRun: {environ.get('RUN_URL', '')}")
        except Exception as issue_error:
            print(f"could not open the failure issue: {type(issue_error).__name__}", file=sys.stderr)
        post_discord(http, environ, message)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], os.environ))
