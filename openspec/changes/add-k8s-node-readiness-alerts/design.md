## Context

Demo ServiceRadar already inventories carverauto worker and control-plane
nodes as devices and already has a Discord notification channel. Node
`Ready=False` still pages nobody.

`add-notification-platform` replaced the unsupervised `WebhookNotifier` with
`ServiceRadar.Notifications`. Delivery is functional; demo configuration is
not. The k8s-inventory collector is the right place to observe Node
conditions: it already holds the cluster-wide read-only ServiceAccount.
Host agents MUST NOT gain kube API credentials (same split as public
endpoint inventory).

## Goals / Non-Goals

- Goals:
  - Observe Kubernetes Node `Ready` for every node in the watched cluster.
  - Open one stateful incident per node when `Ready` becomes False; clear it
    when `Ready` returns True.
  - Distinguish control-plane vs worker in the alert title, from Node role
    labels, without a second delivery path.
  - Deliver through the existing notification platform to the existing
    Discord channel.
  - Close the empty-string route matcher footgun.
- Non-Goals:
  - A parallel Discord webhook, Helm Discord sidecar, or Alertmanager route.
  - Paging on MemoryPressure/DiskPressure/PIDPressure independently of
    `Ready` (those often *cause* NotReady; `Ready` is the operator signal).
  - Sweep/ICMP as a substitute for Node conditions.
  - Cordon, drain, or otherwise disturb a live worker to prove the path.
  - Seeding a Discord webhook URL or channel secret in git.

## Decisions

- **Decision: watch Nodes in `serviceradar-k8s-inventory`, not a new binary.**
  One ClusterRole, one NATS identity, one stream. Adding `nodes` get/list/watch
  stays read-only and does not grant pods/secrets/exec.
  Alternatives: a second Deployment (more RBAC and image surface); scraping
  kube-state-metrics (another hop, still needs a rule, not in the inventory
  collector).

- **Decision: publish `inventory.k8s.nodes` on stream `k8s_inventory`.**
  The publisher already `CreateOrUpdateStream`s extra subjects. EventWriter
  today binds consumer `K8S_INVENTORY` to exact subject
  `inventory.k8s.public_endpoints` and routes any `inventory.k8s.*` Broadway
  batcher to `K8sPublicEndpoints`. A node snapshot on a child subject would
  be dropped as malformed. This change adds a dedicated consumer/processor
  and narrows the public-endpoints batcher to that exact subject.

- **Decision: current-state table plus transition events.**
  `platform.k8s_nodes_current` is the IR catalog (mirrors
  `public_endpoints_current`). Readiness flips are emitted as internal logs
  (`logs.internal.k8s`) and promoted by a seeded EventRule, then collapsed by
  a managed StatefulAlertRule. Reusing that pair is how
  `sweep_device_unavailable` works; do not call Discord from EventWriter.

- **Decision: order node snapshots by their generated timestamp.**
  `platform.k8s_node_snapshots` retains the latest accepted `generated_at` per
  cluster, including empty snapshots. Node rows alone cannot retain a watermark
  for an initially empty cluster. A conditional upsert serializes application
  per cluster and rejects equal or older timestamps before node writes,
  deletions, or readiness events. The watermark and node writes share one
  transaction. Readiness transitions use synchronous stateful evaluation through
  the existing log-promotion path; queue admission is insufficient. Evaluation
  errors roll back the node writes and watermark for redelivery.
  Timestamp precision is retained to microseconds; collectors must have
  synchronized clocks. The migration seeds watermarks from existing node rows
  and deletion timestamps.

- **Decision: one rule, role in the title and not in the identity.**
  `k8s_node_not_ready` groups by cluster_id + node name. Control-plane vs
  worker is `node.role` (`control-plane` if the Node has
  `node-role.kubernetes.io/control-plane` or `.../master`, else `worker`),
  and the rule's `event["message"]` template renders it into the alert title.

  The role is deliberately NOT a group key. A group key is the incident
  identity that `StateMachine.recover_event/3` looks up verbatim, so a mutable
  label there strands an open incident: relabel a node while it is NotReady
  and the clear computes a different key, the lookup misses, and the incident
  re-pages every `renotify_seconds` forever.

  The consequence for routing: `incident_group_values` is the only path from a
  rule's group key into `alert.metadata`, so the alert carries
  `metadata.incident_group_values` of `cluster_id` and `node` ONLY - there is
  no `node.role` and no `ready_reason` on the alert. A route that wants
  control-plane pages only must match the title
  (`{"field": "alert.title", "contains": "control-plane"}`), not a metadata
  field. Writing `alert.metadata.incident_group_values.node.role` validates
  (the `alert.metadata.` prefix is allow-listed) and then matches nothing.

- **Decision: do not seed a Discord channel.**
  Channels are operator secrets. Product seeds the *rule*. Demo gets a
  NotificationRoute whose `match_expression` names
  `alert.metadata.incident_rule_name equals k8s_node_not_ready` and whose
  escalation step already points at `demo-discord`.

- **Decision: reject empty-string `equals` on routes.**
  `%{}` already means match-all. `equals: ""` matches only a blank title and
  is how demo's `test` route suppressed every real alert. Save-time rejection
  with an actionable message; existing rows keep working until edited.

- **Decision: prove Discord without taking a node down.**
  Create a synthetic alert (or test dispatch) whose snapshot carries
  `incident_rule_name=k8s_node_not_ready` so it traverses the same route as a
  real NotReady. A channel-only test-send that bypasses Router is not enough.

- **Decision: the probe fires and clears in two separate calls.**
  `POST /alerts/k8s-node-not-ready-test` publishes only `node.not_ready`;
  `POST /alerts/k8s-node-ready-test` publishes the matching `node.ready`.
  Publishing both from one call cannot page: the two events are evaluated
  concurrently by the stateful evaluation queue, and when the recovery lands
  first the incident never opens, while when it lands second it resolves the
  alert before the queued routing job runs - the Dispatcher then skips a
  resolved alert and sends nothing. Splitting them leaves the operator to
  clear only after the Discord page has arrived.

## Risks / Trade-offs

- **Stream subject add** → Mitigation: publisher `ensureStream` already
  appends missing subjects; EventWriter consumer is additive.
- **Noisy node flaps** → Mitigation: StatefulAlertRule cooldown/renotify
  (same 300s / 6h floor as sweep unavailability).
- **Device identity** → Mitigation: set `device_uid` when an `ocsf_devices`
  hostname matches the Node name; otherwise leave it null and still page.
- **Demo route is operator data** → Mitigation: update it after deploy via
  the notification API/UI, not a schema migration.

## Migration Plan

1. Ship collector + EventWriter + seeded rules.
2. On demo, add/replace the notification route to match the seeded rule and
   fan out to `demo-discord`.
3. Test-send through that route; confirm a `sent` delivery and Discord.
4. Rollback: disable the StatefulAlertRule; collector flag
   `k8sInventory.nodes.enabled=false` restores prior RBAC/publish.

## Open Questions

None. Empty-string route rejection is in scope because it is the masking
bug that kept Discord silent even if node alerts already existed.
