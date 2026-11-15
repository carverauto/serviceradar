## MODIFIED Requirements

### Requirement: Secure credential storage for discovery
Discovery credentials (SNMP and API) MUST be stored using AshCloak encryption in CNPG and MUST be redacted in UI-facing responses.

#### Scenario: Save SNMP credentials
- **GIVEN** an admin configures SNMP discovery for a job
- **WHEN** the job is saved
- **THEN** any SNMP credential the job carries SHALL be a reference to a reusable SNMP credential in `platform.network_credential_secrets`, and the job record SHALL NOT store SNMP secret material
- **AND** saving an SNMP-mode job with no referenced SNMP credential SHALL remain valid, so an unbound job can still be edited, disabled or retargeted
- **AND** per-device SNMP credentials SHALL continue to come from device overrides, SNMP credential rules and SNMP profiles
- **AND** any stored credentials (reusable credential, profile or device override) SHALL be encrypted at rest via AshCloak
- **AND** API responses to the UI SHALL redact sensitive fields

### Requirement: Discovery job definition schema
Discovery jobs SHALL capture the minimum fields required for mapper execution, including schedule, seeds, and credentials.

#### Scenario: Job schema completeness
- **GIVEN** a mapper discovery job
- **THEN** it includes:
  - `name`
  - `enabled`
  - `interval`
  - `seeds`
  - `discovery_mode` (SNMP or API)
  - `assignment` (agent or partition)
- **AND** the job MAY hold a reference to a reusable SNMP credential (`snmp_credential_secret_id`)
- **AND** SNMP secret material SHALL NOT be stored on the job record

## ADDED Requirements

### Requirement: Explicit mapper discovery fallback credential
Each SNMP-mode mapper discovery job (`discovery_mode` `snmp` or `snmp_api`) SHALL take its fallback SNMP credential only from the reusable SNMP credential the job itself references (`snmp_credential_secret_id`).
The fallback is the credential the mapper uses for any address without a per-device credential: seeds and neighbours the inventory does not yet know. The compiler MUST NOT derive it from the SNMP profile flagged `is_default`, from an SNMP monitoring rule that is not matched to a specific device, or from the polling credential of the device hosting the agent.

#### Scenario: Job credential is the fallback
- **GIVEN** an SNMP-mode mapper job that references reusable SNMP credential C
- **AND** a seed `192.0.2.10` with no device record
- **WHEN** the mapper config is compiled for the job's agent
- **THEN** the job's base credentials SHALL be built from C
- **AND** `target_specific` SHALL NOT contain an entry for `192.0.2.10`

#### Scenario: Default profile flag does not affect discovery
- **GIVEN** an SNMP-mode mapper job that references reusable SNMP credential C
- **AND** an SNMP profile P with `is_default = true` and a different credential
- **WHEN** P's default flag is cleared, or another profile is made default
- **THEN** the job's compiled base credentials SHALL remain those of C

#### Scenario: Unmatched monitoring rule is not a fallback
- **GIVEN** an enabled SNMP monitoring rule scoped to agent `agent-01` with target query `in:devices hostname:host01.example.com`
- **AND** an SNMP-mode mapper job on `agent-01` with no referenced credential
- **WHEN** the mapper config is compiled
- **THEN** the job's base credentials SHALL NOT be built from that rule
- **AND** the rule's credential SHALL appear only under `target_specific` for addresses of devices the rule's target query matches

#### Scenario: Known devices keep per-device resolution
- **GIVEN** a known device at `192.0.2.20` whose SNMP credential resolves through a device override, a matching SNMP monitoring rule, a targeting profile or the default profile
- **WHEN** an SNMP-mode mapper job that includes it is compiled
- **THEN** `target_specific` for `192.0.2.20` SHALL carry that per-device credential regardless of the job's referenced credential

#### Scenario: Two jobs on one agent use different fallbacks
- **GIVEN** two SNMP-mode mapper jobs assigned to the same agent, referencing credentials C1 and C2
- **WHEN** the mapper config is compiled for that agent
- **THEN** each job's base credentials SHALL be built from its own referenced credential

