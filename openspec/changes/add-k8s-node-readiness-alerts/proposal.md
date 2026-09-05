# Change: Alert Kubernetes node and control-plane NotReady through the notification platform

## Why

A cluster worker going `Ready=False` is silent in Discord even though a
ServiceRadar instance already inventories those nodes and already has a Discord
channel.

Diagnosis on a demo instance separates three layers:

1. **Trigger.** `serviceradar-k8s-inventory` watches Services, EndpointSlices,
   and Gateway API. It does not watch Nodes. There is no `Ready` condition
   signal, no seeded rule, and no `Device Unreachable` (or node-down) alert for
   worker or control-plane hostnames such as `node-worker-1.example.com` and
   `node-control-1.example.com`. Sweep still marks the nodes' IPv4 addresses
   available, which is expected: kubelet NotReady does not imply ICMP loss.
2. **Masking.** The notification platform *is* running. An enabled Discord
   channel exists, with a `webhook_url` secret. The only route (`test`) matches
   `alert.title equals ""`. Recorded deliveries are `suppressed` with
   `no_matching_route`. Channel health is `unknown` because nothing has ever
   been dispatched to it.
3. **Symptom.** Discord stays quiet.

`openspec/changes/add-notification-platform` already built the delivery engine
(Phase 1-3 tasks are checked). `WebhookNotifier` is gone; `Alert.:send_notification`
enqueues routing. This change does **not** add a second Discord path. It
finishes the missing trigger and closes the routing gap that keeps the existing
channel silent.

## What Changes

- Extend `serviceradar-k8s-inventory` to watch Nodes (read-only ClusterRole)
  and publish a current-state snapshot on JetStream subject
  `inventory.k8s.nodes` of the existing `k8s_inventory` stream.
- Ingest snapshots into `platform.k8s_nodes_current` through EventWriter.
  Emit internal readiness events when the Node `Ready` condition flips.
- Seed an EventRule plus a managed StatefulAlertRule that opens one incident
  per cluster node on `Ready=False` (worker or control-plane) and clears it
  when `Ready=True` returns.
- Route those alerts through the existing notification platform to the
  operator Discord channel. Reject empty-string `equals` match operands on
  routes so a "test" route cannot silently match nothing.
- On a demo instance: add (or replace) a route whose predicate matches the
  seeded rule and fans out to the existing Discord channel. Prove Discord
  with a test send that traverses that same route. Operators configure this
  through the JSON:API (`/api/v2/notification-*`) via
  `serviceradar-cli notifications ensure-k8s-alerts` or
  `js/cli/ensure_k8s_node_alerts.py`, not by hand in the UI. The JSON:API
  can create a NotificationChannel only when the operator already has a
  Discord incoming-webhook URL; there is no endpoint that mints a Discord
  webhook. The CLI/Python helpers fail closed if the named channel is
  absent.

## Impact

- Affected specs: `k8s-node-readiness-alerts` (new),
  `observability-rule-management`, `notification-platform` (delta on the
  in-flight platform; empty-equals and node-alert routing).
- Affected code:
  - `go/pkg/k8sinventory`, `go/cmd/k8s-inventory`
  - `helm/serviceradar/templates/k8s-inventory.yaml` (nodes RBAC)
  - `elixir/serviceradar_core` EventWriter processor, migration, rule seeder,
    match-expression validation
  - demo notification route (operator data, not a migration)
