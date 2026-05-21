## ADDED Requirements

### Requirement: Credential sources support external references
Reusable credentials SHALL support both internally encrypted secret material and external secret references without requiring consumers to use different credential APIs.

#### Scenario: Existing internal credential remains valid
- **GIVEN** an existing network credential secret stores encrypted payload material internally
- **WHEN** the external secret provider broker model is enabled
- **THEN** the credential SHALL be treated as source type `internal_encrypted`
- **AND** existing credential rules SHALL continue to resolve through the broker interface

#### Scenario: External reference credential is saved
- **GIVEN** an authorized admin creates a credential that references an external secret provider object
- **WHEN** the credential is saved
- **THEN** ServiceRadar SHALL persist provider ID, object/path reference, field mapping, version policy, credential kind, and redaction metadata
- **AND** it SHALL NOT persist the resolved external secret value

### Requirement: External secret provider records
The system SHALL model external secret providers separately from credential references, including provider type, endpoint metadata, auth mode, resolution locations, health status, and policy.

#### Scenario: Configure provider without adapter support
- **GIVEN** an admin configures a provider type whose adapter is not enabled
- **WHEN** they save the provider record
- **THEN** the system MAY persist the disabled provider metadata
- **AND** it SHALL mark tests and resolutions unavailable until an adapter is enabled

#### Scenario: Provider auth is protected
- **GIVEN** a provider requires bootstrap credentials
- **WHEN** those credentials are configured
- **THEN** they SHALL be stored as protected secret material or referenced from deployment runtime secret configuration
- **AND** they SHALL NOT appear in UI responses, logs, or plugin/agent assignment params

#### Scenario: OpenBao provider resolves KV reference
- **GIVEN** an enabled OpenBao provider points at an operator-provisioned KV mount and a reusable credential references an operator-authorized secret path and field mapping
- **WHEN** the broker resolves the credential from the control plane
- **THEN** it SHALL call OpenBao using deployment-sourced bootstrap credentials or a preconfigured Kubernetes auth role for the ServiceRadar service account token
- **AND** it SHALL return only the selected secret field or a structured JSON payload to the broker consumer
- **AND** it SHALL persist redacted resolution audit metadata without the OpenBao token or resolved secret value
- **AND** ServiceRadar SHALL NOT create or modify OpenBao auth mounts, policies, roles, KV mounts, or secret objects as part of normal credential resolution

### Requirement: Broker grants govern credential resolution
Credential resolution SHALL require a broker grant scoped to consumer, purpose, target, allowed network/resource policy, resolution location, and expiration.

#### Scenario: Broker grant is a persisted lifecycle resource
- **GIVEN** a trusted ServiceRadar component needs to authorize credential resolution for a runtime consumer
- **WHEN** it issues a broker grant
- **THEN** ServiceRadar SHALL persist a first-class grant record with secret reference, consumer, purpose, target, allowed request policy, TTL, resolution location, status, issuer, and audit metadata
- **AND** grant lifecycle transitions SHALL be constrained to issued, active, consumed, denied, expired, or revoked
- **AND** the grant SHALL be versioned with AshPaperTrail

#### Scenario: Plugin receives grant reference only
- **GIVEN** a plugin-backed check needs an HTTP bearer token
- **WHEN** the assignment is compiled
- **THEN** the plugin assignment SHALL include a broker grant reference and allowed target policy
- **AND** it SHALL NOT include the bearer token or provider bootstrap credentials

#### Scenario: Grant cannot be reused for another target
- **GIVEN** a broker grant was issued for service `svc-a`
- **WHEN** an agent or worker attempts to use it for service `svc-b`
- **THEN** the broker SHALL deny the resolution or injection attempt
- **AND** an audit event SHALL record the denied target mismatch without secret values

#### Scenario: Agent resolves grant through gateway broker
- **GIVEN** an authenticated agent receives a broker grant for a plugin action
- **WHEN** the agent needs credential material for an agent-owned host operation
- **THEN** it SHALL call the agent-gateway credential resolution RPC with the grant ID, credential reference, agent ID, consumer, purpose, and resolution location
- **AND** the gateway SHALL validate the caller mTLS identity before forwarding resolution to core
- **AND** core SHALL validate the persisted grant scope and audit the resolution before returning memory-only credential material to the agent
- **AND** plaintext credential material SHALL NOT be returned to the plugin or stored in the command payload

