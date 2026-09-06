## 1. Collector: Node inventory

- [x] 1.1 Add a Node view and `BuildNodeSnapshot` in `go/pkg/k8sinventory`
      (cluster id, name, uid, roles, Ready condition, reason/message,
      unschedulable, addresses, kubelet version). Unit tests use documentation
      IPs (`192.0.2.0/24`) and synthetic node names (`node-worker-1.example.com`,
      `node-control-1.example.com`).
- [x] 1.2 Watch Nodes in the inventory informer (cluster-scoped; namespace
      allow-lists do not apply to Nodes). Rebuild still debounces with the
      existing controller.
- [x] 1.3 Publish the node snapshot to JetStream subject `inventory.k8s.nodes`
      on stream `k8s_inventory` without changing the public-endpoints subject.
      `ensureStream` MUST add the new subject when missing. The subject is a
      constant, not a Helm value or env var: EventWriter hardcodes it in both
      the stream definition and the Broadway matcher, so an override could only
      silence node alerting.
- [x] 1.4 Helm ClusterRole: add `nodes` `get/list/watch`. Keep the comment
      that this is read-only and still excludes secrets/pods/exec. Gate with
      `k8sInventory.nodes.enabled` defaulting true when inventory is enabled.
      The COLLECTOR default is the opposite: `K8S_INVENTORY_NODES` defaults to
      false, because the node informer sits inside the startup cache-sync gate
      and a manifest that predates this change has no Nodes RBAC, so an
      image-only rollout would crashloop instead of degrading to endpoints.
      The main chart always renders the env var, so chart-driven deployments
      are unaffected.
- [x] 1.4a `helm/serviceradar-k8s-edge` ships the same image but grants no
      Nodes RBAC (and supports namespace scope, where cluster-scoped Nodes
      cannot be granted). It needs no env var of its own: the collector
      default is off, and 1.4b refuses nodes outright for the `agent_spool`
      mode that chart uses.
- [x] 1.4b `Config.Validate` refuses `K8S_INVENTORY_NODES=true` with
      `PUBLISH_MODE=agent_spool`. `SpoolPublisher.Publish` ignores the subject
      and keeps one `latest.json`, so a node snapshot would overwrite the
      endpoint snapshot the agent republishes, and an endpoints processor that
      accepts it soft-deletes every public endpoint row for the cluster.
- [x] 1.4c The resync tick rebuilds directly instead of calling `Notify()`.
      The debounce is resetting with no max wait, so Node status events - a
      new, cluster-size-proportional source - could otherwise hold it open and
      starve the public-endpoint publish that shares the same loop.
- [x] 1.5 `bazel test //go/pkg/k8sinventory:k8sinventory_test`

## 2. EventWriter ingest and readiness events

- [x] 2.1 HAND-WRITE migration
      `elixir/serviceradar_core/priv/repo/migrations/20260906110000_create_k8s_nodes_current.exs`
      creating `platform.k8s_nodes_current` (`prefix: "platform"`).
- [x] 2.2 Add `ServiceRadar.EventWriter.Processors.K8sNodes` that upserts the
      snapshot and soft-deletes cluster rows absent from it.
- [x] 2.3 On `Ready` false←true / true←false transitions of a PERSISTED node,
      publish internal logs via `InternalLogPublisher` (`k8s`, event types
      `node.not_ready` / `node.ready`). Do not call Discord or
      `WebhookNotifier`. A node seen for the first time does not page: kubelet
      registers a joining Node with `Ready=False`, so a first-seen rule would
      page critical on every node join.
- [x] 2.3a A NotReady node that leaves the snapshot still emits `node.ready`
      so its incident clears, but says it was removed from the cluster rather
      than that it recovered.
- [x] 2.3b A failed readiness publish rolls the snapshot transaction back.
      Committing the row while dropping the event would leave the next
      snapshot comparing the new `ready` value against itself, so the incident
      could never open; the apply is idempotent, so redelivery recomputes the
      same transition.
- [x] 2.4 Add EventWriter consumer `K8S_NODES` on stream `k8s_inventory`,
      subject `inventory.k8s.nodes`. Narrow the public-endpoints Broadway
      matcher to exact `inventory.k8s.public_endpoints` so node snapshots
      cannot hit `K8sPublicEndpoints`.
- [x] 2.5 Processor tests: upsert, soft-delete, emit only on Ready flips,
      ignore malformed snapshots.

## 3. Seeded alert rules

- [x] 3.1 Seed EventRule `k8s_node_readiness_events` matching
      `logs.internal.k8s` event types `node.not_ready` / `node.ready`,
      promoting to log name `k8s.node.readiness`.
