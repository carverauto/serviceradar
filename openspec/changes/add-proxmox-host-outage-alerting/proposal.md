# Alert on Proxmox VM/host outages

## Why

Consider a hypothetical test cluster whose kubeconfig points directly to a
control-plane VM. A Proxmox host OOM-kills that VM's process between monitoring
polls. The configured Kubernetes API endpoint becomes unavailable, so clients
lose cluster access even if other API endpoints could still serve requests.
A later memory sample can look healthy after the process has been killed.
This example is invented solely to illustrate the failure mode; it describes
no deployment or observed incident.

Availability checks, Kubernetes readiness conditions, and host OOM events
answer different questions. The proposal adds the missing Proxmox condition
signals while reusing the existing ServiceCheck and notification mechanisms.

Repository context:

- The Proxmox WASM plugin (`go/cmd/wasm-plugins/proxmox/`) emits ratio-based
  ok/warning/critical pressure summaries for node/guest CPU, memory, disk,
  and IO-wait. Guest running/stopped counters do not provide a distinct
  running-to-stopped condition event, and the plugin lacks OOM-killer detection.
- `fix-proxmox-inventory-plugin-reliability` documents incorrect guest runtime
  status. Its status correction is a prerequisite for availability alerting.
- `add-plugin-alert-rules` supplies the provisioning mechanism: manifest
  `alert_rules:` entries materialize as disabled `stateful_alert_rules` on
  package approval. An operator explicitly enables them.
- The `ServiceCheck` -> `Alert` -> `Notifications` pipeline supports baseline
  availability monitoring through `/api/v2/service-checks` and
  `/api/v2/alerts`, independently of the Proxmox plugin.
- `add-k8s-node-readiness-alerts` covers Kubernetes Node readiness through the
  existing notification platform. Its recorded JSON:API gap for
  `StatefulAlertRule` is separately scoped as `add-alert-rule-json-api`;
  arbitrary rule provisioning is outside this proposal.

## What Changes

- **Baseline availability configuration:** provision `ServiceCheck` rows for
  operator-selected Kubernetes API endpoints and Proxmox hosts using the
  existing API. Choose an executor with target reachability and configure
  notification routing. This is independent operational setup, not plugin
  implementation gated on this proposal.
- **Guest availability events:** emit
  `com.carverauto.proxmox.guest_availability_changed` on a guest's
  running-to-stopped transition, separate from periodic pressure summaries.
- **Host OOM-kill detection:** scan each node's kernel log since the last
  successful poll and emit `com.carverauto.proxmox.node_oom_kill`, carrying
  the node, killed process when parseable, and raw log line as event detail.
- **Manifest alert catalog:** declare `guest-availability-changed` and
  `node-oom-kill` under `alert_rules:` so package approval provisions disabled
  rules that an operator can enable without hand-authoring definitions.

## Impact

- Affected specs: `proxmox-host-monitoring` (new capability).
- Affected code: `go/cmd/wasm-plugins/proxmox/`, including guest transition
  handling, node log collection, and `plugin.yaml`.
- No additional core provisioning mechanism is anticipated beyond
  `add-plugin-alert-rules`.
- Prerequisites: `fix-proxmox-inventory-plugin-reliability` and completion of
  `add-plugin-alert-rules`.
- This proposal adds a separate capability without modifying either
  prerequisite's pending spec deltas.
- Baseline checks and readiness alert configuration remain separate from
  the plugin implementation; see `tasks.md` sections 0 and 1.
