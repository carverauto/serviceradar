## Context
The Proxmox console work is really a special case of a larger capability: agent-routed remote access. The operator is in the browser, the target is often reachable only from an edge agent, and the platform must route a short-lived interactive session through the existing outbound agent control path. If this is designed cleanly, ServiceRadar can cover use cases currently handled by remote access products while staying integrated with inventory, RBAC, audit, discovery, and alert context.

The dangerous part is credential custody. A long-lived SSH private key stored centrally can become a network-wide compromise primitive. The architecture must support central secrets where appropriate, but it must not require storing broad SSH keys in Postgres/AshCloak for generic device access.

## Goals
- Provide one remote-access substrate for SSH terminals, hypervisor consoles, and future graphical protocols such as RDP.
- Route all target connections through a selected enrolled agent using the agent-initiated control stream.
- Avoid direct platform-to-target connectivity requirements.
- Make credential custody explicit per credential rule and per protocol.
- Support customers that prohibit SaaS/control-plane storage of private keys.
- Enforce RBAC, per-agent/per-device scope, TTLs, audit, and optional approval before session start.
- Keep xterm/webpty reusable and protocol-neutral.

## Non-Goals
- Do not implement a full privileged access management product in the first iteration.
- Do not require session recording for all customers; make it policy-controlled.
- Do not require browser-held credentials for every SSH session; support multiple custody modes.
- Do not build RDP immediately; reserve the protocol boundary so it can be added without redesigning the tunnel.
- Do not build CEA-852/CN-IP support immediately; capture it as a future OT protocol adapter because we do not currently have real LonTalk/CN-IP infrastructure for validation.

## Architecture
Remote access sessions use this route:

```text
browser renderer
  -> web-ng remote access channel
  -> agent-gateway session router
  -> existing agent-initiated control stream
  -> agent protocol adapter
  -> target device or provider console endpoint
```

The session record is created in the platform before any target connection is opened. It includes actor, device or target ref, protocol, selected agent, partition, credential rule or session credential mode, RBAC decision, TTL, and requested capabilities.

The target connection must be opened by the selected agent, not the platform. That preserves support for overlapping IP spaces and segmented customer networks.

## Generic Resource and Frame Model
Use `remote_access` as the generic capability name in new code. Keep Proxmox-specific modules and routes as wrappers until the UI and API callers are migrated.

Resource and module names:
- Ash resource: `ServiceRadar.Edge.RemoteAccessSession`
- lifecycle/context module: `ServiceRadar.Edge.RemoteAccessSessions`
- browser/channel broker: `ServiceRadar.Edge.RemoteAccessBroker`
- pubsub boundary: `ServiceRadar.Edge.RemoteAccessPubSub`
- agent gateway router: `ServiceRadarAgentGateway.RemoteAccessStreamSession` or a genericized successor to `ControlStreamSession`
- agent package boundary: `go/pkg/agent/remoteaccess`

Session state machine:
- `requested`: platform created the session and issued any one-time browser attach ticket.
- `attached`: browser has consumed the ticket and is attached, but no target connection is open yet.
- `opening`: the selected agent has received the open frame and is dialing the target or provider adapter.
- `active`: the target adapter reported ready and byte/control frames may flow.
- `closing`: browser, platform policy, timeout, or agent requested close.
- `closed`: target connection ended cleanly or was explicitly closed.
- `failed`: target connection, policy, routing, credential, or adapter setup failed.
- `expired`: browser attach ticket or session TTL expired before clean completion.

Frame names:
- `open`: platform-to-agent request containing non-secret target metadata, protocol, terminal size, policy TTLs, and a one-time credential grant or session-present credential envelope when applicable.
- `ready`: agent-to-platform notification that the adapter is attached and the renderer can accept input.
- `data`: terminal or protocol payload bytes.
- `resize`: terminal size change for PTY-capable protocols.
- `heartbeat`: liveness and byte counter signal for long-running sessions.
- `close`: requested or completed close with a normalized reason.
- `error`: terminal error with a sanitized reason.
- `outcome`: final normalized status summary used by audit, optional recording manifests, and UI close banners.

Terminal outcomes:
- `completed`: clean close requested by the operator or target.
- `idle_timeout`: no activity before the idle deadline.
- `absolute_timeout`: maximum session TTL reached.
- `agent_disconnected`: owning control stream disconnected before close completed.
- `target_unreachable`: adapter could not connect to the target host/provider endpoint.
- `credential_rejected`: target or provider rejected the supplied credential.
- `credential_policy_denied`: custody, scope, approval, or grant policy blocked credential use.
- `rbac_denied`: actor was not authorized to create, attach, resume, or operate the session.
- `protocol_error`: adapter or frame protocol failed after the session opened.
- `internal_error`: platform or agent failed outside the protocol adapter.

Compatibility:
- Existing `ConsoleFrame` protobuf messages should continue to flow for Proxmox console callers while generic `RemoteAccessFrame` messages are introduced.
- The generic frame payload should carry `session_id`, `protocol`, `frame_type`, `data`, `cols`, `rows`, `reason`, `timestamp`, and optional `metadata`. Proxmox compatibility wrappers can map `ConsoleFrame` to `RemoteAccessFrame` with protocol `proxmox-console`.
- Persisted command records are still appropriate for on-demand commands such as mapper/MTR. Interactive remote-access byte streams should keep using the side-channel pattern used by `send_console_frame/3` to avoid persisting sensitive payload bytes in command records.

