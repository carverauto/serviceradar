## Context
This design records the broader program explored by the original change. For archival, only the generic remote-access substrate described in `proposal.md` and the reconciled delta specs is considered delivered. Protocol-specific file transfer, app/TCP, automatic host-key observation, packaged SSH CA access, production BPF, provider-native Proxmox, QEMU, and RDP behavior remains governed by separate active changes and their live-proof gates. SSH CA references below describe library/policy/smoke-test primitives, not a packaged or enabled release capability.

The Proxmox console work is really a special case of a larger capability: a Teleport-like access plane inside ServiceRadar. The operator is in the browser, the target is often reachable only from an edge agent, and the platform must route a short-lived interactive session through the existing outbound agent control path. If this is designed cleanly, ServiceRadar can cover use cases currently handled by remote access products while staying integrated with inventory, RBAC, audit, discovery, host telemetry, and alert context.

The target is functional parity class, not code cloning: SSH/shell access, protocol adapters, session recording, audit, approvals, short-lived credentials, app/database/Kubernetes/desktop-style access patterns over time, and enhanced command/disk/network tracing. Teleport has done substantial engineering in these areas, so ServiceRadar should import verified Apache-2.0 Teleport packages wherever that is legally and technically clean. Where Teleport implementation source is AGPL or has an AGPL transitive dependency path, ServiceRadar must implement equivalent behavior clean-room from requirements, public protocol/kernel interfaces, and tests.

The dangerous part is credential custody. A long-lived SSH private key stored centrally can become a network-wide compromise primitive. The architecture must support central secrets where appropriate, but it must not require storing broad SSH keys in Postgres/AshCloak for generic device access.

## Goals
- Build a ServiceRadar-native access plane with Teleport-like capability coverage over time.
- Reuse/import verified Apache-2.0 Teleport Go packages where the full transitive dependency path is license-clean and compatible with ServiceRadar's Bazel/Go module graph.
- Provide clean-room equivalents for non-importable Teleport functionality rather than mechanically porting AGPL implementation code.
- Provide one remote-access substrate for SSH terminals, hypervisor consoles, and future graphical protocols such as RDP.
- Route all target connections through a selected enrolled agent using the agent-initiated control stream.
- Avoid direct platform-to-target connectivity requirements.
- Make credential custody explicit per credential rule and per protocol.
- Support customers that prohibit SaaS/control-plane storage of private keys.
- Enforce RBAC, per-agent/per-device scope, TTLs, audit, and optional approval before session start.
- Support policy-controlled session recording and enhanced host-event telemetry, including command execution, file activity, and network connections on Linux agents where BPF is available.
- Keep xterm/webpty reusable and protocol-neutral.

## Non-Goals
- Do not implement the entire Teleport-equivalent capability set in the first iteration; design the architecture so the parity tracks can land incrementally.
- Do not copy, translate, or mechanically port AGPL Teleport implementation source.
- Do not require session recording for all customers; make it policy-controlled.
- Do not require BPF/enhanced recording on all platforms; provide policy and capability detection with graceful fallback.
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

## Teleport-Parity Capability Tracks
The first implementation should be narrow, but the architecture must preserve these capability tracks:

- SSH and shell access: browser terminal, PTY lifecycle, resize/input/output frames, SFTP/SCP-style file transfer later, host key policy, and per-session credentials.
- Session recording and replay: lifecycle audit first, optional byte recording later, replay metadata, recording retention, redaction boundaries, and sensitive-data classification.
- Enhanced host telemetry: command execution, file open/access, and network connection events correlated to a remote-access session. Linux BPF support should be clean-room unless a fully importable Teleport path is cleared.
- Access governance: RBAC, approvals, access requests, break-glass policy, per-target/per-agent scope, credential custody policy, and reauthorization on attach/resume.
- Identity and credentials: short-lived SSH certificates, user-present credentials, tightly scoped centrally brokered break-glass secrets, future hardware-backed signing, and audit correlation.
- Protocol adapters: SSH first, Proxmox/vSphere provider consoles, app/database/Kubernetes-style TCP/HTTP proxying later, and graphical desktop/RDP-style adapters later.
- Agent inventory and presence: enrolled agents advertise capabilities such as `remote_access`, `remote_access.ssh`, `remote_access.recording`, and `remote_access.bpf` so the control plane can route only to compatible agents.

Session recording starts as manifest and retention plumbing, not unconditional transcript persistence. When `recording_policy` enables recording, the platform creates a `remote_access_recordings` manifest with policy snapshot, storage backend/bucket/object key, retention expiry, lifecycle status, and aggregate input/output byte counters. Raw terminal input/output payload storage remains separately policy-gated and is not written by default.

Replay event persistence uses `remote_access_recording_events` under the platform schema. Events inherit the parent recording retention expiry and store sequence, stream, event type, byte count, payload hash, optional payload text, redaction state, and structured metadata. Terminal input/output payload text remains empty unless trusted policy explicitly enables terminal payload persistence; input payload text additionally requires an explicit input-recording flag. Enhanced-recording frames are stored as structured metadata rather than raw payload text. Replay reads require the base remote-access permission, while export requires `devices.remote_access.recordings.export`.

## File Transfer Parity Plan
File transfer is part of the remote-access plane, not a separate credential or routing bypass. The first implementation should prefer structured SFTP operations over raw SCP because SFTP gives ServiceRadar clear request boundaries for authorization, quota, recording, and audit. SCP compatibility can be added later as a wrapper or adapter only if it maps each operation into the same policy and audit model before any target file handle is opened.

The browser/API request should be intentionally narrow: target/session reference, direction, operation, optional path, and transfer intent. It must not accept client-supplied route, agent, target host, credential rule, recording policy, content-audit policy, quota, approval, or custody overrides. Those values come from trusted remote-access policy and the already selected session route.

Planned RBAC permissions:
- `devices.remote_access.files.list` for directory listing and metadata reads.
- `devices.remote_access.files.download` for file reads from the target.
- `devices.remote_access.files.upload` for writes to the target.
- `devices.remote_access.files.manage` for mkdir, rename, remove, chmod, chown, and similar mutating operations.
- `devices.remote_access.files.approve` for reviewer workflows when policy requires just-in-time approval for risky transfers.

Planned policy gates:
- Path allow/deny rules, optional path redaction policy, symlink behavior, and realpath validation before opening file handles.
- Direction and operation allowlists per actor, target, agent, protocol, and session.
- Quotas for bytes, files, single-file size, recursive depth, concurrent transfers, and transfer rate.
- Optional approval for upload, download, recursive copy, manage operations, sensitive paths, or content-audit exceptions.
- Optional content audit hooks for malware/DLP scanning, file hashing, and artifact retention.

The durable model should capture transfer lifecycle without storing file contents by default. A `remote_access_file_transfers` record, or an equivalent typed recording event stream, should include transfer ID, session ID, actor ID, device/target, selected agent, target path or path hash according to policy, direction, operation, byte count, file count, SHA-256 when enabled, decision, policy snapshot, quota counters, status, failure reason, timestamps, and retention expiry. Replay should show transfer lifecycle events such as `transfer_request`, `transfer_started`, `transfer_progress`, `transfer_completed`, and `transfer_failed` alongside terminal events, but the transcript must not include raw file contents unless an explicit content-audit policy enables a separate sensitive artifact path with retention and export controls.

