#!/usr/bin/env python3
"""Ensure k8s node NotReady pages through ServiceRadar Notifications.

Talks to the Ash JSON:API at /api/v2. Never prints the bearer token.
Token source (first match): --token, SERVICERADAR_TOKEN.

Does not create a Discord webhook. The named channel must already exist.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

JSON_API = "application/vnd.api+json"
ACCEPT = f"{JSON_API}, application/json"
RULE_NAME = "k8s_node_not_ready"
ROUTE_NAME = "k8s-node-not-ready"
POLICY_NAME = "k8s-node-not-ready"
MATCH = {"field": "alert.metadata.incident_rule_name", "equals": RULE_NAME}
PROBE_NODE = "node-worker-1.example.com"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--instance", required=True, help="ServiceRadar base URL")
    parser.add_argument("--token", default="", help="Bearer token (or SERVICERADAR_TOKEN)")
    parser.add_argument("--channel", default="demo-discord")
    parser.add_argument("--cluster", default="demo")
    parser.add_argument("--fire-test", action="store_true")
    parser.add_argument(
        "--clear-test",
        action="store_true",
        help="Publish node.ready for the probe node after confirming the Discord page",
    )
    args = parser.parse_args()

    if args.fire_test and args.clear_test:
        print(
            "error: --fire-test and --clear-test cannot be combined; the clear resolves the "
            "alert before its routing job runs, so Discord is never paged. Run --fire-test, "
            "confirm the Discord page, then run --clear-test",
            file=sys.stderr,
        )
        return 2

    token = args.token or os.environ.get("SERVICERADAR_TOKEN", "")
    if not token:
        print("error: pass --token or set SERVICERADAR_TOKEN", file=sys.stderr)
        return 2

    instance = args.instance.rstrip("/")
    client = JsonApiClient(instance, token)

    channels = client.list("notification-channels")
    channel = next((row for row in channels if row["attributes"].get("name") == args.channel), None)
    if channel is None:
        print(f"error: channel {args.channel} not found", file=sys.stderr)
        return 1
    if channel["attributes"].get("enabled") is False:
        print(f"error: channel {args.channel} is disabled; nothing would be delivered", file=sys.stderr)
        return 1

    policies = client.list("notification-escalation-policies")
    policy = next((row for row in policies if row["attributes"].get("name") == POLICY_NAME), None)
    if policy is None:
        policy = client.create(
            "notification-escalation-policies",
            "notification_escalation_policy",
            {"name": POLICY_NAME, "enabled": True, "repeat_count": 0, "resolve_notifies": True},
        )

    steps = client.list("notification-escalation-steps")
    step = next(
        (
            row
            for row in steps
            if row["attributes"].get("policy_id") == policy["id"]
            and row["attributes"].get("step_number") == 1
        ),
        None,
    )
    if step is None:
        step = client.create(
            "notification-escalation-steps",
            "notification_escalation_step",
            {
                "policy_id": policy["id"],
                "step_number": 1,
                "delay_seconds": 0,
                "condition": "always",
            },
        )

    client.create(
        "notification-escalation-step-channels",
        "notification_escalation_step_channel",
        {"step_id": step["id"], "channel_id": channel["id"]},
    )

    routes = client.list("notification-routes")

    route_attrs = {
        "name": ROUTE_NAME,
        "priority": 10,
        "continue": False,
        "match_expression": MATCH,
        "escalation_policy_id": policy["id"],
    }
    existing = next((row for row in routes if row["attributes"].get("name") == ROUTE_NAME), None)
    if existing:
        client.patch(f"notification-routes/{existing['id']}", "notification_route", existing["id"], route_attrs)
        print(f"Updated route {ROUTE_NAME}")
        if existing["attributes"].get("enabled") is not True:
            client.patch(f"notification-routes/{existing['id']}/enable", "notification_route", existing["id"], {})
            print(f"Enabled route {ROUTE_NAME}")
    else:
        client.create("notification-routes", "notification_route", {**route_attrs, "enabled": True})
        print(f"Created route {ROUTE_NAME}")

    probe_attrs = {"cluster_id": args.cluster, "node": PROBE_NODE, "role": "worker"}

    if args.fire_test:
        client.action("alerts/k8s-node-not-ready-test", probe_attrs)
        print(f"Fired node.not_ready probe for {PROBE_NODE}; confirm Discord, then re-run with --clear-test")

    if args.clear_test:
        client.action("alerts/k8s-node-ready-test", probe_attrs)
        print(f"Cleared node.not_ready probe for {PROBE_NODE}")

    print(f"OK {ROUTE_NAME} -> {args.channel} on {instance}")
    return 0


class JsonApiClient:
    def __init__(self, instance: str, token: str) -> None:
        self.instance = instance
        self.token = token

    def list(self, path: str) -> list[dict]:
        payload = self.request("GET", f"/api/v2/{path}")
        data = payload.get("data") or []
        return data if isinstance(data, list) else []

    def create(self, path: str, type_name: str, attributes: dict) -> dict:
        payload = self.request("POST", f"/api/v2/{path}", {"data": {"type": type_name, "attributes": attributes}})
        return payload["data"]

    def action(self, path: str, arguments: dict) -> None:
        self.request("POST", f"/api/v2/{path}", {"data": arguments})

    def patch(self, path: str, type_name: str, resource_id: str, attributes: dict) -> dict:
        payload = self.request(
            "PATCH",
            f"/api/v2/{path}",
            {"data": {"type": type_name, "id": resource_id, "attributes": attributes}},
        )
        return payload.get("data") or {}

    def request(self, method: str, path: str, body: dict | None = None) -> dict:
        data = None if body is None else json.dumps(body).encode("utf-8")
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Accept": ACCEPT,
        }
        if data is not None:
            headers["Content-Type"] = JSON_API
        req = urllib.request.Request(
            self.instance + path,
            data=data,
            method=method,
            headers=headers,
        )
        try:
            with urllib.request.urlopen(req) as resp:
                raw = resp.read().decode("utf-8")
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")[:400]
            raise SystemExit(f"{method} {path} -> {exc.code}: {detail}") from exc
        return json.loads(raw) if raw else {"data": {}}


if __name__ == "__main__":
    sys.exit(main())
