## ADDED Requirements

### Requirement: Proxmox console opening requires separate credential-use authorization
Before resolving any brokered credential or creating a privileged provider effect, the system SHALL verify the authenticated current user has `devices.console.open` and `devices.console.credentials.use` for the canonical device and is allowed by the selected rule's explicit `console_access` actor-use policy.

#### Scenario: User has both permissions and rule allow
- **GIVEN** the current user has `devices.console.open` and `devices.console.credentials.use`
- **AND** an enabled `console_access` rule allows that actor and exact device/provider target
- **WHEN** the user requests a console from device details
- **THEN** the system MAY create an actor-bound session authorization decision
- **AND** the decision SHALL be included in the exact broker grant binding

#### Scenario: User lacks credential-use permission
- **GIVEN** a user can view the device and has `devices.console.open`
- **AND** the user lacks `devices.console.credentials.use`
- **WHEN** the user requests a brokered Proxmox console
- **THEN** the request SHALL be denied before rule-secret resolution, provider ticket creation, SSH dial, or WebSocket dial
- **AND** no higher-privileged service or system credential SHALL substitute for the denied user

#### Scenario: Rule policy denies current user
- **GIVEN** a user has both RBAC permissions
- **AND** the matching credential rule does not allow that actor or does not declare `console_access`
- **WHEN** the user requests a console
- **THEN** the request SHALL be denied before credential resolution
- **AND** a system actor used for internal lookup SHALL NOT widen the decision

### Requirement: Browser input cannot select privileged Proxmox console fields
The console API SHALL accept a canonical device identifier and non-privileged presentation inputs only. The server SHALL derive target kind, console mode, credential rule, provider identity, integration/controller, cluster, node, VMID/type, agent/gateway route, controller origin, port, TLS policy, and connector operation from authorized inventory and policy.

#### Scenario: Browser submits only device and terminal dimensions
- **GIVEN** an authorized user selects a Proxmox guest in device details
- **WHEN** the browser requests a console with the device UID and optional terminal dimensions
- **THEN** the server SHALL derive every privileged routing and credential field
- **AND** the resulting session SHALL be bound to the derived values

#### Scenario: Browser attempts privileged substitution
- **GIVEN** a console request includes a credential-rule ID, target kind, mode, provider reference, controller/base URL, node, VMID, host, port, TLS option, agent, gateway, route, or credential metadata
- **WHEN** the API validates the request
- **THEN** it SHALL reject or ignore each field as non-authoritative according to a documented API contract
- **AND** no supplied field SHALL affect rule selection, secret resolution, or network target

### Requirement: Guest consoles use the exact authoritative PVE owner
For a QEMU or LXC guest, the system SHALL resolve one v3 guest and follow its unambiguous current-owner relationship to the exact integration, controller, native cluster, and PVE node. Native console API and WebSocket requests SHALL use that controller's host-owned canonical base origin and SHALL never derive a PVE endpoint from the guest IP.

#### Scenario: QEMU guest opens native console
- **GIVEN** a QEMU device maps to one v3 guest with one current PVE owner
- **AND** the owner, rule, assignment, and agent route pass authorization
- **WHEN** the user opens the native console
- **THEN** the trusted connector SHALL request a one-session QEMU console ticket from the exact owning controller/node
- **AND** it SHALL attach to the exact host-constructed WebSocket path for that node, guest kind, and VMID
- **AND** the browser SHALL not need direct PVE network access

#### Scenario: LXC guest opens native console
- **GIVEN** an LXC device maps to one v3 guest with one current PVE owner
- **WHEN** an authorized user opens its native console
- **THEN** the trusted connector SHALL use the exact owning controller/node and LXC operation path
- **AND** it SHALL not use a QEMU path, another PVE node, or a guest-IP-derived endpoint

#### Scenario: Guest IP exposes port 8006
- **GIVEN** a guest device has an IP address and port 8006 is reachable or appears in metadata
- **WHEN** native Proxmox console routing is resolved
- **THEN** the guest IP SHALL be ignored as a controller target
- **AND** only the host-owned origin for the guest's exact integration/controller owner SHALL be eligible