Threats to account for before implementation:
- Data exfiltration by download, recursive copy, or quota evasion.
- Unauthorized overwrite, chmod/chown, rename, or delete operations.
- Path traversal, symlink escape, relative-path ambiguity, and time-of-check/time-of-use races.
- Sensitive filename disclosure in audit and replay views.
- Malware or policy-violating uploads into managed hosts.
- Partial transfer and resume semantics that bypass byte, file, or approval limits.

Implementation guidance:
- Reuse the existing session, approval, credential-custody, recording, and agent-routing model. File transfer does not get reusable agent-local secrets.
- Add agent capability advertisements such as `remote_access.file_transfer`, `remote_access.sftp`, and `remote_access.scp` only when the agent can enforce the required policy locally.
- Consider `github.com/pkg/sftp` as the first SFTP implementation dependency after direct license review and Bazel/Go module review. Current Teleport server-side SFTP/SCP code remains architecture reference only unless its exact source path and transitive dependency path are proven Apache-2.0 compatible or explicitly approved.
- Keep any future SCP support subordinate to the same file-transfer manager; do not create a second transfer runtime with separate policy, quota, or audit behavior.

## Current Hardening Track
The initial substrate is in place, so active work is now a ServiceRadar remote-access hardening track. This work borrows Teleport's architectural lessons, but it is not full Teleport parity. The ordering is deliberate:

1. Close credential-custody gaps before adding new protocol surface.
2. Bind every frame and grant to one session, one selected agent, one target, one protocol, and one actor.
3. Keep browser-facing APIs narrow; broader custody, route, recording, and policy choices must come from trusted inventory/policy, not client request bodies.
4. Add Teleport-equivalent features one at a time with tests and license notes.

Current hardening decisions:
- Generic SSH MUST NOT use reusable agent-local SSH private keys, passwords, passphrases, or local credential files.
- Persisted remote-access session metadata MUST NOT be used as SSH auth material or as a certificate envelope source. Session credentials and issued certificate envelopes are passed through in-memory broker grants only.
- The public browser SSH create path MAY allow `ssh_certificate` and `user_present` custody selection, but MUST reject browser-selected `centrally_brokered` custody. Central custody is selected by trusted remote-access policy.
- Centrally brokered custody MUST require an approval decision and a trusted credential rule before an attach ticket is issued. The eventual broker grant MUST be short-lived and scoped to one session, one selected agent, one target, and one protocol.
- Agent-returned frames MUST be accepted only when both the session ID and authenticated agent ID match the session owner.
- Gateway broadcast of remote-access frames MUST be stamped from the authenticated control-stream state and MUST NOT broadcast from unregistered streams.

Implemented foundation areas:
- SSH routing plus provider-console compatibility plumbing over the selected agent control stream; no provider-native transport is claimed ready.
- Credential custody boundaries for user-present, SSH-certificate, and scoped central grant modes.
- Session-bound route validation across browser, gateway, and agent frame paths.
- Host key lifecycle primitives and a first operator UI for trust, revoke, and rotation workflows.
- Access-request records and approval/session binding primitives.
- Policy-gated replay event storage/API/UI primitives.
- Enhanced-recording interfaces and non-BPF fallback boundaries; production eBPF attachment and truthful capability proof remain in the separate active change.

Explicit non-parity gaps remain:
- File transfer implementation: SFTP/SCP-style access with explicit RBAC, recording, quota, and content-audit policy.
- Protocol expansion: app, database, Kubernetes, desktop/RDP, vSphere console, cloud console/API, MCP, and OT adapters as separate scoped proposals.
- Enterprise identity governance beyond the current Authentik/OIDC smoke path: per-session MFA, SCIM/provisioning, identity locks, device trust, and richer role/trait mapping.
- Session collaboration: live session inventory, session sharing, moderation, forced termination, and reviewer join workflows.
- Production recording depth: searchable recordings, summaries, SIEM/export pipelines, storage backend hardening, and redaction policy maturity.
- Enhanced recording depth: production ServiceRadar-owned probes for command/file/network telemetry with broader kernel coverage and operational runbooks.

## BPF / Enhanced Recording Model
Enhanced recording is a separate host telemetry capability from the interactive byte stream. It should emit normalized ServiceRadar audit/telemetry events that can be correlated with `remote_access_session_id`, `actor_id`, `agent_id`, `target`, and `credential_custody_mode`.

Initial event families:
- `command`: exec path, argv where policy permits, cwd, uid/gid, pid/ppid, exit status when available, timestamp, and session correlation.
- `file`: path, operation, uid/gid, pid, result, timestamp, and session correlation.
- `network`: source/destination address and port, protocol, pid, result, timestamp, and session correlation.
- `loss`: per-family dropped-event counters and sampler/backpressure state.

Implementation constraints:
- BPF programs and loaders must be ServiceRadar-authored clean-room code unless a license-clean import path is identified.
- BPF attachment must be policy-controlled and capability-gated by kernel/platform compatibility.
- Agents must fail closed for required enhanced recording policies when BPF cannot start, and fail open only when policy explicitly allows non-BPF fallback.
- Events must avoid capturing plaintext credentials, terminal input bytes, or secret file contents.
- Linux-specific event capture should live behind interfaces so non-Linux agents can still run remote access without enhanced recording.

The first agent implementation adds the clean-room `EnhancedRecorder` boundary, policy parser, fail-closed/fallback gate, normalized event frame shape, and agent capability gates. Agents may advertise `remote_access`, `remote_access.ssh`, and `remote_access.recording` once the generic adapter is present, but `remote_access.bpf` is advertised only when a ServiceRadar-owned BPF collector can satisfy required BPF policies. The Linux implementation includes a procfs fallback collector for command, open-file descriptor, and socket observations when policy allows fallback; it refuses required `mode: "bpf"` policies unless fallback is explicitly allowed. The Linux BPF loader/probes remain behind that interface and must be ServiceRadar-authored before required BPF policies can succeed on production agents.

Production BPF gate:
- `remote_access.bpf` is an advertised capability only when `SERVICERADAR_AGENT_EBPF_ENABLED` is explicitly enabled and the shared `go/pkg/agent/ebpf` runtime reports available.
- The runtime compatibility report must include library, library version, platform, and kernel release details and must fail closed on missing bpffs, missing BTF unless policy allows it, missing cgroup v2 path unless policy allows it, unsupported hash/ringbuf/tracepoint/kprobe features, permission denial, or self-test load failure.
- The self-test must load a ServiceRadar-owned `bpf2go` collection through `github.com/cilium/ebpf`; procfs fallback collectors and non-BPF host-event collectors must not cause `remote_access.bpf` advertisement.
- Required BPF policies must start the enhanced recorder before the SSH/provider adapter dials the target. If recorder startup fails, the target opener is not invoked and the session fails with a sanitized policy error.
- Agentless targets cannot satisfy required BPF policies because there is no managed host boundary where ServiceRadar can attach command/file/network probes. Those sessions fail before target access unless policy explicitly allows non-BPF fallback.
- Loss counters for kernel drops, parser failures, and user-space backpressure are part of the event stream. Required policies can later be tightened to fail closed when loss exceeds a configured threshold.

Initial compatibility matrix:

| Gate | Required for `remote_access.bpf` | Failure behavior |
| --- | --- | --- |
| Explicit enablement | `SERVICERADAR_AGENT_EBPF_ENABLED=true` | Omit capability with `config_disabled` |
| bpffs | `/sys/fs/bpf` or configured path exists | Omit capability with `missing_bpffs` |
| BTF | `/sys/kernel/btf/vmlinux` or configured path exists unless explicitly allowed missing | Omit capability with `missing_btf` |
| cgroup v2 path | `/sys/fs/cgroup` or configured path exists unless explicitly allowed missing | Omit capability with `missing_cgroup` |
| Kernel features | cilium/ebpf detects hash maps, ring buffers, tracepoints, and kprobes | Omit capability with `feature_unsupported`, `permission_denied`, or `self_test_failed` |
| Self-test | ServiceRadar self-test collection loads and closes successfully | Omit capability with `self_test_failed` |
| Source ownership | Probes and loader are ServiceRadar-authored under the shared runtime | Do not ship required-BPF support for that probe family |

## Generic Resource and Frame Model
Use `remote_access` as the generic capability name in new code. Keep Proxmox-specific modules and routes as wrappers until the UI and API callers are migrated.

Resource and module names:
- Ash resource: `ServiceRadar.Edge.RemoteAccessSession`
- lifecycle/context module: `ServiceRadar.Edge.RemoteAccessSessions`
- browser/channel broker: `ServiceRadar.Edge.RemoteAccessBroker`
- pubsub boundary: `ServiceRadar.Edge.RemoteAccessPubSub`
- agent gateway router: `ServiceRadarAgentGateway.RemoteAccessStreamSession` or a genericized successor to `ControlStreamSession`
- agent package boundary: `go/pkg/agent/remoteaccess`
- future agent adapter registry: `go/pkg/agent/remoteaccess.AdapterRegistry`, dispatching protocol names to session-scoped `Opener` implementations without introducing reusable agent-local target credentials.

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
- During the compatibility phase, an existing `ConsoleFrame` `open` payload may declare `"protocol": "ssh"` to route through the generic SSH adapter. Payloads without a protocol continue to default to `proxmox-console`.
- Persisted command records are still appropriate for on-demand commands such as mapper/MTR. Interactive remote-access byte streams should keep using the side-channel pattern used by `send_console_frame/3` to avoid persisting sensitive payload bytes in command records.

Future protocol adapters for `app`, `database`, `kubernetes`, `desktop`, `rdp`, `vsphere_console`, and `ot` are registry entries, not separate privileged agent services. Each adapter must validate its open-frame payload, honor session TTL/close semantics, and inherit the same recording, approval, and credential-custody gates before any target connection is opened.

## Protocol Adapter Proposal Backlog
Future Teleport-parity adapters must land as separate OpenSpec proposals before implementation. Each proposal must define the protocol name, agent capability flag, target resource type, RBAC permissions, approval triggers, credential custody mode, recording/export policy, quota/backpressure behavior, validation tests, demo proof path, and Teleport/source reuse license notes. The browser must never be able to turn an adapter into an arbitrary TCP bounce by supplying its own route, upstream host, credential rule, policy, or target identity.

Common adapter contract:
- Route through the selected enrolled agent and bind every stream to one session, one target, one actor, one protocol, and one policy snapshot.
- Use typed target resources from inventory or provider discovery; reject arbitrary browser-supplied upstream addresses unless a dedicated lab/break-glass policy explicitly allows them.
- Keep reusable credentials out of browser request bodies and agent-local config. Prefer short-lived certificates/tokens or provider-issued session tickets; centrally brokered secrets require trusted policy, approval when configured, and one-session grants bound to the selected agent/gateway route.
- Define recording content boundaries before shipping. Metadata recording is the default; protocol payloads, query text, screen frames, request bodies, clipboard data, and downloaded artifacts require explicit policy and retention controls.
- Add protocol-specific quotas and backpressure before opening production access.

Adapter proposal backlog:
- `app`: HTTP/HTTPS application access to registered internal apps through an agent. Threats include SSRF/open-proxy behavior, Host/SNI confusion, cookie/header/token leakage, request smuggling, upload/download exfiltration, origin confusion, and insecure upstream TLS. The first proposal should require registered upstreams, Host/SNI allowlists, header policy, browser origin isolation, TLS verification policy, method/path/status/byte audit by default, and no arbitrary CONNECT tunnel.
- `database`: PostgreSQL/MySQL-style database access through an agent. Threats include broad shared database credentials, data exfiltration, destructive queries, query logs containing secrets, protocol downgrade, and long-lived connection reuse after policy changes. The first proposal should prefer short-lived database credentials or mTLS where available, bind central secrets to one session when unavoidable, support read-only policy, record connection/query metadata with redaction, and cap result/byte volume.
- `kubernetes`: Kubernetes API access, exec, logs, and port-forward over the selected agent. Threats include cluster-admin impersonation, bearer-token theft, namespace escape, unrestricted exec/port-forward lateral movement, and stale kubeconfig reuse. The first proposal should preserve the ServiceRadar actor through impersonation or short-lived client certificates, scope namespaces/resources/verbs, deny exec and port-forward by default, and record request metadata without persisting tokens.
- `desktop`/`rdp`: graphical desktop access with a renderer separate from the terminal path. Threats include clipboard, drive, printer, audio, and smart-card redirection exfiltration, sensitive screen recording, credential prompts inside the session, high-bandwidth denial of service, and weak target TLS/NLA handling. The first proposal should disable redirection features by default, add per-feature RBAC, enforce frame/bitrate quotas, define screenshot/recording retention and consent policy, and keep target credentials out of recordings.
- `vsphere_console`: vSphere or ESXi console access through provider-issued tickets. Threats include provider API token overreach, VM identity confusion, ticket replay, console access bypassing guest OS audit, and accidental power/control-plane operations. The first proposal should mirror the Proxmox provider-ticket model, require one-session provider grants, bind tickets to VM identity and selected agent, exclude power/configuration operations initially, and audit ticket issuance without storing ticket material.
- `ot`: OT protocol adapters such as CEA-852/CN-IP remain separate high-risk proposals. The first implementation stays read-only diagnostics unless representative lab infrastructure, protocol-specific safety tests, and explicit customer policy exist.

## Plugin Trust Boundary
Wasm remains the preferred extension surface for provider-specific integrations such as Proxmox, vSphere, and future inventory or console providers. Plugins may translate provider inventory into ServiceRadar target metadata, call provider APIs, request temporary provider console tickets through scoped broker grants, and stream provider-specific protocols through host functions.

Security-critical remote-access controls stay in trusted ServiceRadar code, not in Wasm plugin policy:
- Identity, Authentik/OIDC claim handling, RBAC, access requests, approval checks, session TTLs, and attach-ticket issuance stay in web-ng/core/agent-gateway.
- SSH certificate signing and CA private-key custody stay behind the ServiceRadar signer boundary, never inside a provider plugin.
- Durable credential decryption, credential-broker grant resolution, host-key trust stores, TOFU writes, host-key rotation/conflict handling, audit writes, and recording/enhanced-recording enforcement stay in the control plane and selected agent.
- eBPF loaders/probes use the ServiceRadar `go/pkg/agent/ebpf` boundary backed by `cilium/ebpf`; plugins may consume normalized telemetry outcomes but must not introduce a second eBPF runtime or policy enforcement path.
- Plugins receive only session-scoped grants, short-lived provider tickets, or non-secret target metadata. They must not receive reusable agent-local bastion credentials or long-lived target private keys.

Teleport-like protocol parity can use Wasm for provider adapters and protocol-specific glue when the plugin sandbox is a good fit, but primitives that establish trust, custody, authorization, audit, or kernel visibility belong in first-party trusted packages with focused tests.