- [x] 3.2 Seed managed StatefulAlertRule `k8s_node_not_ready`: open on
      `node.not_ready`, recover on `node.ready`, group by cluster + node,
      severity critical, title distinguishing control-plane vs worker from
      `node.role`. `template_version: 2`. The role names the node in the title
      through the rule's `event["message"]` template, NOT through `group_by`:
      a group key is the incident identity, and `node.role` is a mutable
      label, so including it would strand an open incident whenever the label
      changed while the node was down.
- [x] 3.3 Alert metadata MUST include `incident_rule_name=k8s_node_not_ready`
      (existing AlertLifecycle behaviour) plus node name and cluster id, which
      arrive as `incident_group_values`. Role and Ready reason are NOT on the
      alert: `incident_group_values` is the only group-key-to-metadata path,
      and the role is deliberately out of the group key (3.2). The role rides
      the alert title instead, so route on `alert.title` `contains` for a
      role-specific page. Set `device_uid` when an inventory device hostname
      matches the Node name.
- [ ] 3.4 Seeder / engine tests covering open, recover, and role in the title.
      The message template and the group-key stability it buys are covered by
      `RecordRenderTemplateTest`; an end-to-end pass through the seeded rule
      still needs the database fixture.

## 4. Notification routing gap

- [x] 4.1 Reject a NotificationRoute `match_expression` whose `equals`
      operand is an empty string, with an actionable message that `%{}`
      matches everything and `equals: ""` matches only a blank value.
- [x] 4.2 Tests: save rejected; `%{}` still match-all; a predicate on
      `alert.metadata.incident_rule_name` equals `k8s_node_not_ready` matches
      a node-down alert and does not match an anomaly finding.
- [x] 4.3 Do not add a second Discord transport.

## 5. Docs

- [x] 5.1 Document Node readiness inventory and the seeded rule in
      `docs/docs/k8s-public-endpoint-inventory.md` (or a short sibling page
      linked from it) and the notifications operator doc: how to route
      `k8s_node_not_ready` to an existing Discord channel. ASCII only.
- [x] 5.2 `openspec validate add-k8s-node-readiness-alerts --strict`

## 5a. JSON:API and CLI

- [x] 5a.1 Expose exactly the Notifications `/api/v2` routes the helpers
      call: channels index; routes index/create/update/enable; escalation
      policies index/create; steps index/create; step-channels attach.
      NotificationProvider stays off the JSON:API, and NotificationChannel is
      read-only there because `secret_refs` is writable on the resource and no
      endpoint mints a Discord webhook.
- [x] 5a.2 Add `serviceradar-cli notifications ensure-k8s-alerts` (JS CLI,
      device-code auth already in `auth login`). Do not add a parallel srctl
      command.
- [x] 5a.3 Add `js/cli/ensure_k8s_node_alerts.py` using the same endpoints.
      Token from `--token` or `SERVICERADAR_TOKEN` only; never print or commit
      it.
- [x] 5a.4 Withhold NotificationChannel `secret_refs` from JSON:API
      (`hide_fields`). A `notifications.channels.view` holder must not be able
      to read a channel's encrypted webhook material back out.
- [x] 5a.5 Both helpers fail closed on a disabled channel and enable an
      existing `k8s-node-not-ready` route after updating it, because the route
      `update` action does not accept `enabled`.
- [x] 5a.6 Split the probe into `--fire-test` (publishes `node.not_ready`
      only) and `--clear-test` (publishes `node.ready`), backed by separate
      `/api/v2/alerts/k8s-node-{not-ready,ready}-test` actions, so the page
      lands before anything clears it. Both helpers reject the two flags in
      one invocation, which would restore the race the split removed.
- [x] 5a.7 The helpers own only the `k8s-node-not-ready` route and its
      policy/step. No sweep that disables other operator-owned routes.

## 6. Demo

- [x] 6.1 Roll collector + core-elx (EventWriter lives in core) to carverauto
      `demo` per demo-local-rollout. Do not take a live node down.
- [x] 6.2 After rules seed, add or replace a demo NotificationRoute matching
      `alert.metadata.incident_rule_name` equals `k8s_node_not_ready` whose
      escalation step fans out to `demo-discord`. Leave the empty-title `test`
      route disabled or deleted so it cannot win.
- [x] 6.3 Fire a test dispatch that exercises that route (synthetic node-down
      alert or equivalent). Confirm a `NotificationDelivery` with `state=sent`
      and that Discord received it. Record the portal/delivery evidence URL.
