# Change: Harden Proxmox Console Credential Custody

## Why

ServiceRadar has Proxmox inventory and console capabilities, but the implemented trust boundaries do not yet match the security properties claimed by the active Proxmox changes. Current configuration shapes can expose credential grants, secret references, or resolved token material to a Wasm plugin; the plugin can influence request URLs, authentication headers, TLS verification, and console targets; console creation accepts client-selected mode and credential-rule fields; and the current Proxmox identity shape can collide when two integrations discover clusters with the same cluster name, node names, and VMIDs.

Those gaps are security blockers for enabling the feature in the `demo` namespace. A plugin that can observe a reusable Proxmox token or select the request target can turn the agent into a credential-exfiltration or SSRF primitive. An ambiguous virtualization identity can associate a guest with the wrong PVE controller and send a console request to another cluster. A console permission that does not separately authorize use of the selected credential can make the broker a confused deputy.

This change makes the agent host, rather than Wasm, the only component that can resolve and apply Proxmox credentials. It also introduces source-scoped virtualization identities and requires the console service to derive the owning controller and node from authoritative inventory relationships. The result is a fail-closed contract that can be demonstrated against both farm01 and tonka01 even when their native names and VMIDs overlap.

## What Changes

- **BREAKING** Proxmox inventory and console assignments no longer place tokens, passwords, private keys, provider tickets, cookies, CSRF values, redeemable secret references, or broker grants in Wasm-visible parameters. A typed host-only assignment envelope carries the authorization grant to the agent broker, and Wasm receives only non-secret semantic operation inputs.
- **BREAKING** the Proxmox HTTP, WebSocket, and SSH paths become trusted agent-hosted connectors. They construct the final request or session and enforce the granted scheme, canonical origin, effective port, resolved address, target, TLS policy, operation, method, path/query, body policy, redirect policy, protected headers, SSH principal, and host-key policy. A plugin cannot supply `Authorization`, cookies, provider tickets, target substitutions, TLS downgrade flags, or an arbitrary privileged request body.
- Introduce `proxmox:v3` virtualization identities scoped by immutable ServiceRadar integration and controller IDs plus the native cluster identity. Identical cluster names, node names, and VMIDs from farm01 and tonka01 remain distinct. Legacy identities become read-only aliases only when they map unambiguously; ambiguous aliases are quarantined rather than merged.
- Resolve a guest console through the guest's authoritative virtualization owner relationship to the exact Proxmox integration, cluster, owning node, and controller base origin. Proxmox console code never derives `https://<guest-ip>:8006`, never uses browser-supplied target metadata, and never silently falls back to another PVE.
- Require both `devices.console.open` and the new `devices.console.credentials.use` permission, plus an allow decision from the selected credential rule's actor and `console_access` use policy, before any secret resolution or privileged network effect.
- Bind each broker resolution and native console ticket to the current actor, authorization decision, assignment, session, device, versioned provider identity, integration, controller, cluster, node, VMID/guest type, credential rule, agent, gateway, console mode, canonical target origin, purpose, expiry, and use count. Any mismatch fails before resolution or dial.
- Bind each console open to the exact active assignment policy version and deterministic fingerprint in typed control-stream fields, and pin every broker frame to the authenticated agent and selected gateway node. Missing or mismatched bindings fail before plugin startup, credential resolution, or dial.
- Carry the server-selected Proxmox SSH host-key policy only in host authority. The supported closed enum is `known_hosts` or `trust_on_first_use`; browser/Wasm overrides, missing/unknown values, and `skip_verify` fail closed.
- Make mixed control-plane/agent/plugin versions fail closed. Legacy inline-secret assignments and v1/v2 identity writes cannot be used as a compatibility path for authenticated inventory or console operations.
- Add redacted authorization, resolution, connector, and lifecycle audit events; negative security tests; migration tests; and an explicit farm01/tonka01 demo proof that includes overlapping names and VMIDs.

## Relationship to Existing Changes

This change extends the host-owned broker model in `add-external-secret-provider-broker`; it does not create another secret store or make a plugin a credential principal. It applies that model to Proxmox with a stricter semantic connector and exact assignment/session binding.

The active changes `add-proxmox-plugin-credential-rules`, `add-proxmox-guest-network-identity`, `fix-proxmox-inventory-plugin-reliability`, and `refactor-provider-neutral-hypervisor-enrichment` describe important intended outcomes, but some completed tasks and requirements overstate what the current implementation proves. In particular, existing code and tests still admit Wasm-visible credential fields, plugin-authored authorization and target data, client-selected console fields, and cluster-name-scoped identities. Those prior completion markers are not acceptance evidence for this change.

Where an earlier active delta conflicts with this proposal, this proposal is the stricter normative contract. The earlier changes MUST NOT be archived as proving secure Proxmox credential custody or collision-safe console routing until the tests and deployment evidence in this change pass. Historical proposals remain intact; implementation and final spec reconciliation will preserve their provider-neutral behavior while superseding unsafe Proxmox-specific assumptions.

## Impact

- Affected specs: `agent-config`, `credential-secret-providers`, `network-credential-rules`, `wasm-plugin-system`, `device-inventory`, `proxmox-integration-plugin`, `proxmox-console-access`
- Affected control-plane areas: Proxmox provider profiles, credential-rule policy and RBAC catalog, assignment generation, console session creation/authorization, virtualization reconciliation and migration, audit projection
- Affected agent areas: plugin assignment parsing, host-only credential envelopes, credential broker validation, trusted HTTP/WebSocket/SSH connectors, DNS/TLS/redirect enforcement, redaction and diagnostics
- Affected plugin areas: Proxmox inventory and console configuration schemas, semantic host-call contracts, removal of raw token/header/target/TLS inputs
- Affected data: virtualization provider-instance and object identities, unambiguous legacy aliases, guest-to-owner relationships, console session binding fields
- Affected operations: coordinated control-plane and agent rollout, credential-rule policy migration, farm01 and tonka01 integration validation, demo feature enablement only after proof completion

## Security Outcome

After this change, compromise or misuse of the Proxmox Wasm plugin does not reveal reusable Proxmox credentials and does not let the plugin redirect a credential-bearing request or console session. A user who can view or open a device console but is not explicitly allowed to use the matching credential cannot cause resolution. A guest discovered through one Proxmox integration cannot collide with or open a console through another integration, even when both environments use the same cluster display name, PVE node name, and VMID.