## Reusable Implementation Inventory
The current Proxmox console path already proves the key routing shape, but its names and frame type are provider-specific.

- `proto/monitoring.proto` defines `ConsoleFrame` on `ControlStreamRequest` and `ControlStreamResponse` with `open`, `ready`, `data`, `resize`, `close`, and `error` frames. This is the compatibility surface to preserve while introducing generic remote-access frame names.
- `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/control_stream_session.ex` registers an active agent control stream under `{:agent_control, agent_id, node()}`, sends gateway-to-agent console frames, and broadcasts returned frames by session ID.
- `elixir/serviceradar_core/lib/serviceradar/edge/agent_command_bus.ex` resolves live agent control-stream sessions through `ServiceRadar.ProcessRegistry.lookup_agent_control/1`, supports required gateway-node affinity, and already has a `send_console_frame/3` side channel separate from persisted command records.
- `elixir/serviceradar_core/lib/serviceradar/edge/proxmox_console_session.ex`, `proxmox_console_sessions.ex`, and migration `20260507021000_create_proxmox_console_sessions.exs` provide the existing Ash lifecycle resource, one-time browser ticket hash, agent/device scope checks, audit writes, idle/absolute timeout fields, and state machine.
- `elixir/serviceradar_core/lib/serviceradar/edge/proxmox_console_broker.ex` is the browser-channel broker boundary. It turns session metadata into an `open` frame payload, sends input/resize/close frames through `AgentCommandBus`, and relays returned data/close/error frames to the owner process.
- `go/pkg/agent/control_stream.go` owns the agent-side bidirectional stream loop. It dispatches incoming `ConsoleFrame` messages to the console manager while command handling remains separate.
- `go/pkg/agent/proxmox_console.go` contains the reusable PTY session manager pattern: per-session open/write/resize/close handling, read loop, and frame emission back through the control stream.
- `go/pkg/agent/proxmox_console_plugin.go` adapts Proxmox console open payloads into streaming Wasm plugin execution and exposes the bridge used by the plugin host functions.
- `go/pkg/agent/proxmox_console_ssh.go` is a concrete SSH PTY implementation using `golang.org/x/crypto/ssh`. Generic inventory SSH should extract this shape without inheriting the Proxmox credential assumptions.
- `go/pkg/agent/proxmox_console_credentials.go` implements an agent-local credential file with permission checks. This is directly reusable for the agent-local custody mode after renaming and generalizing the grant match fields.
- `proto/camera_media.proto`, `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/camera_media_session_tracker.ex`, and `camera_media_server.ex` provide a separate session-ownership example where an agent ID is bound to relay sessions before heartbeats/chunks/closes are accepted.
- `elixir/serviceradar_core/lib/serviceradar/credentials/network_credential_rule.ex`, `network_credential_secret.ex`, and `plugins/secret_refs.ex` provide central encrypted credential storage and plugin secret-reference resolution. Generic SSH must treat this as optional centrally brokered custody, not the default.

Teleport reference findings from `~/src/teleport`:
- `api/ssh` and `api/observability/tracing/ssh` have Apache-2.0 headers and are useful references for SSH client/tracing boundaries.
- `lib/bpf` and broad `lib/srv` paths have AGPL headers. Treat them as architecture reference only unless licensing is explicitly cleared.

## Credential Custody Modes
### Centrally Brokered Secret
The control plane stores an encrypted credential and grants a short-lived, scoped broker reference to the selected agent. This is acceptable for low-scope API tokens, break-glass credentials with strict approval, or customers that explicitly choose central storage.

Constraints:
- Secrets remain encrypted at rest.
- Grants are scoped to one agent, one target, one protocol, one session, and a short TTL.
- The browser never receives plaintext.
- Audit records include credential rule ID but not secret material.

### Agent-Local Credential
The control plane stores only a credential reference and policy metadata. The actual SSH key or password lives on the agent host or in an agent-local secret store.

Constraints:
- The agent validates file permissions or local secret-store policy before use.
- The platform can revoke policy by no longer granting sessions.
- This mode is preferred for customers that will not place private keys in SaaS/control-plane storage.

### User-Present Session Credential
The operator supplies a credential at session start. This can mean a pasted password/key that is held in memory only for the session, a browser-held non-extractable key, a local helper, or a workstation SSH agent bridge.

Constraints:
- Session credentials are never persisted.
- For generic inventory SSH, this SHOULD be the default first implementation: the browser accepts an SSH private key file or pasted key plus optional passphrase, sends it only when the operator starts a session, and the selected agent keeps it in memory only long enough to dial the target.
- Browser-side "remember this key" behavior, if added, MUST be client-only and clearly labeled. The platform MUST NOT sync or persist that private key in Postgres, object storage, gateway state, or core state.
- Browser-held non-extractable keys reduce raw-key exfiltration but do not prevent malicious loaded app code from requesting signatures during the active session.
- For high assurance, prefer local helper or hardware-backed signing where the private key never enters web app JavaScript memory.

