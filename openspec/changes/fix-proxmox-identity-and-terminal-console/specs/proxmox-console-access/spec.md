## MODIFIED Requirements

### Requirement: Proxmox web console sessions
The system SHALL allow authorized operators to open browser-based PTY terminal
sessions for a Proxmox PVE node, LXC guest, or explicitly registered QEMU serial
console through the hardened generic remote-access session and broker. A guest
session SHALL retain the guest as the display and audit target while routing
network traffic through exactly one authoritative parent PVE endpoint and its
server-selected eligible edge route. QEMU graphical RFB/VNC and RDP MUST NOT be
opened, forwarded, or rendered by this terminal capability.

#### Scenario: Open PVE host terminal
- **GIVEN** a PVE host has scoped identity, a registered endpoint and TLS policy, a ready PVE-eligible edge route, an effective terminal capability, one matching `console_access` rule, and actor permission
- **WHEN** the operator opens the ready PVE terminal action
- **THEN** the generic broker creates a short-lived session and atomic single-use browser attach ticket
- **AND** the selected agent opens the allowlisted PVE node `termproxy` path and streams typed PTY frames to xterm

#### Scenario: Open LXC guest terminal
- **GIVEN** an LXC guest resolves to one scoped provider instance, VMID, authoritative parent PVE, ready route, terminal capability, console rule, and actor permission
- **WHEN** the operator opens the guest's ready terminal action
- **THEN** the selected agent opens only the parent PVE LXC `termproxy` path for that frozen node and VMID
- **AND** the browser does not require direct reachability to the PVE or guest endpoint

#### Scenario: Open explicit QEMU serial terminal
- **GIVEN** authoritative current provider configuration registers an enabled serial console for a scoped QEMU guest
- **AND** all parent PVE terminal readiness inputs are ready
- **WHEN** the operator opens the QEMU serial terminal action
- **THEN** the selected agent may open the parent PVE QEMU `termproxy` path for the frozen node and VMID
- **AND** the system treats the returned transport as typed PTY data only

#### Scenario: QEMU has only graphical console capability
- **GIVEN** a QEMU guest has VNC/RFB display capability but no authoritative registered serial console
- **WHEN** terminal readiness is evaluated or a stale client requests a terminal
- **THEN** the terminal remains unavailable with `terminal_transport_unavailable`
- **AND** the system does not call `vncproxy`, open `vncwebsocket`, forward RFB bytes, or launch xterm

#### Scenario: Guest has no discovered IP
- **GIVEN** a scoped LXC or explicit QEMU serial guest has no discovered guest IP
- **WHEN** its authoritative parent PVE endpoint and route are ready
- **THEN** native terminal readiness may succeed without inventing or requiring a guest endpoint

#### Scenario: Provider identity or parent is ambiguous
- **GIVEN** a device resolves to zero or multiple active provider instances, guest rows, guest types, VMIDs, parent PVE hosts, endpoints, or eligible routes
- **WHEN** terminal readiness or session creation runs
- **THEN** the operation fails closed with a sanitized typed reason
- **AND** it does not choose by name, metadata, IP, recency, or row order

#### Scenario: Same-name resources exist in Farm and Tonka
- **GIVEN** Farm and Tonka contain the same node name or overlapping guest identifiers
- **WHEN** an operator opens a terminal for one scoped target
- **THEN** the frozen parent, endpoint, route, credential, grant, and provider path all remain inside that provider instance
- **AND** no resource from the other instance may satisfy readiness or receive traffic

### Requirement: Console access authorization and audit
Proxmox terminal access SHALL require authorization at session creation, atomic
attach, and periodically while active. The system SHALL emit sanitized lifecycle
audit events that identify the actor, canonical display target, authoritative
parent PVE, provider instance, target kind and mode, selected agent/gateway,
policy revisions, start/end time, and close reason without terminal content or
credential material.

#### Scenario: Viewer cannot open terminal
- **GIVEN** a user can view a Proxmox device but lacks terminal permission
- **WHEN** the user attempts to create or attach a session
- **THEN** the request is denied before provider grant or credential resolution
- **AND** no provider connection is opened

#### Scenario: Authorization is revoked while active
- **GIVEN** an authorized Proxmox terminal session is active
- **WHEN** the actor loses terminal permission or an approval/hold policy changes
- **THEN** periodic reauthorization closes the provider and browser transports and revokes the session grant
- **AND** audit records one authorization terminal outcome

