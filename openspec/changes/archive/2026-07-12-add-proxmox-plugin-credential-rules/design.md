## Context
Proxmox support spans discovery, inventory enrichment, metrics, topology, console access, credential handling, and edge execution. The existing mapper already proves a minimal Proxmox API path, but it is configured as mapper endpoint data. The desired operator experience is inventory-driven: discovered PVE hosts are candidates, credential rules decide which edge agents may try which credentials, the Proxmox plugin enriches the already-known devices, and authorized operators can open scoped consoles through the same edge reachability model.

## Goals / Non-Goals
- Goals:
  - Make credential scoping a reusable platform concept, not a Proxmox-only form.
  - Run Proxmox interrogation from edge agents that can reach the PVE API.
  - Keep SRQL evaluation and credential resolution in the control plane.
  - Emit typed device discovery/enrichment payloads and metrics through existing plugin result ingestion.
  - Preserve hosted virtualization topology as `HOSTED_ON` semantics, not physical adjacency.
  - Provide browser terminal access to PVE host shells first, and keep guest console requests safely unavailable until a native Proxmox guest connector is enabled.
- Non-Goals:
  - First-iteration power, migration, clone, delete, backup, or configuration mutation operations.
  - Full digital-twin modeling of Proxmox Linux bridges, SDN zones, VLANs, and storage internals.
  - A separate standalone checker daemon.
  - Default session recording or keystroke capture.

## Library Decision
Use Go for the first-party Proxmox plugin, but do not embed a normal Proxmox Go client in the WASM artifact.

Rationale:
- ServiceRadar first-party plugins are currently Go/TinyGo-oriented, and the Go SDK already has mature result, HTTP, plugin-input, and device discovery helpers.
- The repository already has Go Proxmox mapper logic that can be reused as a behavioral reference.
- External Go clients such as Telmate and luthermonson are useful references for endpoint coverage and response models, but they assume normal `net/http` execution and broad API surfaces.
- Rust `proxmox-client` is promising and type-rich, but its async `reqwest`/Tokio model is not aligned with the current sandboxed ServiceRadar SDK execution path.
- Direct REST calls through the ServiceRadar host HTTP wrapper keep allowlist enforcement, redaction, timeouts, and future audit hooks in one place.

## Credential Rules Model
Add a deployment-scoped `NetworkCredentialRule` resource with:
- name, description, enabled flag, priority, and credential kind
- protocol/provider, initially including `proxmox_pve_api`
- authentication method, initially Proxmox API token and optional ticket login for compatibility
- encrypted secret reference(s), never plaintext API response fields
- SRQL `target_query` used to select candidate devices
- agent, partition, or edge-site scope used to limit where the rule may execute
- allowed host/port constraints derived from selected devices, with an explicit operator override path
- test status, last tested time, and redacted failure reason

Credential kinds must include both API credentials and console credentials:
- `proxmox_pve_api_token`
- `ssh_private_key`
- `ssh_password` only where explicitly enabled by policy
- future `proxmox_console_ticket` as ephemeral runtime material, never stored as a long-lived secret

Resolution order:
1. Per-device credential override, when explicitly configured for the same provider.
2. Enabled credential rules whose SRQL query matches the device and whose agent/site scope includes the assigned edge agent.
3. Auto-discovered Proxmox candidates only when the matched rule explicitly enables auto-discovery credential trials in settings.
4. Highest priority rule wins when multiple rules match.
5. Equal-priority conflicts must be surfaced for operator resolution instead of trying every secret.

Auto-discovery has two separate phases:
- Fingerprinting may probe candidate devices without credentials using safe unauthenticated checks such as TCP/HTTPS evidence, TLS/service metadata, and version endpoint behavior.
- Credential trials are disabled by default for discovered candidates that do not match a rule SRQL query. Enabling auto-discovery on a rule is an explicit admin opt-in and still remains limited by the configured agent, gateway, or partition scope.

## Proxmox Plugin Execution
The Proxmox plugin receives a resolved `serviceradar.plugin_inputs.v1` payload containing concrete target devices and redacted policy metadata. The control plane includes credential broker grants and secret references, not decrypted credential material. The edge-side credential broker is the only component allowed to resolve a secret reference and inject a credential into an outbound Proxmox request.

