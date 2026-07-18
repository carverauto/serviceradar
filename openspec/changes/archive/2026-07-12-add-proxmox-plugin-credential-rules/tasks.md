## 1. Proposal Approval
- [x] 1.1 Review and approve the OpenSpec proposal.
- [x] 1.2 Decide final wording for read-only first iteration versus future mutating management actions.

## 2. Network Credential Rules
- [x] 2.1 Add Elixir migration(s) under `elixir/serviceradar_core/priv/repo/migrations/` for platform-schema credential rule tables and indexes.
- [x] 2.2 Add Ash resources/actions for credential rules, encrypted secret references, rule tests, and redacted reads.
- [x] 2.3 Implement SRQL preview and conflict detection for target queries.
- [x] 2.4 Implement agent/site scope validation and per-agent materialization boundaries.
- [x] 2.5 Add tests proving plaintext secrets are never returned by API/UI reads.
- [x] 2.6 Add SSH private key credential type with AshCloak encryption, passphrase support, redacted fingerprint display, and rotation metadata.

## 3. Settings UI
- [x] 3.1 Add Settings -> Networks -> Credential Rules navigation.
- [x] 3.2 Build list/create/edit/disable/test flows using existing settings UI patterns.
- [x] 3.3 Add explicit Proxmox auto-discovery opt-in for credential trials; keep SRQL-scoped targeting as the default.
- [x] 3.4 Add Proxmox PVE API provider preset fields for token ID, token secret, realm, and TLS policy.
- [x] 3.5 Add SRQL target preview, matched-device sample, and per-agent distribution preview.
- [x] 3.6 Add LiveView/controller tests for authorization, validation, redaction, and preview behavior.

## 4. Policy Reconciliation and Agent Config
- [x] 4.1 Extend plugin target policy reconciliation to bind credential rules to resolved device batches.
- [x] 4.2 Deliver only scoped credential references and broker grants to assigned edge agents; do not send decrypted credential material to plugins or generic command payloads.
- [x] 4.3 Redact sensitive fields from logs, API responses, plugin status, and cached config debug output.
- [x] 4.4 Add tests for priority resolution, equal-priority conflicts, disabled rules, and agent-scope denial.
- [x] 4.5 Deny hidden command `transmit_payload` values that contain raw credential material.

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
- [x] 5.12 Remove fake hard-coded PVE host, token, node, and guest sample payloads from the TinyGo JSON priming workaround.

## 6. Enrichment Ingestion
- [x] 6.1 Add provider-neutral virtualization schema/resources for clusters, hypervisor hosts, guests, host relationships, datastores/storage pools, disks, NICs, and provider extension fields.
- [x] 6.2 Add typed Proxmox enrichment payload validation in core-elx/web-ng ingestion.
- [x] 6.3 Map PVE nodes, QEMU guests, and LXC guests into canonical inventory plus virtualization tables, avoiding infrastructure blobs in device metadata.
- [x] 6.4 Persist hosted virtualization topology relations without creating physical adjacency.
- [x] 6.5 Add SRQL filters/fields for Proxmox provider, cluster, node, guest type, VMID, storage, Ceph health, and enrichment freshness.
- [x] 6.6 Add ingestion tests for duplicate identity, stale enrichment, secret rejection, and provider-neutral virtualization records.
- [x] 6.7 Leave vSphere/vCenter provider IDs and schema affordances in place without implementing vCenter ingestion yet.

## 7. UI and Documentation
- [x] 7.1 Add web-ng Proxmox console session API, authorization policy, short-lived tickets, and audit events.
- [x] 7.2 Add edge agent/gateway console broker for SSH host sessions and explicitly reject native Proxmox termproxy/vncwebsocket modes until a connector is enabled.
- [x] 7.3 Build React/xterm.js terminal component mounted from Phoenix/LiveView using existing web-ng React integration.
- [x] 7.4 Add device details action for "Open PVE shell"; keep VM/LXC console actions hidden until a supported native guest console path is available.
- [x] 7.5 Add idle timeout, absolute session timeout, resize handling, close handling, and error rendering.
- [x] 7.6 Add tests for console RBAC, ticket single-use semantics, credential redaction, and agent-scope denial.
- [x] 7.7 Add first-party Proxmox console plugin package metadata and materialize `console_access` credential rules to scoped console streaming assignments.
- [x] 7.8 Add agent-hosted SSH console connector for PVE host shells, with device target metadata propagated from core through the ERTS broker to the agent/plugin config.
- [x] 7.9 Remove agent-local Proxmox console credential files and keep console credentials on approved session-scoped broker/certificate paths.

## 8. UI and Documentation
- [x] 8.1 Surface Proxmox enrichment on device details and topology views.
- [x] 8.2 Add dashboard-ready resource efficiency panels backed by SRQL/metrics data.
- [x] 8.3 Document required Proxmox API token permissions, SSH key permissions, and least-privilege examples.
- [x] 8.4 Document example credential rules for single site and multi-datacenter deployments.
- [x] 8.5 Document console session security model, audit events, and timeout behavior.
- [x] 8.6 Run focused quality commands for Go plugin, Elixir migrations/UI, and OpenSpec validation.

## 9. Logs, Metrics, and Alerts
- [x] 9.1 Add typed ingestion/schema support for Proxmox infrastructure details: storage, disk, network, Ceph, and future environmental sensor sources.
- [x] 9.2 Surface storage, disk, network, Ceph, and environmental summaries in web-ng device details from the virtualization/infrastructure schema, not raw metadata.
- [x] 9.3 Add alert rule support for metric windows and baselines, including CPU above baseline for a sustained period.
- [x] 9.4 Deferred: deploy Vector on PVE hosts through an operator-managed playbook and forward to the ServiceRadar OTEL log collector instead of building an in-product SSH/rsyslog mutator in this change.
- [x] 9.5 Correlate logs/events to canonical devices and expose device-scoped logs on the device details page.