#### Scenario: Session lifecycle is audited
- **GIVEN** an authorized terminal session starts and later ends
- **WHEN** lifecycle audit events are emitted
- **THEN** they include the actor, display target, parent PVE, provider instance, selected route, mode, policy revisions, timestamps, and close reason
- **AND** they exclude terminal data, API tokens, passwords, SSH keys, PVE tickets, proxy tickets, cookies, CSRF values, route secrets, and internal provider response bodies

#### Scenario: Cross-instance authorization is attempted
- **GIVEN** an actor is allowed to access a target in Farm but not Tonka
- **WHEN** a request or stale readiness value would route the session through Tonka
- **THEN** creation or attach is denied before grant issuance
- **AND** the denial does not reveal Tonka credential or endpoint details outside the actor's visibility

### Requirement: Short-lived console tickets
The system SHALL use bounded, cryptographically random, short-lived,
single-use tickets for browser websocket attachment to a generic Proxmox
terminal session. Ticket consumption SHALL be atomic and SHALL precede provider
grant issuance or credential resolution.

#### Scenario: Ticket cannot be reused
- **GIVEN** a terminal session ticket has already been consumed
- **WHEN** a second websocket attempts to attach with the same ticket
- **THEN** the request is rejected atomically
- **AND** no second provider grant, stream, or lifecycle mutation is created

#### Scenario: Expired ticket is rejected
- **GIVEN** a terminal session ticket has expired
- **WHEN** a websocket attempts to attach with the expired ticket
- **THEN** the request is rejected before any provider grant or credential is resolved
- **AND** the session reaches its bounded terminal outcome when appropriate

#### Scenario: Attach readiness became stale
- **GIVEN** a ticket was issued while the target appeared ready
- **WHEN** identity, parent, route, capability, trust, credential, permission, or hold state is no longer ready at attach
- **THEN** attach fails closed and consumes or invalidates the ticket according to generic session policy
- **AND** no provider credential is resolved

### Requirement: Console credential redaction
Proxmox terminal handling SHALL keep API tokens, passwords, SSH material, PVE
tickets, proxy tickets, cookies, CSRF values, grant secrets, and internal
provider response bodies out of browser payloads, URLs, logs, audit, recordings,
traces, support artifacts, terminal metadata, durable assignments, and generic
command persistence. Public errors SHALL identify only a sanitized failure phase
and stable reason class.

#### Scenario: Provider negotiation fails
- **GIVEN** a terminal session fails while resolving a grant or negotiating PVE termproxy
- **WHEN** the failure is logged, audited, recorded, traced, or shown in the UI
- **THEN** all credential-bearing and internal response values are redacted or omitted
- **AND** the operator sees only a permitted phase and sanitized typed reason

#### Scenario: Terminal setup frame carries provider material
- **GIVEN** the selected agent receives session-scoped provider material for terminal setup
- **WHEN** setup frames or state are inspected at other platform boundaries
- **THEN** browser, web-ng, gateway metadata, recording, audit, and durable command surfaces contain no plaintext provider material

#### Scenario: Graphical payload reaches the terminal adapter
- **GIVEN** a provider response begins with RFB/VNC or otherwise indicates a framebuffer transport
- **WHEN** the terminal adapter validates the stream
- **THEN** it closes the provider stream and emits a sanitized `terminal_transport_unavailable` error
- **AND** it does not log, record, or forward the graphical payload as terminal output

### Requirement: Web terminal component integration
The web UI SHALL render ready Proxmox PVE, LXC, and explicit QEMU serial sessions
with the existing React/xterm terminal integration using typed PTY data, input,
resize, focus, error, and close events. It SHALL derive actions and labels from
server readiness and SHALL NOT render raw RFB/VNC or expose RDP through this
terminal integration.

#### Scenario: Ready terminal renders in device details workflow
- **GIVEN** an authorized PVE, LXC, or explicit QEMU serial session has consumed its attach ticket
- **WHEN** the generic broker reports the typed terminal stream ready
- **THEN** xterm renders inside the Phoenix web-ng shell
- **AND** it handles output, input, resize, focus, bounded close, and reconnect-denied states

#### Scenario: Terminal action is unavailable
- **GIVEN** one required identity, parent, terminal mode, route, trust, capability, credential, privilege, actor, approval, or proof input is unavailable
- **WHEN** device details renders
- **THEN** the UI does not launch a partial terminal
- **AND** an authorized operator may inspect only the sanitized server-derived reason

