## ADDED Requirements

### Requirement: Proxmox console credentials have an exact interactive purpose
An interactive Proxmox terminal SHALL require exactly one enabled credential
rule with purpose `console_access`. The rule SHALL be selected server-side and
SHALL bind provider instance, PVE resource, registered endpoint, eligible edge
scope, terminal operation, required provider privilege, and bounded lifetime.
Rules with purpose `inventory_enrichment`, `generic`, or another non-console
purpose MUST NOT qualify or be attempted as fallback.

#### Scenario: Inventory token is the only matching credential
- **GIVEN** a Proxmox provider instance has a working `inventory_enrichment` rule
- **AND** no enabled `console_access` rule covers the selected PVE resource and route
- **WHEN** terminal readiness is evaluated
- **THEN** inventory enrichment may continue
- **AND** interactive terminal readiness reports `credential_unavailable` without trying the inventory token

#### Scenario: Generic credential could authenticate
- **GIVEN** a generic API or SSH credential can technically authenticate to the selected PVE endpoint
- **WHEN** no exact-purpose console rule is ready
- **THEN** the terminal remains unavailable
- **AND** the resolver does not downgrade to the generic credential

#### Scenario: One least-privilege console rule matches
- **GIVEN** one enabled `console_access` rule covers the frozen provider instance, parent PVE, endpoint, selected route, terminal operation, and required PVE console privilege
- **WHEN** an authorized terminal session is created
- **THEN** the server selects that rule without exposing secret material
- **AND** no rule outside any frozen scope participates

#### Scenario: Equal-priority console rules conflict
- **GIVEN** multiple enabled console rules at the winning priority match the same provider resource and route
- **WHEN** readiness or session creation resolves the credential
- **THEN** the operation fails closed with `credential_conflict`
- **AND** it does not try each secret or choose by row order

#### Scenario: Console rule belongs to another provider instance
- **GIVEN** a Farm terminal target and a console rule scoped to Tonka
- **WHEN** credential resolution runs
- **THEN** the rule cannot match even if node names, VMIDs, endpoint labels, or secrets are equal
- **AND** no grant is issued

#### Scenario: Browser submits a credential or target override
- **GIVEN** a ready terminal action has server-selected identity, route, trust, mode, and credential policy
- **WHEN** the browser submits a credential rule ID, provider reference, endpoint, node, VMID, agent, gateway, trust mode, or terminal mode
- **THEN** session creation rejects the override before ticket or grant issuance

### Requirement: Proxmox console grants are attached-session and route bound
After atomic browser attach, the system SHALL issue at most one short-lived
console grant bound to actor, session, canonical display target, parent PVE,
provider instance, endpoint, selected agent and gateway, typed terminal
transport, allowed API methods/paths, policy revisions, and expiry. Only the
selected agent SHALL redeem the grant, and durable assignments or command rows
MUST NOT contain decrypted provider credentials.

#### Scenario: Attached session obtains a bounded grant
- **GIVEN** an authorized ready terminal session atomically consumes its one-use attach ticket
- **WHEN** the generic broker opens the selected provider adapter
- **THEN** core issues a grant for only the frozen PVE resource, route, terminal operations, and session lifetime
- **AND** the selected agent may redeem it once within the open deadline

#### Scenario: Grant requested before browser attach
- **GIVEN** a terminal session exists but its attach ticket has not been consumed
- **WHEN** provider credential resolution is requested
- **THEN** no decrypted credential or redeemable grant is issued

#### Scenario: Another route redeems the grant
- **GIVEN** a grant is bound to one authenticated agent and gateway route
- **WHEN** another route presents or replays the grant
- **THEN** redemption is rejected
- **AND** it cannot open a PVE connection or mutate the owning session

#### Scenario: Adapter requests an unapproved PVE operation
- **GIVEN** a session grant allows the selected resource's terminal setup and websocket operations
- **WHEN** the adapter requests another node, VMID, endpoint, method, path, redirect target, or API operation
- **THEN** the broker denies the request before injecting credentials
- **AND** the denial exposes no token, ticket, cookie, or internal response body

#### Scenario: Session reaches a terminal outcome
- **GIVEN** a provider grant has been redeemed for a terminal session
- **WHEN** open fails, the session closes, authorization is revoked, the route is lost, the grant expires, or a reaper terminalizes the session
- **THEN** the grant is revoked and provider credential references are cleared from bounded runtime state
- **AND** it cannot be reused for another session or resource

### Requirement: Proxmox console credential rules require least privilege
The system SHALL validate that a Proxmox `console_access` rule is limited to the
provider operations required for its approved terminal resource. Node-terminal
rules SHALL require the applicable node console permission such as
`Sys.Console`; guest-terminal rules SHALL require the applicable guest console
permission such as `VM.Console`. Inventory-only access MUST remain separately
grantable and revocable.

#### Scenario: Guest rule lacks console privilege
- **GIVEN** a rule authenticates to PVE but lacks the selected guest's console privilege
- **WHEN** its readiness proof runs
- **THEN** the rule remains unavailable for interactive use
- **AND** the result reports a sanitized privilege reason without returning the provider response body

#### Scenario: Console credential is rotated
- **GIVEN** an enabled console rule is rotated while an old grant exists
- **WHEN** readiness and subsequent sessions are evaluated
- **THEN** new grants bind the current credential revision
- **AND** an old revision cannot be used to broaden or silently resume a terminal

#### Scenario: Inventory credential is revoked independently
- **GIVEN** separate inventory and console rules cover the same provider instance
- **WHEN** the inventory rule is disabled
- **THEN** the console rule's readiness is evaluated independently under its own scope and privilege
- **AND** no purpose is automatically copied or promoted