For local development and smoke tests, operators MAY supply Proxmox API credentials through test-only environment variables. Production agent/plugin assignments should use credential rules and broker grants instead of reusable agent-local secrets.

The plugin calls PVE API endpoints through SDK host HTTP:
- `/version`
- `/nodes`
- `/cluster/status`
- `/cluster/resources`
- `/nodes/{node}/status`
- `/nodes/{node}/storage`
- `/nodes/{node}/network`
- `/nodes/{node}/disks/list`
- `/nodes/{node}/ceph/status`
- `/nodes/{node}/ceph/osd`
- `/nodes/{node}/ceph/pool`
- `/nodes/{node}/ceph/fs`
- `/nodes/{node}/qemu/{vmid}/status/current`
- `/nodes/{node}/lxc/{vmid}/status/current`
- `/nodes/{node}/qemu/{vmid}/config`
- `/nodes/{node}/lxc/{vmid}/config`

The first pass should use API tokens. Ticket login may be supported only when needed for environments that cannot issue tokens, with CSRF handling contained in the plugin and no credential-bearing URLs.

Optional infrastructure endpoints must be partial-success paths. A credential with `Sys.Audit`/VM audit permissions can still collect basic nodes, guests, and network data; additional `Datastore.Audit`, disk, Ceph, or syslog privileges unlock deeper storage, disk, Ceph, and log capabilities without requiring a different plugin configuration. Missing permissions are emitted as redacted warnings, not target failures.

The PVE API exposes read paths for node syslog and journal data, but not an API shape for configuring remote syslog forwarding. Inventory collection must not poll syslog/journal as a substitute for log ingestion. Proxmox log forwarding is deferred from the first ServiceRadar plugin implementation: the preferred path is to deploy Vector on PVE hosts with an operator-managed playbook, then forward logs to the ServiceRadar OTEL log collector. ServiceRadar should still correlate those logs back to canonical devices once they arrive, but it should not build a direct SSH/rsyslog mutator in this change.

## Enrichment Contract
The plugin result includes:
- normal plugin status and summary
- `serviceradar.device_discovery.v1` devices for PVE nodes, QEMU VMs, and LXC containers
- `proxmox_enrichment` details for cluster/node/guest metadata
- infrastructure details for node storage, disks, network interfaces, and Ceph health where permissions allow
- metrics for CPU, memory, disk, storage, uptime, guest status, Ceph health, and resource-efficiency ratios
- hosted topology hints linking VM/LXC guests to PVE nodes

Infrastructure details must not be treated as arbitrary device metadata long term. The plugin details payload is an ingestion boundary, not the durable query model. Durable storage should use provider-neutral virtualization and infrastructure tables that can support both Proxmox and future vSphere/vCenter inventory:
- hypervisor clusters and cluster membership
- hypervisor hosts mapped to canonical inventory devices
- virtual guests mapped to canonical inventory devices
- host/guest relationship edges
- datastore/storage pools and backing provider IDs
- physical disks and health/SMART summaries
- virtual and physical NICs, bridges, bonds, VLANs, and SDN objects
- storage/compute/network/environmental metric samples or rollups where they are not already covered by existing metrics tables
- provider-specific extension JSON only for fields that have no stable cross-provider meaning

Core ingestion maps this into canonical device inventory:
- PVE nodes become type `Server`, role `hypervisor`, vendor `Proxmox`, OS `Proxmox VE`
- QEMU guests become type `Virtual`
- LXC guests become type `Virtual` with container metadata
- hosted links use the existing hosted virtualization relation family
- raw API tokens, ticket values, cookies, and passwords are rejected from enrichment payloads

Environmental data is not first-class in the documented PVE node API beyond system status, disk health, and Ceph/storage telemetry. True chassis-level temperature, fan, power, and PSU data should be modeled as an extension source that can use IPMI, Redfish, SNMP, lm-sensors, or BMC-specific APIs when available, then attach those metrics to the same canonical PVE node.