### Requirement: Mapper discovery credential reference integrity
A mapper job's SNMP credential reference MUST be restricted at the database, included in the credential usage inventory, and navigable from the credential's usage surface.

#### Scenario: Referenced credential cannot be deleted
- **GIVEN** a reusable SNMP credential referenced by a mapper job
- **WHEN** an operator attempts to delete the credential
- **THEN** the deletion SHALL be refused as `credential_in_use`
- **AND** the credential usage inventory SHALL list the mapper job as a consumer

#### Scenario: Usage surface links to the job
- **GIVEN** a reusable SNMP credential referenced by mapper job `site01-core`
- **WHEN** an operator views that credential's usage
- **THEN** the listing SHALL name `site01-core` as a mapper discovery job
- **AND** SHALL link to that job's edit form

#### Scenario: Non-SNMP credential is rejected
- **GIVEN** a reusable credential whose `credential_kind` is not `snmp`
- **WHEN** an operator saves a mapper job referencing it as the SNMP credential
- **THEN** the save SHALL fail with a validation error on the SNMP credential field

#### Scenario: Usage inventory fails closed
- **GIVEN** the mapper job usage loader fails
- **WHEN** credential usage is requested
- **THEN** the lookup SHALL report usage as unavailable rather than return a partial consumer list

### Requirement: Missing mapper discovery credential fails closed and is visible
An SNMP-mode mapper job with no referenced SNMP credential MUST compile with an empty base credential that the mapper refuses, and MUST be shown to operators as missing its SNMP credential.
A referenced credential that deterministically cannot be built (broker refusal, unknown security level) MUST also compile to an empty base credential for that job. A failure to read the referenced credential from storage or the broker MUST fail the compile instead, so the previously cached config stays in place.
The compiler MUST NOT emit an SNMPv1/v2c credential with no community string as a substitute.

#### Scenario: No referenced credential
- **GIVEN** an SNMP-mode mapper job with no referenced SNMP credential
- **WHEN** the mapper config is compiled
- **THEN** the job's base credentials SHALL be `{}` plus its `target_specific` map
- **AND** the compiled base credentials SHALL NOT contain `"version" => "v2c"`
- **AND** the mapper SHALL NOT open an SNMP session to any address of that job that lacks a `target_specific` entry

#### Scenario: Job list shows the missing credential
- **GIVEN** an SNMP-mode mapper job with no referenced SNMP credential
- **WHEN** an operator opens Settings → Networks → Discovery
- **THEN** the job's row SHALL show a "No SNMP credential" warning
- **AND** the job's edit form SHALL show the same warning next to the SNMP credential field until one is chosen

#### Scenario: API-only job needs no SNMP credential
- **GIVEN** a mapper job with `discovery_mode` `api` and no referenced SNMP credential
- **WHEN** it is compiled and listed
- **THEN** no missing-credential warning SHALL be shown and the API discovery configuration SHALL compile unchanged

#### Scenario: Credential read failure still fails the compile
- **GIVEN** an SNMP-mode mapper job whose referenced credential cannot be read because of a storage or broker read failure
- **WHEN** the mapper config is compiled
- **THEN** the compile SHALL return an error rather than deliver a config with `{}` for that job

#### Scenario: Missing credential does not flood logs
- **GIVEN** an SNMP-mode mapper job with no referenced SNMP credential
- **WHEN** the mapper config is compiled repeatedly
- **THEN** the compiler SHALL NOT log a warning for that job on every compile

### Requirement: Reusable community credential SNMP version
A reusable SNMP community credential SHALL carry an optional SNMP version, `v1` or `v2c`, stored with the community in its secret payload; a payload without a version SHALL resolve as `v2c`, and a consumer that references the credential without a version of its own, such as a mapper discovery job, SHALL deliver the stored version.

#### Scenario: Payload without a version resolves as v2c
- **GIVEN** a mapper discovery job referencing a reusable community credential whose payload has no version
- **WHEN** the mapper config compiles
- **THEN** the job's base credentials SHALL carry version `v2c` and that community

