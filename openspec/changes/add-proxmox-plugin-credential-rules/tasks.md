## 1. Proposal Approval
- [x] 1.1 Review and approve the OpenSpec proposal.
- [x] 1.2 Decide final wording for read-only first iteration versus future mutating management actions.

## 2. Network Credential Rules
- [x] 2.1 Add Elixir migration(s) under `elixir/serviceradar_core/priv/repo/migrations/` for platform-schema credential rule tables and indexes.
- [x] 2.2 Add Ash resources/actions for credential rules, encrypted secret references, rule tests, and redacted reads.
- [x] 2.3 Implement SRQL preview and conflict detection for target queries.
- [x] 2.4 Implement agent/site scope validation and per-agent materialization boundaries.
- [x] 2.5 Add tests proving plaintext secrets are never returned by API/UI reads.
- [ ] 2.6 Add SSH private key credential type with AshCloak encryption, passphrase support, redacted fingerprint display, and rotation metadata.

## 3. Settings UI
- [ ] 3.1 Add Settings -> Networks -> Credential Rules navigation.
- [ ] 3.2 Build list/create/edit/disable/test flows using existing settings UI patterns.
- [ ] 3.3 Add Proxmox PVE API provider preset fields for token ID, token secret, realm, and TLS policy.
- [ ] 3.4 Add SRQL target preview, matched-device sample, and per-agent distribution preview.
- [ ] 3.5 Add LiveView/controller tests for authorization, validation, redaction, and preview behavior.

## 4. Policy Reconciliation and Agent Config
- [x] 4.1 Extend plugin target policy reconciliation to bind credential rules to resolved device batches.
- [x] 4.2 Deliver only scoped credential material to the assigned edge agent over existing authenticated config channels.
- [ ] 4.3 Redact sensitive fields from logs, API responses, plugin status, and cached config debug output.
- [ ] 4.4 Add tests for priority resolution, equal-priority conflicts, disabled rules, and agent-scope denial.

## 5. Proxmox Plugin
- [x] 5.1 Add first-party Go WASM plugin package under `go/cmd/wasm-plugins/proxmox/`.
- [x] 5.2 Implement SDK host-HTTP Proxmox client for version, cluster, nodes, QEMU, and LXC status/config endpoints.
- [x] 5.3 Emit `serviceradar.device_discovery.v1` devices for PVE nodes, QEMU VMs, and LXC containers.
- [x] 5.4 Emit resource-efficiency metrics and bottleneck events for CPU, memory, disk, I/O wait where available.
- [x] 5.5 Add plugin manifest, config schema, fixture tests, and TinyGo build coverage.
- [x] 5.6 Add first-party plugin bundle registration and publish/sign verification wiring.
- [x] 5.7 Add env-driven local Proxmox API smoke test path for command-line validation without agent deployment.
- [x] 5.8 Add env-driven live Go plugin smoke test for direct Proxmox inventory validation without agent deployment.
- [x] 5.9 Add best-effort Proxmox infrastructure enrichment for node storage, network interfaces, disks, and Ceph health.
- [x] 5.10 Emit infrastructure metrics/events for storage pressure, disk health, and Ceph health while preserving partial success for least-privilege tokens.
- [x] 5.11 Confirm Proxmox syslog/journal API endpoints are read-only log access paths and keep log-forwarding configuration out of inventory collection.

## 6. Enrichment Ingestion
- [x] 6.1 Add provider-neutral virtualization schema/resources for clusters, hypervisor hosts, guests, host relationships, datastores/storage pools, disks, NICs, and provider extension fields.
- [x] 6.2 Add typed Proxmox enrichment payload validation in core-elx/web-ng ingestion.
- [x] 6.3 Map PVE nodes, QEMU guests, and LXC guests into canonical inventory plus virtualization tables, avoiding infrastructure blobs in device metadata.
- [x] 6.4 Persist hosted virtualization topology relations without creating physical adjacency.
- [ ] 6.5 Add SRQL filters/fields for Proxmox provider, cluster, node, guest type, VMID, storage, Ceph health, and enrichment freshness.
- [ ] 6.6 Add ingestion tests for duplicate identity, stale enrichment, secret rejection, and provider-neutral virtualization records.
- [x] 6.7 Leave vSphere/vCenter provider IDs and schema affordances in place without implementing vCenter ingestion yet.

## 7. UI and Documentation
- [ ] 7.1 Add web-ng Proxmox console session API, authorization policy, short-lived tickets, and audit events.
- [ ] 7.2 Add edge agent/gateway console broker for SSH host sessions and optional Proxmox termproxy/vncwebsocket sessions.
- [ ] 7.3 Build React/xterm.js terminal component mounted from Phoenix/LiveView using existing web-ng React integration.
- [ ] 7.4 Add device details actions for "Open PVE shell", "Open VM console", and "Open LXC console" only when policy and reachability allow them.
- [ ] 7.5 Add idle timeout, absolute session timeout, resize handling, close handling, and error rendering.
- [ ] 7.6 Add tests for console RBAC, ticket single-use semantics, credential redaction, and agent-scope denial.

## 8. UI and Documentation
- [ ] 8.1 Surface Proxmox enrichment on device details and topology views.
- [ ] 8.2 Add dashboard-ready resource efficiency panels backed by SRQL/metrics data.
- [ ] 8.3 Document required Proxmox API token permissions, SSH key permissions, and least-privilege examples.
- [ ] 8.4 Document example credential rules for single site and multi-datacenter deployments.
- [ ] 8.5 Document console session security model, audit events, and timeout behavior.
- [ ] 8.6 Run focused quality commands for Go plugin, Elixir migrations/UI, and OpenSpec validation.

## 9. Logs, Metrics, and Alerts
- [x] 9.1 Add typed ingestion/schema support for Proxmox infrastructure details: storage, disk, network, Ceph, and future environmental sensor sources.
- [x] 9.2 Surface storage, disk, network, Ceph, and environmental summaries in web-ng device details from the virtualization/infrastructure schema, not raw metadata.
- [ ] 9.3 Add alert rule support for metric windows and baselines, including CPU above baseline for a sustained period.
- [ ] 9.4 Add Proxmox log-forwarding setup flow that configures host logging toward the ServiceRadar syslog collector through an audited agent/SSH action when no PVE API mutation path is available.
- [ ] 9.5 Correlate logs/events to canonical devices and expose device-scoped logs on the device details page.