The golden path is not a monolithic "Teleport plugin." It is a native ServiceRadar access plane with small, signed, permissioned provider plugins at the edge of the system. Before expanding the plugin substrate beyond Proxmox, the demo environment must prove that the Proxmox console plugin can reliably open, stream, resize, close, and audit a real session through the same signed-plugin and broker-grant path operators will use in production.

Wasm improves security posture when it reduces provider-specific code running with full agent privileges, gives the agent an explicit permission manifest, and lets us publish or roll plugin fixes independently. It does not improve security when a plugin is given broad reusable credentials, becomes the source of authorization truth, or requires host functions so powerful that the sandbox is only nominal. Long-running SSH/proxy implementations also carry practical Wasm costs: TinyGo/runtime compatibility, garbage-collection pressure, copied frame buffers, harder debugging, and host-function API stability.

## Reusable Implementation Inventory
The current Proxmox console path supplied compatibility plumbing for the key routing shape, but does not prove a working provider-native adapter and still uses provider-specific names and frame types.

- `proto/monitoring.proto` defines `ConsoleFrame` on `ControlStreamRequest` and `ControlStreamResponse` with `open`, `ready`, `data`, `resize`, `close`, and `error` frames. This is the compatibility surface to preserve while introducing generic remote-access frame names.
- `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/control_stream_session.ex` registers an active agent control stream under `{:agent_control, agent_id, node()}`, sends gateway-to-agent console frames, and broadcasts returned frames by session ID.
- `elixir/serviceradar_core/lib/serviceradar/edge/agent_command_bus.ex` resolves live agent control-stream sessions through `ServiceRadar.ProcessRegistry.lookup_agent_control/1`, supports required gateway-node affinity, and already has a `send_console_frame/3` side channel separate from persisted command records.
- `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_session.ex`, `remote_access_sessions.ex`, and migration `20260509090000_create_remote_access_sessions.exs` provide the generic Ash lifecycle resource/API for agent-routed sessions. The record captures actor, target, protocol/adapter, selected agent, credential custody mode, TTLs, policies, status, outcome, and sanitized metadata while storing attach tickets only as hashes and never storing session credential payloads.
- `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/remote_access_session_controller.ex` exposes authenticated generic session create/show/close routes under `/api/remote-access/sessions` using the existing `:api_auth` pipeline. The current public create endpoint is the browser SSH API protected by `devices.remote_access.ssh.open`: it defaults requests to `protocol: "ssh"`, `adapter: "ssh"`, and `target_kind: "inventory_device"`, rejects non-SSH protocols, non-SSH adapters, or provider-console target kinds until those surfaces get dedicated endpoints or permission checks, and rejects browser-supplied `agent_id`/`gateway_id` route selectors so route ownership stays in inventory/policy. Responses include the one-time browser attach ticket only on create, never include attach-ticket hashes, and keep reusable credential material out of returned JSON. The public create API strips credential-shaped metadata plus client-controlled SSH certificate policy metadata such as allowed principals, principal mappings, certificate envelopes, SSH auth objects, and credential mode overrides; those values must come from trusted target policy or session credential issuance paths. Browser-supplied `credential_rule_id`, `recording_policy`, and `enhanced_recording_policy` are rejected so credential, audit, and recording behavior is selected by trusted remote-access policy. Browser-supplied `target_host` and `target_port` overrides are rejected by default and require explicit deployment switches.
- `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/remote_access_stream_controller.ex` and `channels/remote_access_stream_handler.ex` expose the authenticated generic browser stream at `/v1/remote-access/sessions/:id/stream`. The handler consumes the one-time attach ticket, starts `RemoteAccessBroker`, forwards bounded base64 terminal bytes and bounded resize frames, handles ready/close/timeout events, and tests prove attach tickets and credential metadata are not echoed to the browser.
- `elixir/web-ng/assets/component/src/RemoteAccessTerminal.jsx`, `assets/js/hooks/RemoteAccessTerminal.js`, and `ServiceRadarWebNGWeb.ReactComponents.remote_access_terminal/1` provide the protocol-neutral xterm renderer for browser-stream sessions. The existing Proxmox console helper delegates to this generic component with console-specific labels, so future SSH and provider-console UIs do not need to fork terminal lifecycle, resize, base64 data, or close/error handling.
- `elixir/web-ng/assets/component/src/RemoteAccessSSHConsole.jsx`, `assets/js/hooks/RemoteAccessSSHConsole.js`, `ServiceRadarWebNGWeb.RemoteAccessLive.SSH`, and `/devices/:uid/remote-access/ssh` provide the first browser SSH console. The React form supports SSO-certificate and user-present credential modes, accepts pasted or uploaded per-session private keys, accepts a public key for certificate signing, supports optional passphrases, displays a browser-local SHA-256 digest of the normalized key text, and can remember user-present keys only in browser local storage when deployment policy explicitly enables that affordance. Keys are not posted to session creation and are sent only in the authenticated WebSocket attach frame as a session credential envelope. SSH host-key `skip_verify`, target-host override, and target-port override controls are hidden and rejected by default; deployments must explicitly enable them with runtime policy switches for lab/break-glass use.
- `elixir/serviceradar_core/lib/serviceradar/edge/proxmox_console_session.ex`, `proxmox_console_sessions.ex`, and migration `20260507021000_create_proxmox_console_sessions.exs` provide the existing Ash lifecycle resource, one-time browser ticket hash, agent/device scope checks, audit writes, idle/absolute timeout fields, and state machine.
- `elixir/web-ng/lib/serviceradar_web_ng_web/channels/proxmox_console_stream_handler.ex` remains a live compatibility stream while Proxmox console moves onto the generic remote-access path. It must apply the same browser-side terminal data and dimension bounds before forwarding frames to the broker.
- `elixir/serviceradar_core/lib/serviceradar/edge/proxmox_console_broker.ex` is the browser-channel broker boundary. It turns session metadata into an `open` frame payload, sends input/resize/close frames through `AgentCommandBus`, and relays returned data/close/error frames to the owner process.
- `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_ssh_certificate_policy.ex` is the pure policy boundary for generic SSH certificate requests. It checks the dedicated SSH remote-access permission, intersects requested principals with a target-approved principal policy, bounds request identifiers, public keys, target fields, principal count/length, and TTL, and emits the session key ID/audit shape before any CA signs.
- `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_ssh_principal_mapper.ex` maps Authentik/OIDC/SAML claims to SSH principals using explicit target/session mappings for groups, email, email domains, or specific claims. It bounds mapping count, claim value expansion, claim value size, and output principal count. It only produces candidate Unix logins; it does not bypass RBAC or certificate policy checks.
- `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_ssh_certificates.ex` orchestrates policy plus a configured or per-call signer module. The signer is intentionally replaceable so the CA private key can live in a dedicated signer service, OpenBao/KMS path, or native port instead of web-ng or agent-gateway.
- `ServiceRadar.Edge.RemoteAccessSessions` can copy SSH certificate principal policy from trusted deployment config `:remote_access_ssh_certificate_policy`, populated by `SERVICERADAR_REMOTE_ACCESS_SSH_CERTIFICATE_POLICY_JSON` or `SERVICERADAR_REMOTE_ACCESS_SSH_CERTIFICATE_POLICY_FILE`. Supported policy keys are `allowed_principals`, `principal_mappings`, `ttl_seconds`, and per-target overrides under `targets`; this is the Authentik proof path until a first-class target access-policy resource is added. SSH certificate sessions fail before attach-ticket issuance unless trusted policy supplies either allowed principals or principal mappings for the target.
- `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_ssh_identity_issuer.ex` is the Authentik/OIDC/SAML-facing issuance boundary. It accepts only server-side authoritative IdP claims from the authenticated login context, overlays stable ServiceRadar actor identity, strips any caller-supplied claims from request attrs, and then invokes certificate policy/signing. It writes sanitized success/denial audit events for certificate issuance without public keys, private keys, passphrases, or raw browser-supplied claims.
- `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_ssh_session_credentials.ex` builds one-session user-present credential grants for key, password, and certificate-backed SSH opens. Private keys, passwords, and passphrases appear only in returned broker options and must not be copied into certificate envelopes, audit details, persisted session metadata, or logs. The SSO-backed certificate grant path uses the identity issuer boundary so browser-supplied claims cannot select SSH principals.
- `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_ssh_ca_command_signer.ex` implements that signer behaviour by invoking an external JSON stdin/stdout command. It is enabled explicitly with `SERVICERADAR_REMOTE_ACCESS_SSH_CA_SIGNER_ENABLED=true` and can be pointed at a signer command with `SERVICERADAR_REMOTE_ACCESS_SSH_CA_SIGNER_COMMAND`, `SERVICERADAR_REMOTE_ACCESS_SSH_CA_SIGNER_ARGS_JSON`, and `SERVICERADAR_REMOTE_ACCESS_SSH_CA_KEY_ID`. This is a local bridge to a signer process and must not log request payloads, place CA private-key bytes in application state, or accept oversized signer response certificate/fingerprint fields.
- `go/cmd/tools/sshca-signer` wraps the ServiceRadar-owned `go/pkg/remoteaccess/sshca` primitive as a JSON stdin/stdout signer process for local Authentik/OpenSSH proof tests and future signer-service packaging. It should be treated as a signer boundary, not as permission to move CA private-key custody into web-ng or agent-gateway.
- `elixir/web-ng/lib/serviceradar_web_ng_web/user_auth.ex`, `accounts/scope.ex`, and `controllers/oidc_controller.ex` preserve sanitized, server-verified OIDC/SAML identity claims in the browser session scope after login. Remote-access certificate issuance uses those authoritative scope claims instead of trusting browser-supplied claims in websocket attach frames.
- `elixir/web-ng/lib/serviceradar_web_ng_web/channels/remote_access_stream_handler.ex` supports `ssh_certificate` attach by accepting a bounded session-scoped browser/private key, deriving principal policy only from session metadata, and invoking the identity certificate grant boundary. Browser-supplied claims, principal mappings, routing fields, TTLs, and credential-policy fields in the credential envelope are rejected so the client can request principals but cannot grant them or retarget the credential.
- `go/pkg/remoteaccess/sshca/openssh_integration_test.go` is an opt-in integration proof for the target-host trust model: `go test -tags integration ./go/pkg/remoteaccess/sshca -run TestOpenSSHTrustedUserCAKeysAcceptsServiceRadarCertificate -count=1 -v` starts a temporary high-port OpenSSH server with `TrustedUserCAKeys`, signs a user key with the ServiceRadar CA package, and proves certificate login without a shared bastion credential.
- `go/pkg/agent/remoteaccess/ssh_integration_test.go` is an opt-in adapter proof: `go test -tags integration ./go/pkg/agent/remoteaccess -run TestOpenSSHFromFrameAuthenticatesWithServiceRadarCertificate -count=1 -v` starts temporary OpenSSH, signs a user key with the ServiceRadar CA package, then opens the session through the agent `OpenSSHFromFrame` adapter with `credential_mode: "ssh_certificate"`.
- `go/pkg/agent/proxmox_console_ssh_integration_test.go` is the agent control-frame compatibility proof: `go test -tags integration ./go/pkg/agent -run TestProxmoxConsoleManagerAuthenticatesToTrustedUserCATarget -count=1 -v` opens a real SSH target through the same `ConsoleFrame` open/data/close route used by the current gateway-to-agent compatibility path, with a ServiceRadar-signed OpenSSH user certificate and no stored target credential.
- `scripts/remote-access-demo-ssh-smoke.sh` runs that agent control-frame proof from inside the live demo agent pod against a temporary OpenSSH target in a separate Kubernetes namespace. The target trusts only the generated ServiceRadar CA public key through `TrustedUserCAKeys`; the agent receives the user private key and certificate only as per-session frame payload material and removes the copied smoke-test files after the run.
- `elixir/serviceradar_core/test/serviceradar/edge/remote_access_sessions_test.exs` proves generic attach tickets are one-time use, session metadata redacts private keys/passwords/provider tickets, generic SSH rejects the agent-local reusable credential custody anti-pattern and protocol-mismatched custody modes, SSH certificate sessions require trusted principal policy, lifecycle transitions audit terminal outcomes, and provider-console sessions default to provider-ticket custody.
- `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_broker.ex` writes sanitized generic session audit events for open, input, resize, close-request, close, and failure transitions. Input audit records byte counts only; open audit removes the SSH auth object before writing details. When backed by a `RemoteAccessSession` resource, the broker also advances durable lifecycle state on open-frame send, ready, close-request, close, and failure without requiring credential persistence.
- `ServiceRadar.Edge.RemoteAccessRequest` and `ServiceRadar.Edge.RemoteAccessRequests` provide the in-platform access-request lifecycle for Teleport-style approval parity. Requests capture requester, target, agent route, protocol, custody mode, credential rule, expiry, reviewer policy, and sanitized metadata; approve/deny/expire/consume transitions are audited and store no credentials or attach tickets. `ServiceRadar.Edge.RemoteAccessSessions` uses this manager as its default approval checker, verifies the approved request matches the exact session scope, and consumes it by binding it to one session before returning an attach ticket. External approval checkers may still be injected for integration tests or future third-party approval systems.
- `go/pkg/agent/control_stream.go` owns the agent-side bidirectional stream loop. It dispatches incoming `ConsoleFrame` messages to the console manager while command handling remains separate.
- `go/pkg/agent/proxmox_console.go` contains the reusable PTY session manager pattern: per-session open/write/resize/close handling, read loop, and frame emission back through the control stream.
- `go/pkg/agent/remoteaccess/manager.go` is the agent-side generic frame boundary. It validates open payload size, open/resize terminal dimensions, and terminal input-frame size before touching the PTY, chunks target output into bounded frames, and does not rely only on browser/web-ng validation.
- While `ConsoleFrame` remains the compatibility transport, the Proxmox console manager attaches the local agent ID to generic remote-access frame metadata so generic SSH open payloads cannot claim a different agent before dialing.
- `go/pkg/agent/proxmox_console_plugin.go` adapts Proxmox console open payloads into streaming Wasm plugin execution and exposes the bridge used by the plugin host functions.
- `go/pkg/agent/proxmox_console_ssh.go` is a concrete SSH PTY implementation using `golang.org/x/crypto/ssh`. It remains a compatibility path and must validate target ports plus target/username/key/password/passphrase field sizes before dialing. Generic inventory SSH should extract this shape without inheriting the Proxmox credential assumptions.
- `go/pkg/agent/remoteaccess/ssh_open.go` validates generic SSH open payload scope before dialing. Payload `session_id` must match the control frame, payload `protocol` must remain SSH, and payload `agent_id` must match frame metadata when supplied by the transport. Only `user_present` and `ssh_certificate` credential modes are accepted. `go/pkg/agent/remoteaccess/ssh.go` range-checks target ports and bounds target, terminal type, username, credential, certificate, password, and passphrase fields before dialing. The SSH signer path rejects host certificates and user certificates whose public key does not match the supplied per-session private key.
- Legacy Proxmox-specific local credential files are removed from the agent path. Generic enterprise SSH should use short-lived certificates; legacy Proxmox host SSH can use centrally brokered session grants only when explicitly accepted by deployment policy.
- `go/pkg/remoteaccess/sshca` is the ServiceRadar-owned OpenSSH user certificate signing primitive. The eventual Authentik-backed issuer should wrap this package with identity, RBAC, approval, target, and audit policy before returning `ssh.certificate` to the session path.
- `proto/camera_media.proto`, `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/camera_media_session_tracker.ex`, and `camera_media_server.ex` provide a separate session-ownership example where an agent ID is bound to relay sessions before heartbeats/chunks/closes are accepted.
- `elixir/serviceradar_core/lib/serviceradar/credentials/network_credential_rule.ex`, `network_credential_secret.ex`, and `plugins/secret_refs.ex` provide central encrypted credential storage and plugin secret-reference resolution. Generic SSH must treat this as optional centrally brokered custody, not the default.

