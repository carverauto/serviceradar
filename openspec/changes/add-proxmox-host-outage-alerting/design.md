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

- Which Proxmox API log endpoint and permissions provide the required kernel
  entries? If unavailable, can the existing SSH console-access path supply
  them within the plugin execution and credential contracts?
- What execution vantage point keeps baseline checks available when the
  monitored host fails? This must be chosen for each deployment.
