## ADDED Requirements

### Requirement: Tenant-scoped manual adoption authorization
The system SHALL authorize manual legacy recovery as one immutable adoption plan
under the initiating user or API-token actor and tenant scope. Plan preview and
confirmation SHALL require assignment-management authority in that tenant. Each
item SHALL be reauthorized inside its guarded fulfillment transaction and SHALL
be constrained to the confirmed plan membership, current item fingerprint,
legacy agent UID, and fresh mTLS-derived partition. The fulfillment actor SHALL
receive no bearer token, permission snapshot, caller-controlled item list,
caller-controlled configuration, or caller-supplied partition and SHALL NOT
itself be authorization evidence.

#### Scenario: Authorized operator confirms one tenant plan
- **GIVEN** an operator has permission to create plugin assignments in the selected tenant
- **AND** the server produced an immutable unexpired plan for compatible manual legacy items in that tenant
- **WHEN** the operator confirms the plan once
- **THEN** the system persists that initiating principal and exact plan membership
- **AND** it may fulfill only those items that pass fresh per-item authorization and identity checks
- **AND** no per-item browser confirmation is required

#### Scenario: Constrained manual fulfillment cannot elevate the requester
- **GIVEN** an approved plan item is leased to the named recovery executor
- **WHEN** the executor reauthorizes the persisted initiating principal inside the guarded transaction
- **THEN** revoked permissions, changed fingerprints, expired plans, stale leases, conflicts, or changed identity prevent fulfillment
- **AND** the executor may create only the one current partition-bound assignment described by the plan item
- **AND** no bearer token, permission snapshot, caller parameters, secret value, or caller-supplied partition is passed to the fulfillment actor

#### Scenario: Cross-tenant plan access is denied
- **GIVEN** an actor from tenant A supplies a plan or item identifier from tenant B
- **WHEN** the actor requests preview, confirmation, or status
- **THEN** the system denies the action before resolving plan membership
- **AND** it does not disclose item counts, plugins, agents, configuration, secret references, authenticated partition details, or recovery history from tenant B

### Requirement: Automatic policy recovery uses current controller authority
The system SHALL authorize automatic policy-owned recovery only through the
narrow internal controller action for an enabled current authoritative policy or
credential rule. The current owner, not the historical row or generic system
actor, SHALL define the permitted plugin, targets, configuration, and credential
references. Browser events SHALL NOT create or parameterize automatic policy
recovery requests. User-initiated changes to the owner SHALL continue to require
the normal plugin-assignment and, for credential rules, credential-management
permissions.

#### Scenario: Enabled current owner authorizes controller reconciliation
- **GIVEN** an enabled policy or credential rule currently expresses desired plugin state for an agent
- **WHEN** the automatic recovery controller evaluates that logical item
- **THEN** the restricted controller may materialize only the state produced by that current owner
- **AND** it rechecks current package, schema, credential policy, target eligibility, and mTLS evidence before persistence
- **AND** no operator identity is manufactured or treated as authority

#### Scenario: Historical row cannot authorize controller recovery
- **GIVEN** a historical row references an owner that is missing, disabled, unsupported, or no longer targets the agent
- **WHEN** the automatic controller evaluates it
- **THEN** no assignment or credential grant is created from the historical data
- **AND** the system records a normalized absent-owner or unsupported-owner outcome without secret material

#### Scenario: Browser cannot forge automatic policy recovery
- **GIVEN** an operator knows a legacy row, owner, or recovery identifier
- **WHEN** the browser submits an event purporting to start or alter controller recovery
- **THEN** the system rejects the event without creating a request or assignment
- **AND** ordinary user edits to a credential rule still require both plugin-assignment and credential-management permission

### Requirement: Recovery projections are aggregate and tenant-authorized
The system SHALL expose recovery progress and exceptions only after authorizing
the reader for the current tenant. The projection SHALL contain allowlisted
aggregate counts, recognizable plugin labels, normalized reason codes, and
bounded affected-agent detail when explicitly requested. Durable plan, item,
request, and audit records SHALL NOT be generally readable by plugin managers,
and user-facing code SHALL NOT receive principal identities, secret references,
replacement identifiers, credential data, or raw audit payloads.

#### Scenario: Authorized overview receives safe aggregate state
- **GIVEN** an operator is authorized to view plugin recovery in the current tenant
- **WHEN** the recovery overview is read
- **THEN** it may return restored, waiting, eligible-manual, and exception counts grouped by plugin and normalized reason
- **AND** it contains no request parameters, raw plan membership, persisted initiating-principal data, owner identifiers, replacement identifiers, secret references, or credential material

#### Scenario: Cross-tenant state cannot be inferred from counts
- **GIVEN** an actor is not authorized to read recovery state in another tenant
- **WHEN** the actor attempts to discover its overview, plan, item, request, audit, or exception state
- **THEN** the system denies before projection
- **AND** it does not disclose the existence or count of any recovery data in that tenant

### Requirement: Raw recovery records are internally fenced
The system SHALL restrict raw recovery plan, item, request, and audit reads to
named internal actors. A user-facing recovery read model MUST first authorize the
requesting actor for the tenant and MUST project only allowlisted aggregate or
exception state. A generic plugin-management principal SHALL NOT enumerate raw
recovery records even when it knows an identifier.

#### Scenario: Plugin manager cannot enumerate raw recovery records
- **GIVEN** an operator has plugin-assignment management permission
- **AND** the operator knows a legacy assignment, plan, item, request, or audit identifier
- **WHEN** the operator attempts a raw lookup or enumeration
- **THEN** the system denies the raw read
- **AND** it does not return initiating actors, plan membership, replacements, authenticated principals, partitions, credential references, or audit payloads

#### Scenario: Stale worker cannot change a recovery item
- **GIVEN** a recovery item is leased to a named executor
- **AND** the lease expired or a different executor token owns it
- **WHEN** a worker attempts to claim or terminalize the item
- **THEN** an exact-executor conditional database update affects no row
- **AND** the worker does not materialize an assignment or dispatch configuration
- **AND** the durable item outcome remains available for a valid retry