#### Scenario: Owner is ambiguous stale or changes
- **GIVEN** the guest owner is absent, duplicated, references a legacy ambiguous alias, differs from the session binding, or changes before attach
- **WHEN** the console is created, resolved, or attached
- **THEN** the operation SHALL fail closed before credential resolution or further dial
- **AND** the system SHALL NOT choose another cluster node or silently retarget the session

### Requirement: Every Proxmox console effect validates an exact session binding
The system SHALL bind and revalidate the actor, authorization decision, assignment/version/fingerprint, session, device, v3 provider/object identity, integration, controller, cluster, node, VMID/type, credential rule, purpose, agent, selected control-stream gateway, console mode, canonical origin, target-policy digest, expiry, and use count at every privileged console boundary.

#### Scenario: Exact session attaches once
- **GIVEN** a short-lived browser ticket and broker grant match every persisted session binding
- **WHEN** the browser attaches and the agent opens the provider connection
- **THEN** the browser ticket, broker grant, and provider ticket SHALL each be limited to the declared session and use count
- **AND** successful use SHALL prevent replay

#### Scenario: Session binding differs at attach
- **GIVEN** any persisted or presented actor, assignment, session, device, provider, owner, rule, route, mode, origin, expiry, or use-count binding differs
- **WHEN** attach, resolution, provider ticket creation, WebSocket dial, or SSH dial is attempted
- **THEN** the operation SHALL be denied before the next credential or network effect
- **AND** no default, legacy alias, current cluster leader, or alternate route SHALL be tried

#### Scenario: Authorization is revoked before attach
- **GIVEN** a session ticket was created while the user and rule were allowed
- **AND** RBAC, rule-use policy, assignment, or owner authorization is revoked or changed before credential resolution or attach
- **WHEN** the privileged boundary revalidates the session
- **THEN** it SHALL deny and close the session
- **AND** it SHALL not resolve a credential under the earlier decision

#### Scenario: Console open reaches the selected agent assignment
- **GIVEN** session creation selected one active Proxmox console assignment and recorded its positive policy version and deterministic assignment-policy fingerprint
- **WHEN** the broker emits the agent open frame
- **THEN** the version and fingerprint SHALL travel in typed control-stream fields outside browser- or Wasm-authored JSON
- **AND** the agent SHALL compare both values with the active assignment before plugin startup, credential resolution, slot acquisition, or network dial

#### Scenario: Assignment policy binding is stale or missing
- **GIVEN** the open frame omits or changes the assignment policy version or fingerprint, or the active assignment no longer has the same binding
- **WHEN** the broker or agent validates the open
- **THEN** it SHALL fail closed before plugin startup, credential resolution, or dial
- **AND** JSON fields supplied by the browser or Wasm SHALL NOT satisfy or override the typed binding

#### Scenario: Agent frame arrives through another route
- **GIVEN** the broker selected one authenticated agent control stream and gateway node for the session
- **WHEN** a ready, data, close, error, or other console frame has a missing or different session ID, agent ID, or gateway-node tag
- **THEN** the broker SHALL reject the frame without forwarding bytes or closing the browser session
- **AND** it SHALL NOT repin the live session to the alternate route

### Requirement: Native provider and SSH console credentials remain host owned
Proxmox tickets, cookies, CSRF values, API tokens, SSH keys, passphrases, passwords, and ServiceRadar bearer tokens SHALL remain in trusted host memory and SHALL NOT be returned to Wasm, the browser, gateway metadata, console metadata, URLs, logs, audit events, metrics, errors, or persisted session fields.

#### Scenario: Native provider ticket is used
- **GIVEN** the trusted connector obtains a ticket for one exact guest session
- **WHEN** it opens the provider WebSocket
- **THEN** trusted host code SHALL apply the ticket only to the exact authorized path and target
- **AND** the browser and Wasm SHALL receive only console stream data and non-secret lifecycle state

