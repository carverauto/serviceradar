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

### Requirement: Redacted manual completion is bound to an authorized legacy row
The system SHALL expose a completed manual-reapproval indication only after it
has authorized the actor to read the exact legacy assignment in the actor's
tenant. The projection SHALL contain only an allowlisted completion state. It
SHALL NOT expose the immutable audit record, replacement identifier, actor,
timestamp, partition evidence, or audit payload.

#### Scenario: Authorized detail receives only manual completion state
- **GIVEN** a manual legacy assignment has a successful immutable recovery audit
- **WHEN** an operator authorized for that exact legacy assignment reads recovery detail
- **THEN** the result may contain only `reapproved`
- **AND** it contains no replacement identifier, actor, timestamp, partition, or audit details

#### Scenario: Unauthorized detail cannot discover manual completion
- **GIVEN** an actor is not authorized to read a legacy assignment in another tenant
- **WHEN** the actor attempts to read its recovery detail
- **THEN** the system denies before projecting manual completion
- **AND** it does not disclose whether an audit exists or whether recovery succeeded

#### Scenario: Credential-rule reconciliation requires both current permissions
- **GIVEN** an initiating principal requests recovery for a credential-rule-owned legacy assignment
- **WHEN** the control plane authorizes the current authoritative owner before creating or fulfilling the request
- **THEN** it requires both plugin-assignment and credential-management permission
- **AND** it denies the request when either permission is absent or revoked

### Requirement: Raw recovery audit lookup is internally fenced
The system SHALL restrict raw plugin-assignment recovery audit reads to the
named internal recovery-audit lookup actor. A user-facing recovery read model
MUST first authorize the initiating actor to read the exact legacy assignment
in its tenant before it performs that internal lookup, and it MUST project only
the allowlisted recovery state. A generic plugin-management principal SHALL NOT
enumerate raw audit rows, even when it knows a legacy-assignment identifier.

#### Scenario: Plugin manager cannot enumerate raw recovery audits
- **GIVEN** an operator has plugin-assignment management permission
- **AND** the operator knows the identifier of a legacy assignment
- **WHEN** the operator attempts a raw recovery-audit lookup for that identifier
- **THEN** the system denies the raw audit read
- **AND** it does not return actor, replacement, authenticated-partition, or audit-outcome fields

#### Scenario: Authorized legacy detail projects a raw audit safely
- **GIVEN** an operator is authorized to read one manual legacy assignment in the current tenant
- **AND** that assignment has a successful immutable recovery audit
- **WHEN** the recovery detail performs its internal audit lookup
- **THEN** it returns only `reapproved` to the operator
- **AND** it does not return the raw audit row or its identifiers