#### Scenario: Browser attempts to retarget a ready action
- **GIVEN** device details exposes a ready server-derived terminal action
- **WHEN** the browser submits another provider reference, parent, endpoint, node, VMID, route, credential rule, trust mode, or terminal mode
- **THEN** session creation rejects the request
- **AND** the UI cannot use client fields to broaden readiness

#### Scenario: QEMU graphical action is requested through terminal UI
- **GIVEN** a QEMU guest has no ready registered serial terminal
- **WHEN** a stale or crafted client requests the terminal component
- **THEN** the server returns typed terminal unavailability
- **AND** the UI does not render xterm for an RFB/VNC stream or substitute RDP

### Requirement: Console session limits
Proxmox terminal sessions SHALL enforce configured create, attach, provider-open,
idle, and absolute deadlines; bounded frame sizes and rates; periodic
authorization; route-loss and capability-loss closure; and orphan reaping. Every
terminal path SHALL close provider and browser transports, revoke the grant,
clear pending runtime state and owned secret buffers/references, and record one
sanitized terminal outcome.

#### Scenario: Idle session closes
- **GIVEN** a Proxmox terminal session is open
- **WHEN** no permitted terminal input or output occurs for the configured idle timeout
- **THEN** the generic broker closes the provider and browser transports and revokes the grant
- **AND** audit records close reason `idle_timeout`

#### Scenario: Agent or route disconnects
- **GIVEN** a terminal session is proxied through its selected parent PVE route
- **WHEN** the selected agent/gateway disconnects or its route generation changes
- **THEN** the generic broker closes the browser websocket and terminalizes the session
- **AND** the UI shows a sanitized disconnected state without reconnecting through another route

#### Scenario: Provider open fails after credential redemption
- **GIVEN** the selected agent has redeemed a one-session provider grant
- **WHEN** TLS validation, termproxy setup, websocket open, or transport validation fails
- **THEN** the agent closes provider resources and clears owned token, ticket, cookie, CSRF, proxy-ticket, and password buffers/references
- **AND** the broker revokes the grant and records one redacted terminal outcome

#### Scenario: Orphaned session is reaped
- **GIVEN** a requested, attaching, opening, or active session exceeds its state deadline without an owner
- **WHEN** the generic reaper runs
- **THEN** it terminalizes the session, revokes any grant, requests selected-agent cleanup, and closes remaining browser state
- **AND** no legacy provider-specific requested row remains indefinitely

#### Scenario: Duplicate or late frame arrives
- **GIVEN** a session has terminalized or advanced beyond a frame's sequence or deadline
- **WHEN** a duplicate, replayed, stale-generation, or late provider frame arrives
- **THEN** the broker rejects it before state mutation, terminal output, recording, or success audit

## ADDED Requirements

### Requirement: Proxmox terminals use hardened generic session guarantees
Every new Proxmox terminal SHALL be represented by the generic remote-access
session and owned by its generic broker lifecycle. The session SHALL freeze the
actor, canonical display target, parent PVE, provider instance, scoped resource,
endpoint and trust policy, selected route and generation, credential policy,
terminal mode, target digest, and policy revisions. Provider-specific
compatibility code MUST NOT create a second session or broker path for new opens.

#### Scenario: New terminal is opened through a compatibility API
- **GIVEN** a client calls an approved legacy-shaped Proxmox terminal endpoint after cutover
- **WHEN** the request passes readiness and authorization
- **THEN** the endpoint creates and returns a generic remote-access session and attach ticket
- **AND** no new provider-specific session/broker state is created

#### Scenario: Return frame comes from the wrong route
- **GIVEN** a terminal session is bound to one authenticated agent/gateway route and generation
- **WHEN** another route returns a ready, data, error, or close frame
- **THEN** the frame is rejected before it can mutate, stream, record, or successfully audit the session

#### Scenario: Return frame fails integrity or replay validation
- **GIVEN** a frame has an invalid authenticator, session binding, target digest, sequence, generation, or deadline
- **WHEN** the generic broker validates it
- **THEN** the frame is rejected and cannot trigger provider or browser state
- **AND** the event is logged without route secrets or provider credentials

#### Scenario: Legacy sessions are drained
- **GIVEN** provider-specific sessions exist before cutover
- **WHEN** the bounded compatibility drain expires
- **THEN** a reaper terminalizes remaining nonterminal rows with typed close reasons
- **AND** compatibility code remains unable to open a new legacy session