#### Scenario: PVE SSH shell is used
- **GIVEN** policy selects SSH for an exact PVE host rather than a guest native console
- **WHEN** the trusted connector opens SSH
- **THEN** it SHALL use only session-scoped credential material and the exact verified host-key policy
- **AND** reusable agent-local keys, plugin-supplied passwords/keys, guest-IP fallback, and skip verification SHALL not be accepted

#### Scenario: Server selects SSH host-key policy
- **GIVEN** an SSH-backed PVE console rule selects either `known_hosts` or `trust_on_first_use`
- **WHEN** the assignment is rendered and the trusted connector opens SSH
- **THEN** the exact closed-enum value SHALL travel only in the host authority binding and SHALL configure the trusted connector
- **AND** browser input, Wasm parameters, target metadata, or inline SSH configuration SHALL NOT override it

#### Scenario: SSH host-key policy is unsafe or unknown
- **GIVEN** an SSH-backed PVE console binding has no host-key policy or specifies `skip_verify`, an unknown value, or a value with different casing
- **WHEN** the control plane or agent validates the binding
- **THEN** it SHALL reject the assignment before credential resolution or SSH dial
- **AND** it SHALL NOT fall back to `known_hosts`, TOFU, or an insecure verifier

### Requirement: Proxmox console audits are complete and redacted
The system SHALL audit console authorization, rule selection, exact owner resolution, grant issue/use/reject, connector policy validation, provider ticket use, attach, close, expiry, and denial using stable identifiers and safe result codes. It SHALL NOT record secrets or terminal content by default.

#### Scenario: Console lifecycle succeeds
- **GIVEN** an authorized console opens and closes
- **WHEN** lifecycle audits are inspected
- **THEN** they SHALL identify actor, authorization decision, session, device, v3 provider/guest, integration/controller, owner node, credential rule, agent/gateway, mode, canonical target identity, timestamps, and close reason
- **AND** they SHALL exclude credential values, redeemable references, protected headers, tickets, cookies, CSRF, request bodies, and terminal I/O

#### Scenario: Binding or connector policy is denied
- **GIVEN** a malicious or stale request fails authorization, owner, target, TLS, redirect, path/body, replay, or version validation
- **WHEN** the denial is audited and shown to an operator
- **THEN** it SHALL contain a bounded phase, safe reason code, and correlation ID
- **AND** it SHALL not echo attacker-supplied protected fields or provider secrets

### Requirement: Farm01 and tonka01 prove isolated console routing before demo enablement
The demo namespace SHALL keep Proxmox console access disabled for incompatible or unmigrated targets until automated and live evidence proves collision-safe inventory, host-only credential custody, exact-owner routing, authorization, and redaction for both farm01 and tonka01.

#### Scenario: Both clusters use overlapping identifiers
- **GIVEN** farm01 and tonka01 have distinct integration/controller IDs but matching native cluster/node names and VMIDs
- **WHEN** both inventories sync in demo
- **THEN** their v3 provider instances, hosts, guests, device links, and owner relationships SHALL remain distinct
- **AND** repeated sync SHALL produce no overwrite or cross-cluster alias

#### Scenario: Guest console proof runs in each environment
- **GIVEN** one eligible guest from farm01 and one from tonka01
- **WHEN** an authorized user opens each console from device details
- **THEN** captured trusted-host evidence SHALL show each session reached its exact owning PVE/controller and node
- **AND** neither session SHALL target the guest IP on port 8006 or the other integration
- **AND** captured Wasm-visible and audit surfaces SHALL contain no credential sentinel

#### Scenario: Negative demo proof fails a binding
- **GIVEN** a test substitutes actor permission, rule policy, session, device, integration/controller, owner node, origin, agent, TLS policy, redirect, or version
- **WHEN** the console is attempted
- **THEN** the request SHALL fail before secret resolution or dial
- **AND** demo enablement SHALL remain blocked if any negative case reaches a resolver or network target
