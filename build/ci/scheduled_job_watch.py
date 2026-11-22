#!/usr/bin/env python3
"""Report scheduled BuildBuddy jobs that failed, stalled or did not run.

A scheduled workflow in //:buildbuddy.yaml gates nothing, so its failure is
visible only to someone who opens BuildBuddy. Each run does post a commit
status on the staging commit it ran against. This program reads those statuses
and posts one Discord message naming every watched job whose newest status is

  * failure or error (a failed step, a timeout, a lost runner),
  * pending for longer than STALLED_AFTER, or
  * absent, or a success older than EXPECTED_WITHIN (the job did not run).

The Rekor signing monitor is a GitHub Actions workflow and posts no commit status, so it is not
in WATCHED_JOBS: a separate Actions run lookup reports it when its last successful scan on staging
(a run that kept its checkpoint artifact) is older than MONITOR_EXPECTED_WITHIN (three of its
hourly scan intervals).

It runs from .github/workflows/scheduled-job-watch.yml, after the last nightly.

Environment:
  GITHUB_TOKEN                     reads commit statuses and Actions runs
  GITHUB_REPOSITORY                owner/name
  CI_FAILURE_DISCORD_WEBHOOK_URL   where the message goes (a credential)

Exit status: 0 when every job is healthy or the report was delivered; 1 when
there was something to report and it could not be delivered, or the statuses
could not be read. A failed run of this watcher is itself reported by GitHub.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from http.client import HTTPException

# Every action in //:buildbuddy.yaml with a schedule trigger.
# //build/ci:scheduled_job_watch_test fails when this list and that file differ.
WATCHED_JOBS = (
    "Elixir Quality (daily)",
    "LargeIngestionGate",
    "RustPropertyExploration",
    "WorldWorkerScale",
)
BRANCH = "staging"
# Each job runs once a day; two hours of slack covers a queued or slow run.
EXPECTED_WITHIN = timedelta(hours=26)
# The longest of these jobs is limited to three hours.
STALLED_AFTER = timedelta(hours=6)
LOOKBACK = timedelta(hours=72)
WEBHOOK_ENV = "CI_FAILURE_DISCORD_WEBHOOK_URL"
GITHUB_GRAPHQL = "https://api.github.com/graphql"
GITHUB_API = "https://api.github.com"
MONITOR_WORKFLOW = "rekor-signing-monitor.yml"
MONITOR_NAME = "Rekor Signing Monitor"
MONITOR_EXPECTED_WITHIN = timedelta(hours=3)
MONITOR_SCAN_EVENTS = ("schedule", "workflow_dispatch")
MONITOR_STATE_ARTIFACT = "rekor-signing-monitor-state"
# Discord rejects a message longer than 2000 characters.
MESSAGE_LIMIT = 2000
TIMEOUT_SECONDS = 30
PAGE_LIMIT = 20

QUERY = """
query($owner: String!, $name: String!, $ref: String!, $after: String) {
  repository(owner: $owner, name: $name) {
    ref(qualifiedName: $ref) {
      target {
        ... on Commit {
          history(first: 100, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
              oid
              committedDate
              status { contexts { context state createdAt targetUrl description } }
            }
          }
        }
      }
    }
  }
}
"""


def request_json(url, payload, headers):
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", **headers},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
        body = response.read()
    return json.loads(body) if body else None


def get_json(url, headers):
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
        return json.loads(response.read())


def pages(url, headers, key):
    """Every item of a GitHub list, one page of 100 at a time."""
    page = 1
    while True:
        items = get_json(f"{url}{'&' if '?' in url else '?'}per_page=100&page={page}", headers).get(key) or []
        yield from items
        if len(items) < 100:
            return
        page += 1


def monitor_problems(api, token, repository, now):
    """A line when the Rekor signing monitor has not scanned within MONITOR_EXPECTED_WITHIN.

    A scan is a successful schedule or workflow_dispatch run on BRANCH that kept its checkpoint
    artifact; a self-test dispatch keeps none, so it never counts.
    """
    api = api.rstrip("/")
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
               "User-Agent": "scheduled-job-watch/1"}
    last = None
    for run in pages(f"{api}/repos/{repository}/actions/workflows/{MONITOR_WORKFLOW}/runs?status=success", headers,
                     "workflow_runs"):
        if run.get("head_branch") != BRANCH or run.get("event") not in MONITOR_SCAN_EVENTS:
            continue
        artifacts = pages(f"{api}/repos/{repository}/actions/runs/{run['id']}/artifacts", headers, "artifacts")
        if any(artifact["name"] == MONITOR_STATE_ARTIFACT for artifact in artifacts):
            last = parse_time(run["updated_at"])
            break
    if last is not None and now - last <= MONITOR_EXPECTED_WITHIN:
        return []
    seen = f"last scan {last:%Y-%m-%d %H:%M} UTC" if last else "no successful scan found"
    return [f"**{MONITOR_NAME}** has not scanned in the last {hours(MONITOR_EXPECTED_WITHIN)} hours ({seen})."]


def parse_time(text):
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def newest_statuses(graphql_url, token, repository, now):
    """The newest status of each context on recent commits of the branch.

    The walk reads from the tip through the first commit older than LOOKBACK, so the
    tip and the commit a recent status may sit on are read however old they are.
    """
    owner, name = repository.split("/", 1)
    cutoff = now - LOOKBACK
    newest = {}
    after = None
    for _ in range(PAGE_LIMIT):
        reply = request_json(
            graphql_url,
            {
                "query": QUERY,
                "variables": {
                    "owner": owner,
                    "name": name,
                    "ref": f"refs/heads/{BRANCH}",
                    "after": after,
                },
            },
            {"Authorization": f"Bearer {token}", "User-Agent": "scheduled-job-watch/1"},
        )
        if reply.get("errors"):
            raise ValueError(f"GitHub refused the query: {reply['errors']}")
        history = reply["data"]["repository"]["ref"]["target"]["history"]
        for commit in history["nodes"]:
            for status in (commit["status"] or {}).get("contexts", []):
                seen = {
                    "state": status["state"].lower(),
                    "at": parse_time(status["createdAt"]),
                    "url": status["targetUrl"],
                    "description": status["description"],
                    "commit": commit["oid"],
                }
                held = newest.get(status["context"])
                if held is None or seen["at"] > held["at"]:
                    newest[status["context"]] = seen
            if parse_time(commit["committedDate"]) < cutoff:
                return newest
        if not history["pageInfo"]["hasNextPage"]:
            return newest
        after = history["pageInfo"]["endCursor"]
    raise ValueError(f"more than {PAGE_LIMIT} pages of commits in the lookback window")


def problems(newest, now):
    """One line per watched job that needs attention, in job-name order."""
    lines = []
    for job in WATCHED_JOBS:
        status = newest.get(job)
        state = status["state"] if status else None
        if state in ("failure", "error"):
            detail = f": {status['description']}" if status["description"] else ""
            lines.append(f"**{job}** {state}{detail} at `{status['commit'][:10]}`\n{status['url']}")
        elif state == "pending" and now - status["at"] > STALLED_AFTER:
            lines.append(
                f"**{job}** has been pending for more than {hours(STALLED_AFTER)} hours "
                f"at `{status['commit'][:10]}`\n{status['url']}"
            )
        elif status is None or now - status["at"] > EXPECTED_WITHIN:
            last = f"last status {status['at']:%Y-%m-%d %H:%M} UTC" if status else "no status found"
            lines.append(f"**{job}** did not run in the last {hours(EXPECTED_WITHIN)} hours ({last}).")
    return lines


def hours(delta):
    return int(delta.total_seconds() // 3600)


def post(webhook, content):
    request_json(
        webhook,
        {"content": content[:MESSAGE_LIMIT], "allowed_mentions": {"parse": []}},
        # Discord's edge refuses urllib's default agent.
        {"User-Agent": "scheduled-job-watch/1"},
    )


def main(argv, environ, now=None, graphql_url=GITHUB_GRAPHQL, actions_api=GITHUB_API):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="post a test message instead of reading statuses, to prove the webhook",
    )
    args = parser.parse_args(argv)
    now = now or datetime.now(timezone.utc)

    if args.self_test:
        content = "Scheduled CI job watch: test message. The webhook works."
    else:
        found, read_failed = [], False
        for what, read in (
            ("the commit statuses", lambda: problems(newest_statuses(
                graphql_url, environ["GITHUB_TOKEN"], environ["GITHUB_REPOSITORY"], now), now)),
            (f"the {MONITOR_NAME} runs", lambda: monitor_problems(
                actions_api, environ["GITHUB_TOKEN"], environ["GITHUB_REPOSITORY"], now)),
        ):
            try:
                found += read()
            except (urllib.error.URLError, OSError, HTTPException, ValueError, KeyError, TypeError) as error:
                print(f"could not read {what}: {type(error).__name__}: {error}", file=sys.stderr)
                found.append(f"Could not read {what} ({type(error).__name__}).")
                read_failed = True
        if not found:
            print("every scheduled job is healthy")
            return 0
        content = "Scheduled CI jobs need attention:\n" + "\n".join(found)
        print(content)

    webhook = environ.get(WEBHOOK_ENV, "")
    if not webhook:
        print(f"{WEBHOOK_ENV} is not set: nobody was notified", file=sys.stderr)
        return 1
    try:
        post(webhook, content)
    except (urllib.error.URLError, OSError, HTTPException) as error:
        # The URL is a credential: report the kind of failure, never the URL.
        reason = getattr(error, "code", None) or type(error).__name__
        print(f"the notification was not delivered ({reason})", file=sys.stderr)
        return 1
    return 1 if not args.self_test and read_failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], os.environ))
