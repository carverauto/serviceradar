## 1. Design
Archival reconciliation: design and scaffold tasks for future protocol areas do not assert those protocols are production-ready. SSH CA tasks below cover library/policy/disposable-smoke primitives, not release packaging or live target trust. File transfer, app/TCP, packaged SSH CA access, automatic host-key observation, production eBPF, provider-native Proxmox, QEMU, and RDP completion remain tracked by their separate active changes.

- [x] 1.1 Inventory existing Proxmox console, camera relay, agent control stream, and credential broker paths that can be reused.
- [x] 1.2 Define remote-access session/resource names, state machine, frame types, and terminal outcomes.
- [x] 1.3 Inventory Teleport capability areas and classify each candidate package/path as importable Apache-2.0, blocked by AGPL/transitive risk, or requiring legal review.
- [x] 1.4 Define credential custody modes and policy constraints for short-lived certificate, user-present, and exceptional centrally brokered credentials.
- [x] 1.5 Define RBAC, approval, audit, TTL, idle timeout, optional recording, and enhanced BPF tracing policies.
- [x] 1.6 Define future protocol-adapter requirements for graphical, app, database, Kubernetes, desktop/RDP, and OT protocols, including deferred CEA-852/CN-IP support.
- [x] 1.7 Define the Proxmox-console versus generic-SSH credential split so PVE consoles use provider tickets and general SSH defaults to user-present or short-lived certificate credentials.
- [x] 1.8 Define clean-room BPF/enhanced-recording event schemas, kernel attachment strategy, compatibility gates, loss counters, and fallback policy.
- [x] 1.9 Define the Wasm provider-adapter trust boundary: provider-specific console/inventory code can live in plugins, but identity, custody, host-key trust, audit, recording, and eBPF enforcement stay in trusted ServiceRadar code.

## 2. Implementation
- [x] 2.1 Add generic remote-access session resources and APIs with compatibility for current Proxmox console routes.
- [x] 2.2 Refactor xterm/webpty UI into a protocol-neutral remote-console component.
- [x] 2.3 Add gateway-to-agent session routing over the existing agent-initiated control stream.
- [x] 2.4 Add an agent-side SSH protocol adapter with user-present credential support and no generic agent-local reusable SSH secrets.
- [x] 2.5 Add user-present session credential support without persisting credentials.
- [x] 2.6 Add a Proxmox compatibility facade and provider-adapter entrypoint for the generic remote-access path; native provider transport readiness remains owned by the Proxmox console changes.
- [x] 2.7 Add audit events and RBAC/approval checks for create, attach, input, resize, close, and failure transitions.
- [x] 2.8 Add browser UI for SSO-certificate and user-present SSH modes, per-session SSH key upload/paste, optional policy-controlled client-only remembered keys, passphrase support, and browser-local key digest display without server-side key persistence.
- [x] 2.9 Add session recording storage/retention plumbing behind policy gates.
- [x] 2.10 Add the clean-room enhanced-recording interface, normalized event model, and non-BPF fallback boundary; production eBPF attachment remains owned by `add-remote-access-ebpf-recording`.
- [x] 2.11 Add a ServiceRadar-owned SSH CA signing primitive for short-lived OpenSSH user certificates.
- [x] 2.12 Add a core SSH certificate policy boundary that maps actor permission, target principal policy, requested principals, and TTL into a bounded signing request shape.
- [x] 2.13 Add a core SSH certificate issuance orchestrator that combines policy with an injected signer and returns a session certificate envelope.
- [x] 2.14 Add ServiceRadar SSH CA issuance for Authentik-authenticated users, mapping IdP claims and RBAC to short-lived OpenSSH user certificates.
- [x] 2.15 Add future adapter scaffolds or proposals for app/database/Kubernetes/desktop-style access once SSH and recording primitives are stable.