#### Scenario: Ad-hoc device task receives scoped credential grant
- **GIVEN** an authorized operator runs an ad-hoc task against device `dev-1`
- **AND** the task needs to call an external API that requires credentials
- **WHEN** the task execution request is created
- **THEN** ServiceRadar SHALL attach a credential broker grant scoped to the task execution ID, device, API target, actor, purpose, and TTL
- **AND** the task payload SHALL NOT contain plaintext credentials

#### Scenario: Ad-hoc task source is transparent to the task runner
- **GIVEN** an ad-hoc task references a reusable credential
- **WHEN** the credential source is `external_reference`
- **THEN** the broker SHALL retrieve the value from the configured secret provider subject to provider and grant policy
- **AND** when the credential source is `internal_encrypted`, the same broker API SHALL resolve the internally stored encrypted value
- **AND** the task runner SHALL NOT need separate code paths for secret-provider versus internally stored credentials

### Requirement: Resolution location is explicit
The system SHALL resolve external secrets only from locations allowed by provider policy and grant policy.

#### Scenario: Agent-side provider resolution
- **GIVEN** a provider is configured for agent-side resolution through edge site `lab-a`
- **WHEN** an eligible agent in `lab-a` receives a broker grant
- **THEN** the agent broker MAY resolve the external secret
- **AND** the control plane SHALL NOT need to fetch the external secret value

#### Scenario: Disallowed resolution location is blocked
- **GIVEN** a provider allows only control-plane resolution
- **WHEN** an agent attempts to resolve a reference directly
- **THEN** the broker SHALL deny the request
- **AND** the denial SHALL be audited with provider, grant, target, and reason metadata

### Requirement: Broker caching and leases are bounded
The credential broker SHALL enforce cache and lease policy so resolved external secret values are not retained longer than provider lease TTL, credential cache TTL, or broker grant TTL.

#### Scenario: Memory cache expires
- **GIVEN** a credential reference allows memory caching for 60 seconds
- **WHEN** the cache TTL expires
- **THEN** the next resolution SHALL fetch from the provider again
- **AND** the old secret value SHALL be dropped from memory

#### Scenario: Lease TTL caps cache TTL
- **GIVEN** an external provider returns a leased credential valid for 30 seconds
- **AND** the credential reference cache policy requests 5 minutes
- **WHEN** the broker stores the cache entry
- **THEN** the effective cache TTL SHALL NOT exceed 30 seconds

### Requirement: Secret resolution is audited and redacted
The system SHALL audit external secret provider tests, resolutions, failures, cache hits, lease renewals, and revocations without storing or logging secret values.

#### Scenario: Provider returns not found
- **GIVEN** a credential reference points to a missing external object
- **WHEN** resolution is attempted
- **THEN** the audit log SHALL record provider, reference, consumer, target, and error class `not_found`
- **AND** the missing secret value SHALL NOT appear because no resolved value exists

#### Scenario: Resolution succeeds
- **GIVEN** an agent broker resolves an external reference successfully
- **WHEN** audit metadata is persisted
- **THEN** it SHALL include provider ID, reference ID, consumer kind, target ID, agent ID, grant ID, resolution location, cache/lease status, and timestamp
- **AND** it SHALL NOT include the resolved secret value

#### Scenario: Ad-hoc task execution emits audit and informational events
- **GIVEN** an authorized operator launches an ad-hoc device task that uses a credential broker grant
- **WHEN** the task is queued, dispatched, resolved, completed, denied, or failed
- **THEN** ServiceRadar SHALL persist redacted audit records for the task execution and credential resolution
- **AND** it SHALL emit OCSF events, informational for normal queue/dispatch/success transitions and higher severity for denial or failure
- **AND** the events SHALL include actor, device, task execution ID, credential reference ID, provider ID when present, and target metadata without secret values

### Requirement: Credential lifecycle is first class
Credential providers, credential references, broker grants, task executions, and credential rotation SHALL model lifecycle transitions explicitly instead of relying on free-form status fields.

#### Scenario: Credential provider availability transitions are constrained
- **GIVEN** a credential provider is disabled
- **WHEN** an admin enables it or a provider test succeeds
- **THEN** the provider SHALL transition through an explicit lifecycle action to `active`
- **AND** unavailable or degraded states SHALL only be reached through explicit broker/provider test outcomes

#### Scenario: Credential rotation is tracked as a lifecycle
- **GIVEN** a reusable credential has a rotation due date
- **WHEN** rotation begins, succeeds, fails, is disabled, or is re-enabled
- **THEN** the credential SHALL transition through explicit rotation lifecycle actions
- **AND** each transition SHALL be audit/version tracked and MAY emit informational or failure events as appropriate