### Requirement: Proxmox terminal actions require authoritative readiness
Device details SHALL expose a Proxmox terminal action only when secure-off
deployment and provider policy are enabled and current server-side evidence
proves one scoped identity, one authoritative parent PVE when applicable, a
supported PTY mode, registered endpoint and TLS trust, one connected
parent-eligible route, effective `remote_access.proxmox.terminal_v1` capability,
one exact-purpose console rule with required privilege, actor permission,
approval and hold state, adapter/renderer availability, and fresh provider/route
proof. The system SHALL re-evaluate mutable readiness at create and attach.

#### Scenario: Applied PVE terminal capability is ready
- **GIVEN** the selected agent's applied configuration enables Proxmox terminals
- **AND** its local adapter, TLS client, frame protocol, bounded runtime, cleanup, and self-tests are compatible and healthy
- **WHEN** the agent publishes effective capabilities
- **THEN** it advertises `remote_access.proxmox.terminal_v1` for the eligible route

#### Scenario: Terminal code exists but runtime policy is disabled
- **GIVEN** an agent binary includes the Proxmox terminal adapter
- **WHEN** applied terminal policy is disabled or a required self-test fails
- **THEN** the agent omits or withdraws the effective capability
- **AND** it rejects new provider terminal opens with a sanitized reason

#### Scenario: Ready LXC action is shown
- **GIVEN** an LXC guest satisfies every current readiness input
- **WHEN** an authorized operator opens device details
- **THEN** the UI exposes one server-derived LXC terminal action bound to those inputs
- **AND** create re-evaluates them before issuing a ticket

#### Scenario: QEMU serial evidence is stale
- **GIVEN** a QEMU guest previously had a registered serial console
- **WHEN** current provider evidence no longer proves that configuration
- **THEN** terminal readiness becomes unavailable
- **AND** a previously rendered action cannot open termproxy from stale client state

#### Scenario: Parent route is unavailable
- **GIVEN** the guest device is visible and may have its own connected agent
- **WHEN** no connected capable route is eligible for the authoritative parent PVE
- **THEN** native terminal readiness reports `route_unavailable`
- **AND** the resolver does not route to the guest IP or guest-assigned agent

### Requirement: Proxmox provider credentials are session scoped and cleaned
The system SHALL resolve Proxmox console credentials only from an exact-purpose
`console_access` grant after atomic attach and SHALL keep decrypted API tokens,
passwords, PVE tickets, proxy tickets, cookies, and CSRF values only inside the
bounded selected-agent session runtime. It SHALL discard provider material and
revoke the grant on every normal, denied, failed, expired, disconnected,
restarted, revoked, or reaped terminal outcome.

#### Scenario: Inventory credential exists without console credential
- **GIVEN** inventory enrichment has a valid provider token
- **AND** no matching `console_access` rule is ready
- **WHEN** an operator views or requests a terminal action
- **THEN** the action remains unavailable with `credential_unavailable`
- **AND** the system never copies, promotes, or redeems the inventory token for the session

#### Scenario: Session grant is resolved after attach
- **GIVEN** an authorized ready terminal consumes its one-use browser attach ticket
- **WHEN** the broker starts the selected agent adapter
- **THEN** it may issue one grant bound to the frozen actor, session, provider resource, endpoint, route, operation, policy, and expiry
- **AND** the browser, gateway metadata, durable assignments, and generic commands receive no decrypted provider material

#### Scenario: Browser supplies a credential rule
- **GIVEN** credential selection belongs to server readiness and policy
- **WHEN** a browser submits a credential rule ID or secret material
- **THEN** creation or attach rejects the request before provider resolution
- **AND** it does not use the supplied value as fallback

#### Scenario: Session closes normally
- **GIVEN** a terminal session has redeemed provider credentials
- **WHEN** the operator closes the session
- **THEN** the selected agent closes the provider websocket and clears owned mutable secret buffers and references
- **AND** the broker revokes the grant, removes pending state, and records one sanitized close outcome

#### Scenario: Route loss occurs during provider setup
- **GIVEN** the selected agent has provider material but the owning route is lost before ready
- **WHEN** route-loss cleanup runs
- **THEN** the agent and generic reaper clear pending provider state and revoke the grant
- **AND** no other route can resume or redeem the session material