## 3. Validation
- [x] 3.1 Add unit tests for credential custody policy and grant scoping.
- [x] 3.2 Add gateway/agent tests proving frames are accepted only from the session-owning agent and selected gateway route.
- [x] 3.3 Add browser/channel tests proving tickets and credentials are not echoed to the client.
- [x] 3.4 Add a demo SSH target test through an agent in a non-platform network path.
- [x] 3.5 Add regression tests for the generic provider-console session metadata and compatibility routing contract; live PVE/LXC/QEMU transport proof remains owned by the Proxmox console changes.
- [x] 3.6 Document why CEA-852/CN-IP support remains deferred until representative LonTalk/CN-IP test data is available, and require read-only/passive behavior before any active control support.
- [x] 3.7 Add license-review tests or scripts that fail if a supposedly imported Teleport path includes AGPL-header source in its transitive Go package directories.
- [x] 3.8 Add enhanced-recording tests for command/file/network event normalization, session correlation, dropped-event counters, and policy fallback behavior.
- [x] 3.9 Validate Authentik OIDC login to ServiceRadar SSH certificate issuance against an OpenSSH target configured with `TrustedUserCAKeys`, proving no shared bastion credential or reusable target key is stored.

## 4. Teleport-Parity Hardening and Follow-Up
- [x] 4.1 Remove generic agent-local reusable SSH credential file support from the agent and docs.
- [x] 4.2 Ensure browser attach grants keep SSH private keys, passwords, passphrases, and certificate envelopes in memory only; persisted session metadata must not act as a credential carrier.
- [x] 4.3 Ensure agent-returned frames and SSH open payloads are accepted only when session ID plus authenticated agent/gateway route match the broker session.
- [x] 4.4 Ensure gateway console-frame broadcasts only come from registered agent control streams and are stamped with authenticated stream ownership.
- [x] 4.5 Ensure browser-selected central custody is rejected by the public SSH create/attach path until a trusted policy-owned broker grant resolver exists.
- [x] 4.6 Require centrally brokered remote-access sessions to reference a trusted credential rule and approval before issuing an attach ticket.
- [x] 4.7 Add the scoped central credential grant resolver: one session, one selected agent/gateway route, one target, one protocol, short TTL, no browser plaintext, redacted audit.
- [x] 4.8.1 Share the agent-side known-hosts and trust-on-first-use implementation across generic SSH and legacy Proxmox SSH console paths.
- [x] 4.8.2a Add host key policy management API primitives: persistent known-host collection state, trust-on-first-use lifecycle, rotation/conflict handling, and audit.
- [x] 4.8.2b Add operator UI for host key review, trust, revocation, and rotation workflows.
- [x] 4.9 Add access-request parity: request creation, approval lifecycle, reviewer policy, expiration, and session binding.
- [x] 4.10 Add session replay parity beyond metadata manifests: policy-gated transcript/event storage, redaction boundaries, retention, export controls, and replay UI/API.
  - [x] 4.10.1 Add policy-gated transcript/event storage with retention inheritance and redaction boundaries.
  - [x] 4.10.2 Add authenticated replay/export API primitives with a dedicated export permission.
  - [x] 4.10.3 Add an operator replay UI backed by the replay API.
- [x] 4.11 Add file-transfer parity planning for SFTP/SCP-style access with RBAC, recording, quota, and content-audit policy.
- [x] 4.12 Add app/database/Kubernetes/desktop/RDP adapter proposals with per-protocol threat models before implementation.
- [x] 4.13 Split ServiceRadar-owned probes, attachment, kernel compatibility, truthful capability advertisement, fail-closed policy, and live proof into `add-remote-access-ebpf-recording` rather than claiming them in the generic foundation.
- [x] 4.14 Keep Teleport source reuse notes current for each imported or copied area, including exact tag/commit, file paths, headers, and transitive license scan output.
- [x] 4.15 Maintain an Authentik/OpenSSH smoke test path for SSO -> ServiceRadar SSH CA -> `TrustedUserCAKeys` target login with no shared bastion credential.
