## 1. Design
- [ ] 1.1 Inventory existing Proxmox console, camera relay, agent control stream, and credential broker paths that can be reused.
- [ ] 1.2 Define remote-access session/resource names, state machine, frame types, and terminal outcomes.
- [ ] 1.3 Define credential custody modes and policy constraints for central, agent-local, user-present, and short-lived certificate credentials.
- [ ] 1.4 Define RBAC, approval, audit, TTL, idle timeout, and optional recording policies.
- [ ] 1.5 Define future protocol-adapter requirements for graphical and OT protocols, including RDP and deferred CEA-852/CN-IP support.
- [ ] 1.6 Define the Proxmox-console versus generic-SSH credential split so PVE consoles use provider tickets and general SSH defaults to session-present or agent-local credentials.
- [ ] 1.7 Define optional enhanced Linux recording inspired by Teleport BPF recording, including command/file/network event classes, compatibility gates, lost-event accounting, and strict/best-effort failure policy.
- [ ] 1.8 Define a third-party code policy that allows Apache-2.0 Teleport package imports after package/dependency review, excludes AGPL Teleport BPF code, and requires clean-room enhanced-recording implementation where licensing is not explicitly compatible.

## 2. Implementation
- [ ] 2.1 Add generic remote-access session resources and APIs with compatibility for current Proxmox console routes.
- [ ] 2.2 Refactor xterm/webpty UI into a protocol-neutral remote-console component.
- [ ] 2.3 Add gateway-to-agent session routing over the existing agent-initiated control stream.
- [ ] 2.4 Add an agent-side SSH protocol adapter with agent-local credential support.
- [ ] 2.5 Add user-present session credential support without persisting credentials.
- [ ] 2.6 Convert Proxmox console handling into a provider adapter that uses the generic remote-access path.
- [ ] 2.7 Add audit events and RBAC/approval checks for create, attach, input, resize, close, and failure transitions.
- [ ] 2.8 Add browser UI for per-session SSH key upload/paste, optional client-only remembered keys, passphrase support, and key fingerprint display without server-side key persistence.
- [ ] 2.9 Add a future Linux-agent enhanced recording adapter that emits structured command, file, and network telemetry for sessions when policy and host capabilities allow it.
- [ ] 2.10 Wrap any imported Teleport API tracing code behind ServiceRadar-owned interfaces and document the reviewed upstream module/package/file set.

## 3. Validation
- [ ] 3.1 Add unit tests for credential custody policy and grant scoping.
- [ ] 3.2 Add gateway/agent tests proving frames are accepted only from the session-owning agent.
- [ ] 3.3 Add browser/channel tests proving tickets and credentials are not echoed to the client.
- [ ] 3.4 Add a demo SSH target test through an agent in a non-platform network path.
- [ ] 3.5 Add regression tests that Proxmox console still works through the generic path.
- [ ] 3.6 Document why CEA-852/CN-IP support remains deferred until representative LonTalk/CN-IP test data is available, and require read-only/passive behavior before any active control support.
- [ ] 3.7 Add capability and failure-mode tests for enhanced Linux recording, including unsupported kernels, lost-event counters, and strict versus best-effort behavior.
- [ ] 3.8 Add license/dependency review checks or documented allowlists before accepting Teleport-derived imports or copied source.