Teleport reference findings from `~/src/teleport`:
- `api/ssh` and `api/observability/tracing/ssh` source files have Apache-2.0 headers in the local checkout, but their current Go dependency graph reaches AGPL-header directories through the Teleport API root (`api/gen/proto/go/teleport/hardwarekeyagent/v1` and `api/utils/iterutils`). Do not import these packages until dependency review finds a license-clean version/path or legal explicitly approves the dependency graph.
- The `github.com/gravitational/teleport/api` module is not safe to treat as uniformly Apache-2.0 without subpackage and transitive dependency review; this checkout includes AGPL-header files under `api/types/...`, generated API packages, and utility packages.
- `lib/bpf` and broad `lib/srv` paths have AGPL headers. Treat them as architecture reference only unless licensing is explicitly cleared.
- Import verified Apache-2.0 Teleport subpackages wherever they fit the agent implementation. Do not copy, translate, or mechanically port AGPL implementation code. For non-Apache areas, write a clean-room ServiceRadar implementation from behavior requirements, protocol documentation, and tests that do not derive from AGPL source text.

Teleport capability inventory to keep mapped as design proceeds:
- `api/ssh`, `api/observability/tracing/ssh`: SSH client/tracing API shape, currently blocked for direct import by transitive license review.
- `lib/srv`, `lib/srv/ssh`, `lib/srv/forward`: server-side SSH, SFTP, and forwarding behavior; treat as clean-room reference due AGPL headers.
- `lib/events`, `api/types/events`: audit/session event vocabulary; review subpackages individually before import.
- `lib/bpf` and top-level `bpf/enhancedrecording`: enhanced recording concepts for command, disk/file, and network events; clean-room unless cleared.
- `lib/proxy`, `lib/web`, `lib/client`, `lib/kube`, `lib/srv/db`, `lib/srv/desktop`, `lib/srv/app`: future protocol adapter and access-governance parity areas; review per feature before reuse.

