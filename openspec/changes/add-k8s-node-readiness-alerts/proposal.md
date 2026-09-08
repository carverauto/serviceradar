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
  `js/cli/ensure_k8s_node_alerts.py`, not by hand in the UI. The CLI/Python
  helpers fail closed if the named channel is absent or disabled.

## Recorded gaps (not closed by this change)

- **The JSON:API cannot create a NotificationChannel.**
  `/api/v2/notification-channels` exposes only `index` - no create, update,
  enable/disable, or fetch-by-id - so a Discord channel must already exist
  before either helper runs, and both fail closed when it does not. The
  channel resource is read-only there because `secret_refs` is writable on
  the resource while no endpoint can mint a Discord incoming-webhook URL, so
  a create route could never produce a channel that can deliver. `secret_refs`
  is additionally withheld from the representation, so stored webhook material
  is never readable back over `/api/v2`. Creating a channel remains a settings
  UI action; giving the API a create path that takes a webhook URL is
  follow-up work.
- **`StatefulAlertRule` has no JSON:API surface.** Unlike the notification
  resources, `ServiceRadar.Observability.StatefulAlertRule` carries no
  `AshJsonApi.Resource` extension, so there is no `/api/v2` endpoint to
  create, edit, enable or disable a node-alert rule. The
  `k8s_node_not_ready` rule exists only because `RuleSeeder` seeds it, and
  the `observability-rule-management` scenario "Operator disable survives
  reseed" therefore has no API path - only the settings UI and the seeder.
  Exposing StatefulAlertRule on `/api/v2` is follow-up work.
- **`srctl` has no authentication flow at all.** It has no `login` command
  and no RFC 8628 device-code support (`go/pkg/cli` covers enrollment, TLS
  and NATS bootstrap only), so it cannot obtain the bearer token these
  endpoints require. That is why notification configuration ships on the JS
  CLI, which already has device-code auth. Bringing `srctl` to parity is
  recorded here as a gap rather than blocking node alerting.

- **Captured cluster data still committed outside `k8sinventory`.** This
  change regenerated the endpoint fixtures and examples in
  `go/pkg/k8sinventory`, `go/cmd/k8s-inventory` and the SRQL/netprobe docs
  pages onto documentation addresses (`198.51.100.0/24`, `192.0.2.0/24`) and
  an invented app naming scheme. It did NOT scrub the rest, and the map below
  is the whole of what is left, because a partial scrub that keeps the shape
  is the failure this record exists to prevent.

  Still committed, named by artifact and by value CLASS. The values
  themselves are deliberately not reproduced here: this file ships in the
  public repository, so transcribing them would spread the fingerprint that
  the follow-up change has to remove.

  - `helm/serviceradar/values.yaml`, the shipped default chart's simulated
    BGP peer list (roughly lines 676-800) - a real cluster's node naming
    scheme, the operator's cluster-wide peer ASN, the internal IPv4
    addressing plan, a routable upstream peer address with its own ASN, and
    an allocated public IPv6 prefix. This is the most widely distributed of
    the four and should be regenerated first.
  - `go/cmd/faker/config.json` and `go/cmd/faker/bgp_sim.go` - the same five
    classes, in shipped non-test source.
  - `helm/serviceradar/values-demo.yaml` - a `nodeSelector` pinning a
    workload to a real node hostname.
  - `go/pkg/trivysidecar` fixtures - agent identifiers derived from the same
    node naming scheme.

  The classes matter as much as the hostnames: an ASN plus an addressing plan
  plus a naming convention identifies an organization on its own, so a scrub
  that replaces only the names leaves the fingerprint, and the replacements
  must be invented rather than derived. Regenerating these changes faker and
  demo behaviour and touches published chart defaults, so they need their own
  change rather than being folded in here.

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