## Console Access
Proxmox console access should reuse the Scion webpty pattern, adapted to ServiceRadar's control plane and edge-agent topology:
1. Browser opens a web-ng console route for a canonical Proxmox node. QEMU and LXC guest routes are modeled but remain unavailable until native guest console support is enabled.
2. Web-ng authorizes the user, creates a short-lived single-use console session ticket, and chooses the edge agent allowed by credential rule scope and device reachability.
3. Browser connects to a web-ng websocket using the session ticket.
4. Web-ng proxies terminal frames to the agent/gateway console broker over the existing authenticated edge channel.
5. The agent broker opens SSH to the PVE host using an encrypted, scoped SSH key credential. Proxmox `termproxy` / `vncwebsocket` for QEMU/LXC consoles are future connector modes and must return an unavailable/unsupported result instead of attempting credential resolution until enabled.
6. Terminal data, resize events, close events, and errors use a small typed websocket protocol similar to Scion's `data`, `resize`, and `close` messages.

The browser terminal should be a React/xterm.js component mounted through the existing `phx-react-ng`/client-side React hook approach in `elixir/web-ng`. Scion's terminal UX is a useful source for fit addon behavior, resize debouncing, clipboard handling, and terminal focus, but the ServiceRadar wrapper must follow web-ng styling and authorization patterns.

Console access must be separately permissioned from read-only Proxmox enrichment. A user who can view device details does not automatically get a shell.

## UI Shape
Settings gains a reusable credentials area, not a Proxmox-only page:
- Settings -> Networks -> Credential Rules
- create/edit/test rule
- choose provider/auth method
- store or rotate secrets through secret-reference fields
- define SRQL target query and preview matching devices
- choose eligible agent/site scope
- view which agents will receive assignments
- show last execution/test status without exposing secret values

Proxmox-specific UX can be a provider preset inside this area and a plugin-specific enrichment status panel in device details.

## Rollout Shape
Keep PRs reviewable and stackable:
1. Spec and data model for network credential rules.
2. UI/API for credential rule CRUD, preview, and test.
3. Assignment reconciliation and agent config delivery for credential-scoped plugin policies.
4. Proxmox plugin package and unit tests.
5. Enrichment ingestion, SRQL fields, and device/topology UI.
6. Console session broker, React/xterm.js terminal UI, and SSH key credential support.
7. Docs and operational examples.

## Risks / Trade-offs
- Credential leakage is the highest risk. Mitigation: central redaction, no URL secrets, no plugin-side SRQL/API tokens, no generic hidden command payloads carrying decrypted credentials, and per-agent broker grants only.
- WASM plugin HTTP calls have less generated type safety than a full Proxmox client. Mitigation: keep endpoint coverage narrow, build local typed response structs, and use fixture-heavy tests.
- Existing mapper Proxmox behavior may drift from plugin behavior. Mitigation: extract or duplicate only stable normalization helpers with tests covering identical identities and hosted links.
- Proxmox APIs vary across versions and standalone/cluster installs. Mitigation: start with conservative endpoints and emit partial enrichment with clear capability flags when optional endpoints are unavailable.
- Browser shell access is high risk. Mitigation: separate RBAC permission, short-lived session tickets, strict agent/device credential scope, no default transcript recording, bounded idle/session timeouts, and audit events for session start/stop.
- Proxmox console websocket behavior differs by endpoint, auth mode, and PVE version. Mitigation: support SSH-to-host first, then add Proxmox-native VM/LXC console proxy behind capability detection and tests.

## References
- Proxmox VE API viewer: https://pve.proxmox.com/pve-docs/api-viewer/
- Proxmox VE API wiki: https://pve.proxmox.com/wiki/Proxmox_VE_API
- Go Telmate client: https://github.com/Telmate/proxmox-api-go
- Go luthermonson client: https://github.com/luthermonson/go-proxmox
- Rust proxmox-client crate: https://docs.rs/crate/proxmox-client/latest
- Official Proxmox Rust crates: https://github.com/proxmox/proxmox-rs
- Scion PTY reference paths: `~/src/scion/pkg/wsprotocol/protocol.go`, `~/src/scion/pkg/hub/pty_handlers.go`, `~/src/scion/pkg/runtimebroker/pty_handlers.go`, `~/src/scion/web/src/components/pages/terminal.ts`
