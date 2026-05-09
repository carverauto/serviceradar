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

## Recording Modes
ServiceRadar should support multiple recording depths rather than treating terminal bytes as the only audit artifact.

- `lifecycle`: required for every session; records start, attach, resize, close, failure, timeout, approval, selected agent, target, protocol, and credential custody metadata.
- `terminal_io`: optional and policy-controlled; records terminal input/output or graphical frames where supported. This data is sensitive and must be protected like credentials-adjacent evidence.
- `enhanced_linux`: future Linux-agent mode inspired by Teleport enhanced session recording. When enabled on a compatible Linux agent, the agent records structured process/file/network events for the session, such as exec-family system calls, open-family file activity, and outbound network connections.

Enhanced Linux recording is not a substitute for OS hardening. It requires a trusted agent host, compatible kernel/eBPF support, explicit policy enablement, lost-event accounting, and clear failure behavior. For high-security policy, failures to initialize enhanced recording may be `strict` and deny or terminate the session; for lower-risk policy, failures may be `best_effort` and continue with lifecycle/terminal recording only.

The event classes must be selectable per policy so operators can enable only the telemetry needed for a target class:
- `command`: executed program, path, arguments where safe to capture, return code, user/session identity.
- `file`: opened file path, flags, return code, process identity.
- `network`: source/destination addresses, destination port, process identity.

Enhanced recording must be implemented on the agent side, bound to the ServiceRadar remote-access session ID, and emitted as structured audit/security events. Browser clients must not be trusted to provide enhanced recording telemetry.

## Third-Party Code Strategy
Teleport is a useful reference implementation, but its repository is mixed-license. ServiceRadar may import or copy Teleport code only after verifying the exact module, package, files, and transitive dependency path are compatible with ServiceRadar's Apache-2.0 licensing.

The `github.com/gravitational/teleport/api` Go module is a good candidate for direct import where it fits, especially Apache-2.0 observability/tracing packages, because importing a stable upstream module is cleaner than copying source into the agent. Any import must still pass dependency review and must stay behind ServiceRadar-owned interfaces so we can replace it if upstream scope or licensing changes.

The current Teleport `lib/bpf` implementation is not an import candidate because the inspected Go files carry AGPL headers. The enhanced-recording BPF path should therefore use Teleport as an architecture reference only: define ServiceRadar-owned interfaces, generate our own `vmlinux.h` from kernel BTF or a documented build input, and clean-room implement the eBPF programs and Go loader using compatible dependencies such as `github.com/cilium/ebpf`.

Do not treat an eBPF `SEC("license")` string such as `Dual BSD/GPL` as sufficient source-file licensing. The file header, repository license, generated-code provenance, and dependency graph all need to be compatible before code can be imported, copied, or vendored.

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