Initial import classification:

| Teleport area | ServiceRadar target | Status | Notes |
| --- | --- | --- | --- |
| `api/ssh` | SSH client/dialer behavior | Blocked pending legal or cleaner dependency path | Local dependency scan reaches AGPL-header directories: `api/utils/iterutils`, `api/gen/proto/go/teleport/hardwarekeyagent/v1`, and `api/types`. |
| `api/observability/tracing/ssh` | SSH tracing spans around dial/session activity | Blocked pending legal or cleaner dependency path | Same AGPL transitive directories as `api/ssh`. |
| `lib/srv`, `lib/srv/ssh`, `lib/srv/forward` | SSH server, SFTP, forwarding behavior | Clean-room required | Source headers are AGPL in this checkout. |
| `lib/bpf`, `bpf/enhancedrecording` | Command/file/network enhanced recording | Clean-room required | Source headers are AGPL in this checkout; use public kernel/BPF interfaces and ServiceRadar-authored tests. |
| `lib/events`, `api/types/events` | Audit and recording vocabulary | Review per subpackage before import | Mixed API/event surfaces need package-level and transitive checks before reuse. |
| `lib/proxy`, `lib/kube`, `lib/srv/db`, `lib/srv/desktop`, `lib/srv/app` | Future app/database/Kubernetes/desktop adapters | Review per feature before import | Treat as parity reference until each path is classified. |

Use `scripts/check-teleport-license-paths.sh` with `TELEPORT_SRC` pointing at a Teleport checkout before adding any Teleport Go import. Use `TELEPORT_REF=<tag-or-commit>` to scan an older detached worktree, for example `TELEPORT_REF=v14.4.0`, without mutating the local Teleport checkout. A candidate import is not considered clean just because the directly imported files have Apache-2.0 headers; its transitive package directories must pass the scan or receive explicit legal approval.

## Teleport Reuse Strategy
ServiceRadar should use a three-lane strategy for Teleport functionality:

1. Import current Teleport packages only when the specific package and its full transitive dependency path pass the Apache-2.0 scan. This is the preferred path for small client/API utilities because it preserves upstream fixes.
2. Vendor or adapt code from a verified Apache-2.0 Teleport tag only when importing current packages is blocked and the old implementation is small enough to maintain. The exact git tag, commit, file paths, headers, and dependency license scan must be recorded in the ServiceRadar commit or design note that introduces the code. Do not mix copied Apache-era source with later AGPL modifications.
3. Write a ServiceRadar clean-room implementation when the current code is AGPL and the old Apache-era implementation is too stale, too large, or too tightly coupled to Teleport internals.

Local checkout findings:
- `v14.4.0` is dated May 20, 2025 and still has an Apache-2.0 repository `LICENSE` in this checkout.
- `v14.4.0:lib/bpf/bpf.go` has an Apache-2.0 file header, while `v15.0.0:lib/bpf/bpf.go` and current `HEAD:lib/bpf/bpf.go` have AGPL headers.
- `v14.4.0` `lib/srv/...` files sampled locally, including app and database server paths, have Apache-2.0 headers.
- `TELEPORT_REF=v14.4.0 scripts/check-teleport-license-paths.sh github.com/gravitational/teleport/lib/bpf github.com/gravitational/teleport/lib/srv` reports no AGPL headers in those v14.4.0 transitive Teleport dependency directories, while the same package scan against current `master` reports AGPL paths.
- `github.com/gravitational/teleport/api/ssh` is not present as an importable package at `v14.4.0`; `github.com/gravitational/teleport/api/observability/tracing/ssh` does scan clean at `v14.4.0`.

Practical rule: treat Teleport v14.x as the likely Apache-2.0 source baseline, but verify each file and dependency path before copying or vendoring. Treat Teleport v15+ and current `master` server/BPF implementation paths as AGPL unless a specific file/package scan proves otherwise. Even when a v14 package scans clean, prefer ServiceRadar-owned implementations for large/stale subsystems unless the vendored surface is small, isolated, and maintainable.