#### Scenario: v1 credential round-trips through the job reference
- **GIVEN** a mapper discovery job referencing a reusable community credential stored with version `v1`
- **WHEN** the mapper config compiles
- **THEN** the job's base credentials SHALL carry version `v1` and that community

#### Scenario: Backfill keeps a legacy v1 community
- **GIVEN** before upgrade, an SNMP-mode job's fallback resolved to an SNMPv1 community, held inline on a profile or override, or in a reusable credential whose payload has no version
- **WHEN** the one-time backfill runs
- **THEN** the job SHALL reference a reusable credential stored with version `v1` and that community
- **AND** the job's compiled base credentials SHALL carry version `v1`

#### Scenario: Promoted credential name is taken
- **GIVEN** the backfill promotes or copies a credential whose generated name is already used by an SNMP credential
- **WHEN** it creates the credential
- **THEN** it SHALL append the first free numeric suffix (` 2`, ` 3`, ...) to the name and bind that credential

### Requirement: Mapper discovery credential migration
Upgrading MUST bind each existing SNMP-mode mapper job, enabled or disabled, to the credential its pre-upgrade fallback chain resolved to, without operators re-entering secrets.
Only a job whose legacy chain, evaluated on a non-empty agent set, resolves to no credential, or to different credentials on different agents, MAY remain unbound. A read or write failure, a missing assigned agent, or an empty or unloadable partition agent set during the backfill MUST NOT be treated as an empty result.
The agent set MUST come from persisted agent records: the assigned agent for an agent-assigned job, or every agent that is not superseded and whose `partition_id` (default `default`) equals the job's partition for a partition-assigned job. Each agent in the set MUST be evaluated with its own id as the agent rule scope, the job's partition as the partition scope, and its own device for host resolution.
Each job that existed before the upgrade MUST carry a backfill mark. The backfill MUST visit only marked jobs, and MUST clear a job's mark in the same update that records its decision: bound, deliberately unbound, or not needed because the job is API-only or already references a credential. That update MUST apply only if the mark is still set and the job's SNMP credential reference still equals the value the backfill read; an update that applies to no row MUST NOT record a decision, and the job MUST stay marked for a retry. Jobs created after the upgrade MUST NOT be marked.
Each committed decision MUST invalidate the compiled mapper configuration of the affected agents, so a bound credential reaches them without waiting for the configuration cache to expire.

#### Scenario: Disabled job is bound
- **GIVEN** a disabled SNMP-mode job whose pre-upgrade fallback resolved to reusable credential C
- **WHEN** the one-time backfill runs
- **THEN** the job SHALL reference C, so re-enabling it later uses C

#### Scenario: Disabled partition job uses the partition's agents
- **GIVEN** a disabled partition-assigned SNMP-mode job
- **WHEN** the one-time backfill runs
- **THEN** the legacy chain SHALL be evaluated against every persisted, non-superseded agent whose `partition_id` equals the job's partition, using each agent record's device for host resolution

#### Scenario: Superseded agent is excluded
- **GIVEN** a partition-assigned SNMP-mode job whose partition holds keeper agent `agent-02`, which resolved the job's fallback to reusable credential C before upgrade
- **AND** superseded agent `agent-01` in the same partition, whose agent-scoped monitoring rule references a different credential R
- **WHEN** the one-time backfill runs
- **THEN** the job SHALL reference C

#### Scenario: Agents not yet connected after restart
- **GIVEN** a partition-assigned SNMP-mode job whose persisted agents all resolved to reusable credential C before upgrade
- **AND** no agent has reconnected to core since it restarted
- **WHEN** the one-time backfill runs
- **THEN** the job SHALL reference C

#### Scenario: Missing agent set is retried
- **GIVEN** an SNMP-mode job whose assigned agent has no persisted record, or whose partition has no persisted, non-superseded agents
- **WHEN** the backfill runs
- **THEN** the job SHALL remain unbound and marked, and show the missing-credential warning
- **AND** the other marked jobs SHALL still be decided in that run
- **AND** the run SHALL fail so the backfill runs again

