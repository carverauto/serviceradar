## 1. Design
- [x] 1.1 Inventory existing Proxmox console, camera relay, agent control stream, and credential broker paths that can be reused.
- [x] 1.2 Define remote-access session/resource names, state machine, frame types, and terminal outcomes.
- [x] 1.3 Inventory Teleport capability areas and classify each candidate package/path as importable Apache-2.0, blocked by AGPL/transitive risk, or requiring legal review.
- [x] 1.4 Define credential custody modes and policy constraints for short-lived certificate, user-present, and exceptional centrally brokered credentials.
- [x] 1.5 Define RBAC, approval, audit, TTL, idle timeout, optional recording, and enhanced BPF tracing policies.
- [x] 1.6 Define future protocol-adapter requirements for graphical, app, database, Kubernetes, desktop/RDP, and OT protocols, including deferred CEA-852/CN-IP support.
- [x] 1.7 Define the Proxmox-console versus generic-SSH credential split so PVE consoles use provider tickets and general SSH defaults to user-present or short-lived certificate credentials.
- [x] 1.8 Define clean-room BPF/enhanced-recording event schemas, kernel attachment strategy, compatibility gates, loss counters, and fallback policy.

## 2. Implementation
- [x] 2.1 Add generic remote-access session resources and APIs with compatibility for current Proxmox console routes.
- [x] 2.2 Refactor xterm/webpty UI into a protocol-neutral remote-console component.
- [x] 2.3 Add gateway-to-agent session routing over the existing agent-initiated control stream.
- [x] 2.4 Add an agent-side SSH protocol adapter with user-present credential support and no generic agent-local reusable SSH secrets.
- [x] 2.5 Add user-present session credential support without persisting credentials.
- [x] 2.6 Convert Proxmox console handling into a provider adapter that uses the generic remote-access path.
- [x] 2.7 Add audit events and RBAC/approval checks for create, attach, input, resize, close, and failure transitions.
- [x] 2.8 Add browser UI for per-session SSH key upload/paste, optional client-only remembered keys, passphrase support, and key fingerprint display without server-side key persistence.
- [x] 2.9 Add session recording storage/retention plumbing behind policy gates.
- [ ] 2.10 Add clean-room Linux enhanced-recording collector for command/file/network events behind agent capability and policy gates.
- [x] 2.11 Add a ServiceRadar-owned SSH CA signing primitive for short-lived OpenSSH user certificates.
- [x] 2.12 Add a core SSH certificate policy boundary that maps actor permission, target principal policy, requested principals, and TTL into a bounded signing request shape.
- [x] 2.13 Add a core SSH certificate issuance orchestrator that combines policy with an injected signer and returns a session certificate envelope.
- [x] 2.14 Add ServiceRadar SSH CA issuance for Authentik-authenticated users, mapping IdP claims and RBAC to short-lived OpenSSH user certificates.
- [x] 2.15 Add future adapter scaffolds or proposals for app/database/Kubernetes/desktop-style access once SSH and recording primitives are stable.

## 3. Validation
- [x] 3.1 Add unit tests for credential custody policy and grant scoping.
- [x] 3.2 Add gateway/agent tests proving frames are accepted only from the session-owning agent.
- [x] 3.3 Add browser/channel tests proving tickets and credentials are not echoed to the client.
- [x] 3.4 Add a demo SSH target test through an agent in a non-platform network path.
- [x] 3.5 Add regression tests that Proxmox console still works through the generic path.
- [x] 3.6 Document why CEA-852/CN-IP support remains deferred until representative LonTalk/CN-IP test data is available, and require read-only/passive behavior before any active control support.
- [x] 3.7 Add license-review tests or scripts that fail if a supposedly imported Teleport path includes AGPL-header source in its transitive Go package directories.
- [x] 3.8 Add enhanced-recording tests for command/file/network event normalization, session correlation, dropped-event counters, and policy fallback behavior.
- [x] 3.9 Validate Authentik OIDC login to ServiceRadar SSH certificate issuance against an OpenSSH target configured with `TrustedUserCAKeys`, proving no shared bastion credential or reusable target key is stored.