ServiceRadar eBPF strategy:
- The agent has one shared eBPF runtime boundary in `go/pkg/agent/ebpf` backed by `github.com/cilium/ebpf` and generated with `bpf2go`.
- Remote-access enhanced recording must reuse that runtime rather than introducing a second loader/runtime stack.
- Teleport BPF sources, even when v14 scans clean, should be treated as behavior reference only unless a later explicit vendoring review decides the maintenance cost is worth it. The default path is ServiceRadar-authored probes and normalizers over the shared cilium/ebpf runtime.

Current reuse ledger:

| Area | Teleport evidence | ServiceRadar decision |
| --- | --- | --- |
| Current Teleport checkout | `~/src/teleport` HEAD `42a4eaafeefee26e52bbd32ceec9699de1e9040c` from 2026-05-08 | No direct imports approved for remote-access server/BPF paths. Current scans of `lib/bpf`, `lib/srv`, `api/ssh`, and `api/observability/tracing/ssh` report AGPL transitive directories. |
| Apache-era baseline | Tag `v14.4.0` commit `8113e07dc94cf2977247346d5ec28ca0d5753c54` from 2025-05-20 | Candidate reference baseline only. `TELEPORT_REF=v14.4.0 scripts/check-teleport-license-paths.sh github.com/gravitational/teleport/lib/bpf github.com/gravitational/teleport/lib/srv github.com/gravitational/teleport/api/observability/tracing/ssh` reports no AGPL headers in Teleport dependency directories. |
| SSH certificate issuance | ServiceRadar-owned `go/pkg/remoteaccess/sshca`; no Teleport files copied or vendored | Keep owned implementation. Teleport may remain behavior reference only unless a small Apache-clean package is separately approved. |
| SSH server, SFTP/SCP, app/database/Kubernetes/desktop adapters | Current `lib/srv` is blocked by AGPL headers and AGPL transitive directories; v14.4.0 scans clean in sampled server paths | Clean-room implementation by default. Any old-tag vendoring must record exact files, headers, ref, dependency scan output, and maintenance/security delta review. |
| Enhanced recording/BPF | Current `lib/bpf` and related server paths are blocked; v14.4.0 `lib/bpf` scans clean | Keep ServiceRadar-owned cilium/ebpf runtime and probes. Treat Teleport BPF source as architecture reference unless a future explicit vendoring review approves a small isolated old-tag subset. |
| SSH tracing helpers | Current `api/observability/tracing/ssh` is blocked by AGPL transitive directories; v14.4.0 scans clean | Do not import current package. Consider only if a future small dependency path can be pinned and scanned clean. |

Before any future Teleport copy, vendoring, or import:
- Record the exact Teleport tag/commit, source file paths, headers, and license scan command/output in the ServiceRadar change.
- Scan direct and transitive Teleport package directories; direct file headers are not sufficient.
- Verify no later AGPL implementation deltas are being mechanically copied into an Apache-era file.
- Prefer ServiceRadar-owned code for large subsystems, stale old-tag code, BPF probes, and security-critical policy boundaries.

## Teleport v14 SSH CA Architecture Findings
The local Teleport `v14.4.0` tag has an Apache-2.0 repository license and is useful as an architectural baseline for certificate-based OpenSSH access. These findings are design constraints for ServiceRadar; they are not permission to copy later AGPL implementation code.

Key architecture patterns to preserve:
- Teleport separates the Auth/CA service from the Proxy path. The proxy checks roles and asks Auth to sign a dynamically generated OpenSSH certificate; the target OpenSSH server trusts the CA public key through `TrustedUserCAKeys`.
- The signing request is built around a public key, user identity, role set, trait-expanded principals, target/cluster routing, and a requested TTL. The private key is not a stored target credential.
- TTL is not user-controlled. It is defaulted or bounded by auth preference, the active user session, and role/session maximums.
- Unix login principals are derived from roles after IdP traits are applied, then filtered by session TTL and deny/allow policy.
- Cert issuance is gated by the caller's authority. Teleport's role wrapper allows the OpenSSH cert issuance path only for trusted proxy roles, while normal user cert issuance protects against recursive impersonation and indefinite self-renewal.
- MFA, device trust, access requests, locks, and active approvals can become part of the certificate issuance decision before the target connection opens.
- OpenSSH agentless access requires targets to be registered as resources with an address/hostname/labels, so RBAC and audit are applied to a known target instead of arbitrary browser-supplied hostnames.
- Audit and recording are preserved by routing the target connection through the proxy path. Direct user bypass is limited because the signing CA is held by Auth, not by arbitrary clients.

ServiceRadar should adapt those patterns as follows:
- Core or a dedicated remote-access CA service owns SSH CA key material. web-ng, agent-gateway, and edge agents MUST NOT hold the CA private key.
- The browser or a local helper generates or exposes a per-session public key. ServiceRadar signs only that public key after Authentik/SSO identity, ServiceRadar RBAC, approval, target route, and TTL checks.
- The selected agent receives a session-scoped SSH credential envelope only after the session grant is bound to one actor, target, selected agent, protocol, principal set, and TTL.
- The certificate issuer returns the signed certificate, selected Unix login, credential mode, protocol, selected agent, target, and audit metadata, but never returns or persists the matching private key. The remote-access broker rejects mismatched certificate envelopes and merges a valid issuer envelope with the user-present session key only when emitting the one-time agent `open` frame.
- Generic SSH certificate issuance must be non-renewable from the session credential. A certificate issued for a remote-access session MUST NOT be usable to ask ServiceRadar for another certificate.
- OpenSSH targets should be represented as inventory/remote-access resources with labels, reachable address, host key policy, allowed agents, and allowed principals. Free-form host/port entry may exist only behind explicit policy.
- Audit events should include actor, IdP subject, sanitized IdP groups/traits, selected principals, target, selected agent, certificate serial/key ID/fingerprint, CA key ID, TTL, approval/MFA context, and final outcome. They must not include private key bytes, passphrases, or terminal input.

Validation harness:
- `scripts/remote-access-authentik-oidc-ssh-smoke.sh` provisions a disposable Authentik OIDC application, group, user, and post-authenticated authorization code in the Kubernetes `authentik` namespace. It then exchanges the code at Authentik's discovered token endpoint, verifies the signed ID token through ServiceRadar's OIDC client, maps the Authentik group claim to an SSH login principal, issues a ServiceRadar short-lived OpenSSH user certificate through the command signer, and authenticates to an OpenSSH target configured with `TrustedUserCAKeys`.
- The harness generates temporary CA/user key material under `mktemp`, deletes the Authentik fixture unless `SERVICERADAR_AUTHENTIK_SMOKE_KEEP=1`, and never creates or stores a reusable target password, target private key, or shared bastion account.
- The harness accepts external target overrides through `SERVICERADAR_REMOTE_ACCESS_SSH_TARGET_HOST` and `SERVICERADAR_REMOTE_ACCESS_SSH_TARGET_PORT`; without overrides it starts a temporary local `sshd` configured for OpenSSH certificate auth only.
- Before changing the SSH certificate issuer, Authentik OIDC handling, principal mapping, command signer, or OpenSSH integration, run this harness when the Authentik Kubernetes namespace is reachable. Ordinary workstation validation must at least keep `bash -n scripts/remote-access-authentik-oidc-ssh-smoke.sh` and the non-integration SSH CA package tests passing.

## Credential Custody Modes
### Centrally Brokered Secret
The control plane stores an encrypted credential and grants a short-lived, scoped broker reference to the selected agent. This is acceptable for low-scope API tokens, break-glass credentials with strict approval, or customers that explicitly choose central storage.

