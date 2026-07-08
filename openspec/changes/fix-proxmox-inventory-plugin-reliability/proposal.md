# Fix Proxmox Inventory Plugin Reliability

## Why

The proxmox-inventory WASM plugin does not reliably produce correct inventory.
Live investigation on demo surfaced several defects, most of which are downstream
of one root cause:

1. **Config-push churn (root blocker).** The agent receives a *new config
   version every ~1s* ("Applied new config from gateway", different `v…` hash
   each time) and relaunches the plugin ("module closed with context canceled")
   before a full-cluster enumeration can finish. Three contributing sources were
   found and fixed (credential-broker grant re-mint churning the assignment row;
   a version-unaware config *push*; `download_token_epoch` folded into the
   version hash), but a residual per-push version rotation remains: something in
   the hashed `version_payload` (checks/sync/sysmon/snmp/plugins/addons/…) still
   changes on nearly every generation. Until this stops, guests are never
   enriched, so most land with **no IP**, and DIRE has nothing to merge on.

2. **Guests/nodes created without IPs.** Because enumeration is cut off (and
   because agentless/stopped guests have no address), many guest and node
   devices are created with no IP. Operator expectation: **do not create a
   device with no IP address** (a stopped VM with no static/cloud-init address
   should not appear).

3. **Wrong running/stopped status.** Stopped VMs/LXCs are reported as
   `running`. The plugin must report the true runtime status.

4. **Identity fragmentation → DIRE duplicates.** The same guest appears as
   multiple devices (`proxmox:vm:<name>`, `proxmox:vm:<MAC>`,
   `proxmox:v2:<cluster>:vm:<vmid>`), and the same node appears multiple times
   (some with IP, some without). Node/guest identity must be emitted
   deterministically so DIRE collapses each physical guest/node to one device.

Definition of done (operator-level, not "green in /services"): every *running*
guest with an address is a single device with its IP; stopped/address-less
guests are not created as IP-less rows; status is accurate; nodes are not
duplicated; a full cluster enumerates within the poll window without the plugin
being relaunched mid-run.

## What Changes

- **Stop the residual config-push churn** so a stable config is not re-versioned
  and re-pushed every second. Instrument `compute_version_hash`'s
  `version_payload` per-component to identify the rotating field, then make that
  field deterministic/stable (or exclude it from the version hash, as done for
  `download_token_epoch`). Keep the already-landed fixes (reconciler grant
  normalization, version-aware `push_config`, epoch removal).
- **Do not emit IP-less guest/node devices.** In the plugin's device-discovery
  builder, only emit a guest/node as a `DiscoveredDevice` when a usable IP was
  resolved (config `netN`/`ipconfigN`, running qemu-agent, or running-LXC
  interfaces). Address-less guests are still summarized in `details` but are not
  ingested as devices. (Coordinate with the DIRE `strong_enough?` gate so an
  address-less discovery is dropped rather than upserted.)
- **Report true status.** Read the guest runtime status (`status` /
  `qmpstatus` for QEMU, `status` for LXC) and set `IsAvailable`/`Status`
  accordingly; never infer `running` from config presence.
- **Deterministic identity.** Emit one canonical `DeviceID` per guest and per
  node (prefer the `proxmox:v2:<cluster>:<kind>:<vmid>` / `:node:<node>` scheme
  when cluster status is available; fall back consistently), and emit the guest
  MAC(s) as identifiers so DIRE merges the proxmox guest with the same host
  discovered by the agent and by AWX.

## Impact

- Affected specs: `proxmox-inventory` (new capability spec).
- Affected code:
  - `go/cmd/wasm-plugins/proxmox/` — `discovery.go` (IP-gated emission, status,
    identity), `inventory_fetch.go` (enrichment), `summaries.go` (status/IP).
  - `elixir/serviceradar_core/lib/serviceradar/edge/agent_config_generator.ex` —
    version-hash determinism.
  - `elixir/serviceradar_core/lib/serviceradar/inventory/…` — DIRE strong-enough
    gate for address-less proxmox discoveries.
- Depends on the committed churn fixes on `fix/credential-grant-assignment-churn`.
- Verified via the local build → hot-swap loop (plugin) and module hot-load
  (core), then a durable build+deploy.
