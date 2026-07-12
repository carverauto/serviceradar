## ADDED Requirements

### Requirement: Proxmox guest consoles route through the authoritative parent PVE
The system SHALL resolve a Proxmox guest console from the canonical guest to exactly one active virtualization guest record, parent PVE host, provider instance, guest type, VMID, registered PVE endpoint, and eligible edge route. The guest remains the audited target while network traffic terminates at its parent PVE.

#### Scenario: IP-less QEMU guest
- **WHEN** a QEMU guest has an unambiguous provider reference, VMID, and parent PVE but no discovered guest IP
- **THEN** native console readiness can use the parent PVE endpoint without inventing or requiring a guest IP

#### Scenario: Ambiguous provider identity
- **WHEN** a canonical device maps to multiple active Proxmox provider references, nodes, guest types, or VMIDs
- **THEN** console access fails closed with `identity_ambiguous` and does not select a target heuristically

#### Scenario: Same node and VMID exist in two clusters
- **WHEN** Farm and Tonka contain the same PVE node name or guest VMID
- **THEN** provider-instance-scoped host and guest references preserve distinct records, relationships, targets, and console routes

### Requirement: Proxmox terminal and graphical consoles use distinct typed transports
The system SHALL render PVE node and LXC terminal consoles with typed PTY frames and SHALL render graphical QEMU consoles with a protocol-aware framebuffer transport. Raw RFB/VNC bytes MUST NOT be emitted as terminal data or rendered with xterm.

#### Scenario: LXC termproxy
- **WHEN** an authorized user opens a ready LXC console
- **THEN** the selected agent opens the parent PVE `termproxy`, forwards bounded terminal/resize/control frames, and web-ng renders xterm

#### Scenario: QEMU graphical console
- **WHEN** an authorized user opens a ready graphical QEMU console
- **THEN** the selected agent authenticates the PVE VNC session, converts RFB updates and input to the desktop-media/control contracts, and web-ng renders the graphical desktop component

#### Scenario: QEMU serial console
- **WHEN** a registered QEMU serial console is explicitly available and selected by server policy
- **THEN** the system may use `termproxy` and xterm without treating the graphical display as terminal data

### Requirement: Proxmox console credentials are explicit and session scoped
Proxmox console access SHALL require an explicit `console_access` credential rule with provider, resource, endpoint, route, and privilege scope. A read-only inventory rule MUST NOT implicitly qualify for interactive access, and decrypted console credentials MUST NOT be stored in durable add-on assignments.

#### Scenario: Inventory token only
- **WHEN** a device matches a Proxmox inventory-enrichment credential rule but no console-access rule
- **THEN** inventory continues to work and interactive console readiness reports `credential_unavailable`

#### Scenario: Authorized console grant
- **WHEN** an authorized console session matches one enabled console-access rule
- **THEN** core issues one short-lived grant bound to the actor, session, guest/node, PVE endpoint, agent, gateway, protocol, and TTL

#### Scenario: Session ends
- **WHEN** the console closes or fails
- **THEN** PVE API tokens, tickets, cookies, CSRF values, VNC passwords, and SSH material are discarded and never appear in browser-visible state, URLs, audit payloads, recordings, or reusable agent config

### Requirement: Proxmox consoles use hardened generic session guarantees
Proxmox console sessions SHALL provide the generic remote-access guarantees for atomic single-use attach, create/attach and periodic authorization, authenticated agent/gateway return binding, integrity, timeout, revocation, route-loss termination, audit, recording policy, and orphan cleanup.

#### Scenario: Return frame from the wrong route
- **WHEN** a console frame is returned by an agent or gateway other than the session's authenticated selected route
- **THEN** the frame is rejected and cannot mutate or stream into the session

#### Scenario: Authorization is revoked while active
- **WHEN** the actor loses console permission during an active session
- **THEN** periodic reauthorization closes the session, revokes its grant, and records the authorization terminal outcome

### Requirement: Proxmox device details expose ready guest actions
Device details SHALL expose provider-console actions for ready PVE nodes, LXC guests, and QEMU guests using server-derived virtualization relationships and protocol readiness.

#### Scenario: Ready guest action
- **WHEN** a Proxmox guest has unambiguous identity, a ready parent PVE route, an allowed console rule, and actor permission
- **THEN** its own device details shows the appropriate Open LXC console or Open VM console action

#### Scenario: Guest action is not ready
- **WHEN** the renderer, adapter, relationship, route, trust, or console credential is unavailable
- **THEN** device details does not launch a partial console and an authorized operator can inspect the sanitized readiness reason
