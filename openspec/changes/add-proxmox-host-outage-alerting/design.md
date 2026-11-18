## Context

### Synthetic illustration

Imagine a disposable test environment with a control-plane VM used directly
as the kubeconfig bootstrap/API address. A memory-intensive workload on its
Proxmox host causes the Linux OOM killer to terminate the VM process between
polls. Clients using that address lose all access through their configured
endpoint. The next memory-pressure sample is below its warning threshold
because killing the process freed memory.

This is a hypothetical example constructed from the failure mechanism, not
an account of an operator environment. It assumes no particular fleet size,
network topology, agent status, notification setup, or credential history.
The useful distinction is between endpoint reachability, guest runtime state,
and the host log evidence explaining the stop. A stopped guest alone does
not establish OOM as the cause.

### Repository mechanisms

- `go/cmd/wasm-plugins/proxmox/summaries.go` emits periodic resource-pressure
  summaries. Those samples do not provide guest-stop or OOM-kill events.
- `discovery.go` derives availability from guest runtime status;
  `fix-proxmox-inventory-plugin-reliability` tracks correcting that status.
  Availability alerts depend on the corrected observations.
- `add-plugin-alert-rules` defines manifest `alert_rules:` materialization on
  package approval as disabled rules namespaced `plugin:<package>:<name>`.
  A package must not automatically arm notifications or overwrite operator
  choices on update.
- `ServiceCheck` -> `AlertGenerator` -> `Alert` -> `Notifications` supplies
  baseline monitoring independently of the plugin. `POST
  /api/v2/service-checks` supports raw targets and ports without requiring
  a device association. Operators must configure execution and notification
  routing for their own deployment.
- `add-k8s-node-readiness-alerts` covers Kubernetes Node readiness. Its
  recorded lack of a `StatefulAlertRule` JSON:API surface is a separate
  concern, scoped as `add-alert-rule-json-api`. Manifest provisioning covers
  this proposal without that API extension.

## Goals / Non-Goals

**Goals**
- Detect guest stops and host OOM kills as distinct condition events.
- Detect guests the hypervisor has paused, which the guest status alone
  reports as running, and a node datastore at critical capacity.
- Complement endpoint checks and Kubernetes readiness notifications with
  host-level evidence.
- Reuse `ServiceCheck`, `Notifications`, and plugin-manifest alert rules.

**Non-Goals**
- Correlating guest stops with Proxmox task logs to distinguish maintenance
  from unexpected stops. Every running-to-stopped transition is alertable;
  operators can disable the rule for planned maintenance.
- Adding a generic alert-rule JSON:API surface; that belongs to
  `add-alert-rule-json-api`.
- Changing Kubernetes API endpoint failover or deployment topology.
- Reimplementing either prerequisite or editing its pending spec deltas.

## Decisions

- **Use baseline ServiceChecks for reachability.** Ping/TCP checks against
  selected endpoints and hosts do not depend on successful Proxmox inventory
  collection. Guest events and OOM logs add runtime state and cause evidence.
- **Add a separate capability.** `proxmox-host-monitoring` is ADDED-only and
  depends on the inventory reliability and manifest-rule changes, avoiding
  concurrent edits to those changes' requirements.
- **Read OOM evidence from kernel logs.** Poll-time memory ratios can miss a
  spike; a retained OOM-killer log entry records the kill after pressure
  subsides. Scan since the last successful poll and avoid repeat events for
  entries already processed.
- **Trust the runtime state over the status for a running guest.** Proxmox
  reports `status: running` while a QEMU process exists, including when the
  guest is paused or stopped on an I/O error. The runtime state is the only
  field that tells the two apart, so a non-running runtime state makes the
  guest not available. Containers have no such state and keep their status.
- **Give capacity its own event with a recovery.** The pressure summary is
  band-classified and de-duplicated, and a return to `ok` is the absence of
  further events. An alert needs an explicit recovery to close, so the
  critical band gets a separate scoped condition and the summaries are left
  alone. The event omits the ratio and threshold fields, so the plugin's band
  decides membership and the agent's hysteresis does not hold the alert open
  below the critical threshold.
