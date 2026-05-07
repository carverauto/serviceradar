# Change: Add Proxmox enrichment plugin and network-wide credential rules

## Why
ServiceRadar already discovers Proxmox-looking hosts and has an initial mapper path that can query configured PVE APIs, but operators still need a safer, scalable model for turning discovered PVE devices into enriched hypervisor inventory without configuring each plugin assignment by hand.

Credential handling is the blocker: Proxmox API tokens should be defined once, scoped to the agents and SRQL target sets that are allowed to use them, and never leaked to unrelated sites or inventory payloads.

## What Changes
- Add a deployment-scoped "Network-Wide Password Rules" capability for API keys, passwords, and protocol credentials.
- Support SRQL-targeted, agent-scoped credential rules so the control plane resolves "which credentials may be tried against which devices by which agent" before plugin assignment.
- Add a first-party Proxmox integration plugin using the ServiceRadar Go WASM SDK.
- Use direct Proxmox VE REST calls through the existing host-proxied HTTP capability rather than embedding a normal Go/Rust Proxmox API client in the sandbox.
- Reuse and converge with the existing `go/pkg/mapper/proxmox_poller.go` semantics for node/guest identity, hosted topology, and metadata.
- Persist Proxmox host, VM, and LXC enrichment against canonical devices, including resource-efficiency metrics requested by Forgejo #223.
- Add a Proxmox console access strategy so authorized operators can open web terminal sessions to PVE hosts through the reachable edge path, with QEMU/LXC guest console modes modeled but unavailable until a native connector is enabled.
- Store SSH keys and console credentials as encrypted credential-rule secrets, with per-agent/per-target scope and audited session launch.
- Expose settings UI for credential rules, Proxmox rule preview/test, agent distribution, and redacted credential lifecycle.

## Research Summary
- Forgejo #518 asks for Proxmox metrics, network mapper support, and device discovery.
- Forgejo #223 asks for VM/LXC resource efficiency, bottleneck reporting, and dashboard-ready visuals.
- The current repository already contains a Go Proxmox mapper path that calls `/nodes` and `/cluster/resources?type=vm`, builds hypervisor and guest devices, and emits hosted links.
- The Scion project under `~/src/scion` has reusable web PTY concepts: xterm.js terminal UX, WebSocket message envelopes for data/resize/close, hub-side authorization and stream proxying, and runtime-broker PTY attach handlers.
- Go options are more mature for normal binaries: `github.com/Telmate/proxmox-api-go` is broad but Terraform-provider-shaped, while `github.com/luthermonson/go-proxmox` has typed/context-aware client APIs.
- Rust options are improving: `proxmox-client` 0.9.2 has strong typed coverage, API token support, and security-oriented defaults, but it is experimental and depends on `reqwest`/Tokio.
- Because ServiceRadar WASM plugins must use host functions for HTTP and cannot open raw sockets, normal Proxmox API clients are not a good direct dependency for the plugin. The plugin should implement the narrow REST calls it needs over the ServiceRadar SDK HTTP wrapper.

## Impact
- Affected specs:
  - `network-credential-rules` (new)
  - `proxmox-integration-plugin` (new)
  - `proxmox-console-access` (new)
  - `device-inventory`
  - `network-discovery`
  - `agent-config`
  - `wasm-plugin-system`
- Affected code:
  - Ash resources/actions and migrations for credential rules and credential-secret references
  - Settings UI for network-wide credential rules and rule testing
  - Plugin target policy reconciliation and per-agent assignment compilation
  - First-party Go WASM plugin under `go/cmd/wasm-plugins/`
  - Proxmox enrichment ingestion in core-elx/web-ng
  - Web-ng console LiveView/React integration and websocket routes
  - Edge agent/gateway console session broker for SSH host sessions, with Proxmox termproxy/vncwebsocket represented as future unavailable connector modes
  - SRQL/device filters for Proxmox candidates and enriched assets
  - Agent plugin config delivery and redaction/caching behavior

## Non-Goals
- Do not add mutating Proxmox management actions such as start/stop/migrate/delete in the first implementation.
- Do not record terminal session contents by default.
- Do not give WASM plugins SRQL credentials or direct control-plane API credentials.
- Do not store raw Proxmox secrets in device inventory, plugin result details, logs, or URL query strings.
- Do not introduce multitenancy or per-customer routing concepts.
