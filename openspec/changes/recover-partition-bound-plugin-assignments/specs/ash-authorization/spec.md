## ADDED Requirements

### Requirement: User-scoped plugin assignment recovery authorization
The system SHALL authorize every user-initiated plugin assignment recovery under
the initiating user or API-token actor and tenant scope. It SHALL require
assignment authority for manual recovery and the authority for the owning policy
or credential rule for policy recovery. A named server-only fulfillment actor
MAY perform the final policy-owned grant or persistence work only after fresh
in-transaction reauthorization of that persisted initiating principal. That
fulfillment SHALL be non-delegable and constrained to the immutable request's
current authoritative owner, legacy agent UID, and exact mTLS-derived
partition; it SHALL receive no bearer token, permission snapshot,
caller-controlled params, or caller-supplied partition. The fulfillment actor
SHALL NOT itself be authorization evidence.

#### Scenario: Authorized manual recovery
- **GIVEN** an operator has permission to create plugin assignments within the selected tenant
- **AND** the operator confirms reapproval of a manual unbound legacy assignment in that tenant
- **WHEN** the recovery is evaluated
- **THEN** authorization is evaluated as that operator
- **AND** the system may create only the partition-bound replacement permitted by the current authenticated agent evidence

#### Scenario: Unauthorized policy recovery is denied
- **GIVEN** an operator can view a policy-owned unbound legacy assignment but lacks authority to reconcile its source policy or credential rule
- **WHEN** the operator requests policy recovery
- **THEN** the system denies the request before materializing any assignment
- **AND** records the actor, resource, action, and denial reason without secret material

#### Scenario: Constrained server fulfillment cannot elevate the requester
- **GIVEN** a policy-recovery request contains only immutable identifiers from
  an authorized initiating principal and legacy row
- **AND** the server-only materializer requires broker-grant persistence that a
  user actor cannot perform directly
- **WHEN** the restricted worker claims the request
- **THEN** it reauthorizes the persisted initiating principal inside the guarded
  transaction before fulfillment
- **AND** it materializes only the current owner, legacy agent UID, and fresh
  mTLS partition bound to that request
- **AND** revoked permissions, a changed owner, an expired lease, or changed
  identity prevent fulfillment
- **AND** no bearer token, permission snapshot, caller-controlled params, or
  caller-supplied partition is passed to the fulfillment actor

#### Scenario: Stale worker cannot change a recovery request
- **GIVEN** a policy-recovery request is leased to the named recovery executor
- **AND** that lease has expired or a different executor token owns it
- **WHEN** a worker attempts to claim or terminalize the request
- **THEN** an exact-executor conditional database update affects no row
- **AND** the worker does not materialize an assignment or dispatch configuration
- **AND** the durable request outcome remains available for a valid retry

#### Scenario: Cross-tenant recovery is denied
- **GIVEN** an actor from tenant A supplies the identifier of an unbound legacy assignment in tenant B
- **WHEN** the actor requests preview or recovery
- **THEN** the system denies the request
- **AND** it does not disclose configuration, secret references, authenticated partition details, or recovery history from tenant B

### Requirement: Redacted policy-recovery status is bound to an authorized legacy row
The system SHALL expose policy-recovery status to a user-facing recovery read
model only after it has authorized that actor to read the exact legacy assignment
in the actor's tenant. The projection SHALL contain only a safe state and a
replacement count. Durable recovery requests SHALL NOT be generally readable by
plugin managers, and user-facing code SHALL NOT enumerate request rows or
receive request payloads, principal identities, owner identifiers, replacement
identifiers, credential data, or audit details.

#### Scenario: Authorized detail receives only a safe status projection
- **GIVEN** an operator is authorized to view a policy-owned unbound legacy assignment in the current tenant
- **AND** its newest durable recovery request is queued, running, or terminal
- **WHEN** the recovery detail is read
- **THEN** the result contains only the normalized recovery state and replacement count
- **AND** it contains no request parameters, request identifiers, persisted initiating-principal data, owner identifiers, replacement identifiers, or credential material

#### Scenario: Recovery request lookup cannot disclose another tenant's state
- **GIVEN** an actor is not authorized to read a legacy assignment in another tenant
- **WHEN** the actor attempts to discover whether that row has a recovery request
- **THEN** the system denies the legacy-row read before status projection
- **AND** it does not disclose the existence, status, or contents of any recovery request

#### Scenario: Credential-rule reconciliation requires both current permissions
- **GIVEN** an initiating principal requests recovery for a credential-rule-owned legacy assignment
- **WHEN** the control plane authorizes the current authoritative owner before creating or fulfilling the request
- **THEN** it requires both plugin-assignment and credential-management permission
- **AND** it denies the request when either permission is absent or revoked