### Short-Lived Certificate / Hardware-Backed Signing
Long term, generic SSH access should prefer short-lived SSH certificates issued after RBAC/approval, optionally backed by FIDO2/WebAuthn or a local SSH agent.

Constraints:
- Certificates must have narrow principals, target constraints, TTL, and audit correlation.
- The CA key must not run in web-ng.
- Revocation and expiry behavior must be documented before enabling broad rollout.

## Protocol Adapters
Protocol adapters run on the selected agent.

- `ssh`: PTY over SSH, rendered with xterm.
- `proxmox-console`: provider adapter that may use Proxmox API/tickets, termproxy, VNC, or SSH depending on the target type and granted credential.
- `vsphere-console`: future provider adapter for VM console APIs.
- `rdp`: future graphical adapter with a renderer different from xterm, but the same session, RBAC, audit, and route.
- `cea-852`: future OT/industrial adapter for Component Network over IP, commonly used to carry LonTalk/LON frames over UDP/TCP port 1628. This should remain deferred until real test gear or representative captures are available.

CEA-852 must be treated as a high-risk BMS/OT protocol, not as a generic shell. Claroty Team82's 2026 research describes CEA-852 as a common path for bringing LonTalk building-management systems onto IP networks and highlights weak/default authentication conditions, optional IP-852 HMAC, mandatory but MD5-based RNI/LPA authentication, and vendor-specific packet types that can affect device configuration or availability. Any first implementation should therefore be read-only discovery/diagnostics by default. Write/control operations, packet crafting, reboot/configuration actions, or credential/key material handling for CEA-852 require a separate approved proposal, lab validation, and explicit customer policy enablement.

The platform channel carries framed data/control messages: open, data, resize, heartbeat, close, error, and terminal outcome. Protocol details stay in the adapter.

## Proxmox Console vs Generic SSH
Proxmox console support must not be modeled as generic SSH key custody. PVE node shells, LXC consoles, and VM noVNC/SPICE-style consoles are requested through the Proxmox API and returned as temporary tickets, ports, or proxy endpoints. The agent-side provider adapter should use the same scoped Proxmox API credential that inventory enrichment uses, request a short-lived console ticket, and proxy the resulting console stream through the generic remote-access tunnel. No SSH private key is required for that path.

Generic inventory device SSH is different. For a first SSH implementation, the operator should provide a key or password per session from the browser, or the selected agent should use an agent-local bastion key that the customer manages on the agent host. The control plane may store public key fingerprints, credential rule metadata, and audit references, but it should not store broad private SSH keys by default.

The SSH adapter must:
- Accept private key bytes and passphrases only inside a session-open frame or a one-time session credential grant.
- Keep key material in process memory only for the active session.
- Avoid logging, tracing, audit payloads, crash dumps, and persisted state that contain private key bytes or passphrases.
- Record the key fingerprint, credential custody mode, actor, target, and selected agent for audit.
- Prefer Ed25519 and passphrase-protected keys where customer policy can enforce it.

## Security Controls
- RBAC checks must happen before session creation and before attach/resume.
- Session start may require approval for privileged targets or broad credentials.
- Every session must have a maximum TTL and idle timeout.
- Gateway routing must bind frames to the authenticated agent that owns the session.
- Agent adapters must enforce target host/port/protocol from the signed session grant and reject arbitrary retargeting.
- Credential broker grants must be one-time or short-lived and scoped to one session.
- Audit must record actor, target, protocol, selected agent, credential rule, approval, timestamps, terminal outcome, and policy decisions.
- Session byte recording must be optional and policy-controlled. If enabled, secrets should be redacted where feasible, but recording must be treated as sensitive data.

## Browser-Held SSH Keys
Keeping a user key local to the browser can avoid persistent server-side storage, but it is not a complete defense. If the web app or browser session is compromised, malicious JavaScript can still use a loaded non-extractable key to sign SSH challenges while the session is active. It may not be able to export the raw key, but it can still abuse it in real time.

Safer options are:
- Use a local helper or workstation SSH agent bridge so the web app cannot directly access key material.
- Use WebAuthn/FIDO2-backed signing with user presence for each session or sensitive operation.
- Issue short-lived SSH certificates after RBAC/approval and avoid long-lived private keys in the platform.

## Migration
1. Keep the existing Proxmox console path working.
2. Introduce generic remote-access session/resource names and compatibility wrappers for Proxmox-specific routes.
3. Move xterm/webpty React components behind a generic remote-console component.
4. Add agent-side SSH adapter using agent-local and user-present credential modes before encouraging centrally stored SSH keys.
5. Add provider console adapters as target metadata emitters from hypervisor enrichment.
6. Add RDP only after the protocol/renderer split is proven.
7. Add CEA-852/CN-IP support only after we have a test strategy using real equipment, partner-provided captures, or an accepted simulator.
8. Start CEA-852 with passive capture parsing or safe diagnostics only; defer active control paths until we can prove safety against real devices.