- **Recover through the existing condition scope, not plugin memory.** The
  WASM plugin is re-instantiated on every check and has no state between
  polls, so it cannot compare with a previous poll or know that it emitted an
  event before. Each node of each Proxmox target gets two condition scopes,
  a guest-runtime scope for its guest list and a node-storage scope for its
  storage, which is already fetched per node. Separate scopes keep one
  condition's marker from clearing the other condition's keys, so each scope
  id is the target discriminator, the scope name (`guest-runtime` or
  `node-storage`) and the node. Every scope id and condition key in this
  change, including the guest-availability and OOM keys, starts with
  the target discriminator the plugin already
  uses as its condition-key prefix, because one assignment polls several
  targets through one agent debouncer and two targets can share a node name
  and VMID. A guest key is that discriminator, the node, the guest type and
  the VMID; a datastore key is that discriminator, the node and the datastore
  name, with byte counts kept as event detail so the key stays stable while
  the datastore stays critical. A scope read fully emits its active
  conditions and a scope-complete marker listing their keys, with an empty
  list when nothing is active, which is what clears its last key. The
  guest-runtime marker also lists a QEMU guest the list shows running whose
  runtime state could not be read, with no condition event for it. That is
  safe because the agent never opens a key from a marker: a listed key the
  agent remembers stays open and an unknown one is ignored, so a failed
  per-guest read holds only that guest's alert and raises none. Because the
  key is derived from the target, node, type and VMID, the plugin can list it
  without memory. The marker omits a guest the list shows stopped or no
  longer contains, so stopping or deleting a paused guest clears its alert.
  The agent's condition debounce already forwards a condition event on first
  sight, on a level change and on its unchanged-level refresh, and forwards
  one clear for a key it still remembers in a scope whose marker no longer
  lists it. A scope that could not be read fully emits no marker, which the
  agent treats as a partial view of that scope only. Another scope's marker,
  an agent restart or the expiry of a remembered key clears nothing, so such
  an alert stays open until an operator resolves it.
- **Keep rule activation explicit.** Approving the plugin package creates
  disabled rules. Operators enable them through the existing alert-rules UI.

## Risks / Trade-offs

- Planned guest stops can generate alerts. Task-log correlation is deferred;
  maintenance procedures must account for rule activation.
- A check executor sharing the monitored failure domain may stop collecting
  when its target fails. Select an independent execution vantage point where
  possible and verify reachability before relying on baseline checks.
- The plugin currently uses the Proxmox REST API. Kernel-log access needs an
  implementation investigation to select a supported log endpoint and its
  required permissions. Any alternative SSH path must use the unified
  credential model rather than introducing a separate secret store.

## Migration Plan

1. Configure Kubernetes readiness alerts and baseline ServiceChecks using
   their existing mechanisms, independently of plugin development.
2. Land the guest status correction from
   `fix-proxmox-inventory-plugin-reliability`.
3. Complete `add-plugin-alert-rules`.
4. Implement guest transitions, OOM log detection, and manifest entries.
5. Publish a new plugin package version; the operator approves the package
   and explicitly enables its rules.
6. Exercise guest-stop and OOM scenarios in a disposable test environment
   and verify alert delivery through the selected notification route.

## Open Questions

- Does the guest list return the runtime state, or does each running guest
  need its own status call? A per-guest call adds one request per running
  guest per poll and a new entry in the agent's Proxmox path allowlist.
- The guest-availability and OOM-kill requirements are also worded as
  cross-poll comparisons ("previous poll", "since the last successful poll"),
  which the stateless plugin cannot evaluate. Before implementation they need
  the same condition-scope treatment or an explicit state source.
- Which Proxmox API log endpoint and permissions provide the required kernel
  entries? If unavailable, can the existing SSH console-access path supply
  them within the plugin execution and credential contracts?
- What execution vantage point keeps baseline checks available when the
  monitored host fails? This must be chosen for each deployment.