Constraints:
- Secrets remain encrypted at rest.
- Grants are scoped to one agent, one target, one protocol, one session, and a short TTL.
- The browser never receives plaintext.
- Audit records include credential rule ID but not secret material.
- The current resolver boundary is `ServiceRadar.Edge.RemoteAccessCentralCredentialGrants`: it resolves an enabled, remote-access-purpose credential rule, emits an in-memory `credential_broker` grant with a `credentialref:network-credential-secret:*` reference, and lets the generic broker include that grant in the one-time agent `open` frame while stripping any SSH plaintext from central-custody metadata.

### User-Present Session Credential
The operator supplies a credential at session start. This can mean a pasted password/key that is held in memory only for the session, a browser-held non-extractable key, a local helper, or a workstation SSH agent bridge.

Constraints:
- Session credentials are never persisted.
- For generic inventory SSH, this SHOULD be the default first implementation: the browser accepts an SSH private key file or pasted key plus optional passphrase, sends it only when the operator starts a session, and the selected agent keeps it in memory only long enough to dial the target.
- Browser-side "remember this key" behavior MUST be disabled by default, deployment-policy controlled, client-only, and clearly labeled. The platform MUST NOT sync or persist that private key in Postgres, object storage, gateway state, or core state.
- Browser-held non-extractable keys reduce raw-key exfiltration but do not prevent malicious loaded app code from requesting signatures during the active session.
- For high assurance, prefer local helper or hardware-backed signing where the private key never enters web app JavaScript memory.

### Short-Lived Certificate / Hardware-Backed Signing
Long term, generic SSH access should prefer short-lived SSH certificates issued after RBAC/approval, optionally backed by FIDO2/WebAuthn or a local SSH agent.

Constraints:
- Certificates must have narrow principals, target constraints, TTL, and audit correlation.
- The CA key must not run in web-ng.
- Revocation and expiry behavior must be documented before enabling broad rollout.

Enterprise target model:
- ServiceRadar SHOULD NOT require a shared bastion account or broad reusable SSH key for generic host access.
- The preferred enterprise model is SSO/LDAP-authenticated ServiceRadar users mapped by RBAC to allowed SSH principals, then issued short-lived SSH certificates by a ServiceRadar remote-access CA.
- Linux targets can either run a ServiceRadar/Teleport-like node component or configure OpenSSH to trust the ServiceRadar user CA with `TrustedUserCAKeys`.
- LDAP/PAM can remain the host account/session authority, but ServiceRadar should avoid pass-through storage of LDAP passwords. The SSO/LDAP login proves user identity; the short-lived SSH certificate is the per-session access credential.
- User-present credentials remain a transitional or emergency fallback, not the default enterprise posture. Agent-local reusable SSH secrets are explicitly out of scope for generic remote access because they recreate the bastion-key anti-pattern.

Authentik validation path:
- Use the internal Kubernetes Authentik deployment as the IdP for the first enterprise proof.
- Authentik provides OIDC/SAML login, MFA, groups, username, email, and policy traits. It is not expected to issue OpenSSH certificates.
- ServiceRadar owns the SSH CA role: map Authentik claims and ServiceRadar RBAC to allowed SSH principals, generate or accept a session public key, and sign a short-lived OpenSSH user certificate.
- A test Linux target trusts the ServiceRadar user CA through OpenSSH `TrustedUserCAKeys`; PAM/LDAP may still manage local account/session policy.
- The validation should prove that no reusable target password, shared bastion account, or long-lived target private key is stored in web-ng, core, agent-gateway, or the database.

## Protocol Adapters
Protocol adapters run on the selected agent.

- `ssh`: PTY over SSH, rendered with xterm.
- `proxmox-console`: planned provider adapter family; API tickets, termproxy, VNC, and compatibility SSH remain unavailable unless their separate changes establish exact credential, protocol, renderer, and live-proof readiness.
- `vsphere-console`: future provider adapter for VM console APIs.
- `rdp`: future graphical adapter with a renderer different from xterm, but the same session, RBAC, audit, and route.
- `cea-852`: future OT/industrial adapter for Component Network over IP, commonly used to carry LonTalk/LON frames over UDP/TCP port 1628. This should remain deferred until real test gear or representative captures are available.

CEA-852 must be treated as a high-risk BMS/OT protocol, not as a generic shell. Claroty Team82's 2026 research describes CEA-852 as a common path for bringing LonTalk building-management systems onto IP networks and highlights weak/default authentication conditions, optional IP-852 HMAC, mandatory but MD5-based RNI/LPA authentication, and vendor-specific packet types that can affect device configuration or availability. Any first implementation should therefore be read-only discovery/diagnostics by default. Write/control operations, packet crafting, reboot/configuration actions, or credential/key material handling for CEA-852 require a separate approved proposal, lab validation, and explicit customer policy enablement.

The platform channel carries framed data/control messages: open, data, resize, heartbeat, close, error, and terminal outcome. Protocol details stay in the adapter.

## Proxmox Console vs Generic SSH
Proxmox console support must not be modeled as generic SSH key custody. A future PVE/LXC/QEMU provider adapter must require an explicit least-privilege `console_access` rule separate from read-only inventory enrichment, request one-session provider material only after authorization, and proxy the protocol through the generic tunnel without exposing provider secrets to the browser. Until the relevant protocol change proves that path, native console actions remain unavailable.

Generic inventory device SSH is different. For early compatibility, the operator may provide a key, certificate, signing capability, or password per session from the browser or a local helper. The target enterprise path is ServiceRadar-issued short-lived SSH certificates backed by SSO/LDAP identity and RBAC. The selected agent MUST NOT use a reusable agent-local bastion key for generic SSH access.

The SSH adapter must:
- Accept private key bytes, passphrases, and OpenSSH user certificates only inside a session-open frame or a one-time session credential grant.
- Treat `credential_mode: "ssh_certificate"` and `ssh.certificate` as a session-scoped OpenSSH user certificate that must be paired with the matching `ssh.private_key`; the agent must reject a certificate without the matching key material.
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
- Agent-routed SSH host-key verification uses the shared `remoteaccess.SSHHostKeyCallback` path. Both generic SSH and the legacy Proxmox SSH console path support `known_hosts`, `trust_on_first_use`, and explicit `skip_verify`, with TOFU pinning unknown hosts and rejecting changed keys. The control plane now has persistent host-key trust state for known-host collection, TOFU lifecycle review, conflict detection, trust, revocation, and rotation audit, plus an initial operator UI for review, trust, revocation, and rotation.
- Audit must record actor, target, protocol, selected agent, credential rule, approval, timestamps, terminal outcome, and policy decisions.
- Session byte recording must be optional and policy-controlled. If enabled, secrets should be redacted where feasible, but recording must be treated as sensitive data.
- Enhanced BPF recording must be policy-controlled, session-correlated, and treated as sensitive telemetry with explicit retention and access policy.

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
4. Add agent-side SSH adapter using user-present credentials as a transitional fallback; do not add generic agent-local reusable SSH secrets.
5. Add short-lived SSH certificate issuance using Authentik-derived identity claims and a ServiceRadar-managed user CA.
6. Add provider console adapters as target metadata emitters from hypervisor enrichment.
7. Add RDP only after the protocol/renderer split is proven.
8. Add CEA-852/CN-IP support only after we have a test strategy using real equipment, partner-provided captures, or an accepted simulator.
9. Start CEA-852 with passive capture parsing or safe diagnostics only; defer active control paths until we can prove safety against real devices.
