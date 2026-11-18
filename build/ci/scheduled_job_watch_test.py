"""The scheduled job watch is run against local stand-ins for GitHub and Discord.

What is protected: a scheduled job that failed, stalled or did not run is
named in exactly one message; healthy jobs produce none; an undelivered report
fails the run; and every scheduled action in buildbuddy.yaml is watched.
"""

import contextlib
import http.server
import io
import json
import threading
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

import yaml

from build.ci import scheduled_job_watch as watch

ROOT = Path(__file__).resolve().parents[2]
NOW = datetime(2030, 1, 2, 12, 0, tzinfo=timezone.utc)
RUN = "https://ci.example.com/invocation/"


class Server:
    """Answers each POST from a queue and records what it was sent.

    A queued reply is (status, body), or a function of the request that returns one.
    """

    def __init__(self, *replies):
        received = self.received = []
        queue = list(replies)

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers["Content-Length"])
                received.append(json.loads(self.rfile.read(length)))
                reply = queue.pop(0)
                status, body = reply(received[-1]) if callable(reply) else reply
                self.send_response(status)
                self.end_headers()
                self.wfile.write(json.dumps(body).encode() if body is not None else b"")

            def log_message(self, *_):
                pass

        self.server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_port}/"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def status(context, state, hours_ago, description=""):
    return {
        "context": context,
        "state": state,
        "createdAt": (NOW - timedelta(hours=hours_ago)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "targetUrl": f"{RUN}{context.split()[0].lower()}-{state.lower()}",
        "description": description,
    }


def commit(oid, hours_ago, contexts):
    return {
        "oid": oid * 40,
        "committedDate": (NOW - timedelta(hours=hours_ago)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "status": {"contexts": contexts} if contexts else None,
    }


def page(commits, cursor=None, committed_hours_ago=1):
    nodes = [commit(oid, committed_hours_ago, contexts) for oid, contexts in commits]
    history = {"pageInfo": {"hasNextPage": cursor is not None, "endCursor": cursor}, "nodes": nodes}
    return 200, {"data": {"repository": {"ref": {"target": {"history": history}}}}}


def healthy(*, without=()):
    return [
        # Old enough that only its state, not its age, keeps a passed job out of the report.
        status(job, "SUCCESS", 20) for job in watch.WATCHED_JOBS if job not in without
    ]


def history(*commits):
    """GitHub's history: (oid, hours since committed, contexts), newest first.

    Like GitHub, a `since` argument drops every commit committed before it.
    """

    def reply(request):
        since = request["variables"].get("since")
        nodes = [
            commit(oid, age, contexts)
            for oid, age, contexts in commits
            if since is None or NOW - timedelta(hours=age) >= datetime.fromisoformat(since)
        ]
        history = {"pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": nodes}
        return 200, {"data": {"repository": {"ref": {"target": {"history": history}}}}}

    return reply


class ScheduledJobWatchTest(unittest.TestCase):
    def serve(self, *replies):
        server = Server(*replies)
        self.addCleanup(server.close)
        return server

    def run_watch(self, github, webhook=None, argv=()):
        environ = {"GITHUB_TOKEN": "token", "GITHUB_REPOSITORY": "example/project"}
        if webhook is not None:
            environ[watch.WEBHOOK_ENV] = webhook.url
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = watch.main(list(argv), environ, now=NOW, graphql_url=github.url)
        return code, out.getvalue(), err.getvalue()

    def test_healthy_jobs_send_nothing(self):
        github = self.serve(page([("a", healthy())]))
        webhook = self.serve()

        code, _, _ = self.run_watch(github, webhook)

        self.assertEqual(0, code)
        self.assertEqual([], webhook.received)
        self.assertEqual("refs/heads/staging", github.received[0]["variables"]["ref"])

    def test_failed_stalled_and_missing_jobs_are_named_in_one_message(self):
        # The newest status wins across commits and pages: the gate failed on an older
        # commit and passed since, so it is healthy; the quality job passed and then failed.
        newer = [
            status("Elixir Quality (daily)", "FAILURE", 5, "Failed in 10m"),
            status("LargeIngestionGate", "SUCCESS", 1),
            status("WorldWorkerScale", "PENDING", 7, "Running..."),
        ]
        older = [
            status("Elixir Quality (daily)", "SUCCESS", 29),
            status("LargeIngestionGate", "ERROR", 9, "Disconnected"),
            status("RustPropertyExploration", "SUCCESS", 30),
        ]
        github = self.serve(page([("a", newer), ("b", None)], cursor="next"), page([("c", older)]))
        webhook = self.serve((204, None))

        code, _, _ = self.run_watch(github, webhook)

        self.assertEqual(0, code)
        self.assertEqual("next", github.received[1]["variables"]["after"])
        self.assertEqual(1, len(webhook.received))
        self.assertEqual({"parse": []}, webhook.received[0]["allowed_mentions"])
        self.assertEqual(
            "Scheduled CI jobs need attention:\n"
            f"**Elixir Quality (daily)** failure: Failed in 10m at `aaaaaaaaaa`\n{RUN}elixir-failure\n"
            "**RustPropertyExploration** did not run in the last 26 hours "
            "(last status 2030-01-01 06:00 UTC).\n"
            "**WorldWorkerScale** has been pending for more than 6 hours at `aaaaaaaaaa`\n"
            f"{RUN}worldworkerscale-pending",
            webhook.received[0]["content"],
        )

    def test_an_error_status_and_a_job_never_seen_are_reported(self):
        contexts = healthy(without=("LargeIngestionGate", "WorldWorkerScale"))
        contexts.append(status("LargeIngestionGate", "ERROR", 2, "Disconnected"))
        github = self.serve(page([("a", contexts)]))
        webhook = self.serve((204, None))

        self.run_watch(github, webhook)

        content = webhook.received[0]["content"]
        self.assertIn("**LargeIngestionGate** error: Disconnected", content)
        self.assertIn("**WorldWorkerScale** did not run in the last 26 hours (no status found)", content)

    def test_a_job_still_running_is_not_reported(self):
        contexts = healthy(without=("WorldWorkerScale",))
        contexts.append(status("WorldWorkerScale", "PENDING", 5, "Running..."))
        github = self.serve(page([("a", contexts)]))
        webhook = self.serve()

        code, _, _ = self.run_watch(github, webhook)

        self.assertEqual(0, code)
        self.assertEqual([], webhook.received)

    def test_a_red_or_stalled_job_keeps_its_state_after_26_hours(self):
        # Monday's 07:30 run, seen at Tuesday's 12:00 watch with nothing newer.
        contexts = healthy(without=("Elixir Quality (daily)", "LargeIngestionGate", "WorldWorkerScale"))
        contexts += [
            status("Elixir Quality (daily)", "FAILURE", 28.5, "Failed in 10m"),
            status("LargeIngestionGate", "ERROR", 28.5, "Disconnected"),
            status("WorldWorkerScale", "PENDING", 28.5, "Running..."),
        ]
        github = self.serve(page([("a", contexts)]))
        webhook = self.serve((204, None))

        self.run_watch(github, webhook)

        self.assertEqual(
            "Scheduled CI jobs need attention:\n"
            f"**Elixir Quality (daily)** failure: Failed in 10m at `aaaaaaaaaa`\n{RUN}elixir-failure\n"
            f"**LargeIngestionGate** error: Disconnected at `aaaaaaaaaa`\n{RUN}largeingestiongate-error\n"
            "**WorldWorkerScale** has been pending for more than 6 hours at `aaaaaaaaaa`\n"
            f"{RUN}worldworkerscale-pending",
            webhook.received[0]["content"],
        )

    def test_statuses_on_a_staging_tip_older_than_the_lookback_are_read(self):
        # Last staging commit Friday 10:00; the nightlies passed on it Monday 07:30.
        github = self.serve(history(("a", 74, healthy())))
        webhook = self.serve()

        code, _, _ = self.run_watch(github, webhook)

        self.assertEqual(0, code)
        self.assertEqual([], webhook.received)

    def test_statuses_on_the_parent_of_a_new_tip_after_a_quiet_stretch_are_read(self):
        # One commit lands after that Monday's nightlies, before the next ones run.
        github = self.serve(history(("a", 2, None), ("b", 74, healthy()), ("c", 80, None)))
        webhook = self.serve()

        code, _, _ = self.run_watch(github, webhook)

        self.assertEqual(0, code)
        self.assertEqual([], webhook.received)

    def test_the_walk_stops_at_the_first_commit_outside_the_lookback(self):
        # A second page is never requested: the stand-in has no reply queued for one.
        github = self.serve(page([("a", healthy())], cursor="next", committed_hours_ago=73))
        webhook = self.serve()

        code, _, _ = self.run_watch(github, webhook)

        self.assertEqual(0, code)
        self.assertEqual(1, len(github.received))
        self.assertEqual([], webhook.received)

    def test_an_undelivered_report_fails_the_run_without_printing_the_url(self):
        failing = healthy(without=("WorldWorkerScale",))
        failing.append(status("WorldWorkerScale", "FAILURE", 3))

        refused = self.serve((500, None))
        code, out, err = self.run_watch(self.serve(page([("a", failing)])), refused)
        self.assertEqual(1, code)
        self.assertIn("not delivered (500)", err)
        self.assertNotIn(refused.url, out + err)

        code, out, err = self.run_watch(self.serve(page([("a", failing)])))
        self.assertEqual(1, code)
        self.assertIn("nobody was notified", err)
        # The job log still says what was wrong.
        self.assertIn("**WorldWorkerScale** failure", out)

    def test_unreadable_statuses_fail_the_run(self):
        webhook = self.serve()
        replies = (
            ((502, None), "HTTPError"),
            # GitHub answers 200 with the refusal in the body.
            ((200, {"errors": [{"message": "denied"}]}), "denied"),
        )
        for reply, reason in replies:
            code, _, err = self.run_watch(self.serve(reply), webhook)
            self.assertEqual(1, code)
            self.assertIn("could not read commit statuses", err)
            self.assertIn(reason, err)
        self.assertEqual([], webhook.received)

    def test_self_test_posts_without_reading_statuses(self):
        github = self.serve()
        webhook = self.serve((204, None))

        code, _, _ = self.run_watch(github, webhook, argv=["--self-test"])

        self.assertEqual(0, code)
        self.assertEqual([], github.received)
        self.assertIn("test message", webhook.received[0]["content"])

    def test_every_scheduled_action_is_watched(self):
        config = yaml.safe_load((ROOT / "buildbuddy.yaml").read_text(encoding="utf-8"))
        scheduled = sorted(
            action["name"]
            for action in config["actions"]
            if "schedule" in (action.get("triggers") or {})
        )

        self.assertEqual(scheduled, sorted(watch.WATCHED_JOBS))


if __name__ == "__main__":
    unittest.main()