#### Scenario: Backfill failure is retried
- **GIVEN** the backfill hits a credential read failure or a failed promote, rebind or bind transaction for one job
- **WHEN** the run ends
- **THEN** only that job SHALL remain marked
- **AND** the run SHALL fail so the backfill runs again for the jobs still marked

#### Scenario: Default profile with a reusable credential
- **GIVEN** before upgrade, an SNMP-mode job's fallback resolved to the default SNMP profile, which references reusable credential C
- **WHEN** the one-time backfill runs
- **THEN** the job SHALL reference C
- **AND** later clearing the profile's default flag SHALL NOT change the job's compiled credentials

#### Scenario: Default profile with inline legacy material
- **GIVEN** before upgrade, an SNMP-mode job's fallback resolved to a profile or device override holding inline encrypted SNMP material
- **WHEN** the one-time backfill runs
- **THEN** the material SHALL be promoted to a new reusable SNMP credential
- **AND** the source profile or override SHALL be rebound to that credential
- **AND** the job SHALL reference the same credential
- **AND** promotion, source rebind and job bind SHALL commit in one transaction, so a failure leaves no promoted credential behind
- **AND** a second job whose fallback resolved to the same source SHALL be bound to that credential without a second promotion

#### Scenario: Agent-scoped monitoring rule fallback
- **GIVEN** before upgrade, an SNMP-mode job's fallback resolved to an enabled SNMP monitoring rule scoped to its agent
- **WHEN** the one-time backfill runs
- **THEN** the job SHALL reference that rule's secret

#### Scenario: Same reusable credential through different sources
- **GIVEN** a partition-assigned SNMP-mode job whose pre-upgrade fallback resolves, on one agent, to a host device override referencing reusable credential C and, on another agent, to the default SNMP profile also referencing C
- **WHEN** the one-time backfill runs
- **THEN** the job SHALL reference C

#### Scenario: Ambiguous or empty legacy fallback
- **GIVEN** a partition-assigned SNMP-mode job whose pre-upgrade fallback resolves to different credentials on different agents, or to no credential
- **WHEN** the one-time backfill runs
- **THEN** the job SHALL remain without a referenced credential and SHALL show the missing-credential warning
- **AND** the job's backfill mark SHALL be cleared

#### Scenario: Decided job is not revisited
- **GIVEN** the backfill bound job K and left job L marked because L's partition has no persisted agents
- **AND** an operator then clears K's SNMP credential
- **WHEN** the backfill retries
- **THEN** it SHALL NOT rebind K

#### Scenario: Job that already references a credential is decided as not needed
- **GIVEN** a marked SNMP-mode job that an operator bound to reusable credential C before the backfill reached it
- **WHEN** the backfill runs
- **THEN** the job SHALL still reference C and its mark SHALL be cleared
- **AND** if the operator later clears the job's credential, a later retry SHALL NOT rebind it

#### Scenario: Job changed between read and decision
- **GIVEN** the backfill read a marked job with no referenced credential
- **AND** an operator set or changed the job's credential before the backfill wrote its decision
- **WHEN** the backfill writes its decision
- **THEN** the write SHALL apply to no row and SHALL NOT overwrite the operator's credential
- **AND** the job SHALL stay marked and the run SHALL fail so the retry re-reads it

#### Scenario: Binding reaches the agent promptly
- **GIVEN** an agent whose mapper config was compiled with base `{}` before the backfill bound its job
- **WHEN** the backfill commits the job's binding to credential C
- **THEN** the agent's mapper config SHALL be invalidated, and its next config poll SHALL carry C as the job's base credentials

#### Scenario: Job created after the upgrade is not bound
- **GIVEN** an SNMP-mode job created after the upgrade with no referenced SNMP credential
- **WHEN** the backfill runs or retries
- **THEN** it SHALL NOT bind that job
