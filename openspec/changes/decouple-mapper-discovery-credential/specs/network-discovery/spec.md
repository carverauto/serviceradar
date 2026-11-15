## MODIFIED Requirements

### Requirement: Secure credential storage for discovery
Discovery credentials (SNMP and API) MUST be stored using AshCloak encryption in CNPG and MUST be redacted in UI-facing responses.

#### Scenario: Save SNMP credentials
- **GIVEN** an admin configures SNMP discovery for a job
- **WHEN** the job is saved
- **THEN** the job SHALL reference a reusable SNMP credential in `platform.network_credential_secrets` and SHALL NOT store SNMP secret material on the job record
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

### Requirement: Mapper discovery credential migration
Upgrading MUST bind each existing SNMP-mode mapper job, enabled or disabled, to the credential its pre-upgrade fallback chain resolved to, without operators re-entering secrets.
Only a job whose legacy chain resolves to no credential, or to different credentials on different agents, MAY remain unbound. A read or write failure during the backfill MUST NOT be treated as an empty result.

#### Scenario: Disabled job is bound
- **GIVEN** a disabled SNMP-mode job whose pre-upgrade fallback resolved to reusable credential C
- **WHEN** the one-time backfill runs
- **THEN** the job SHALL reference C, so re-enabling it later uses C

#### Scenario: Disabled partition job uses the partition's agents
- **GIVEN** a disabled partition-assigned SNMP-mode job
- **WHEN** the one-time backfill runs
- **THEN** the legacy chain SHALL be evaluated against every agent registered in that partition

#### Scenario: Backfill failure is retried
- **GIVEN** the backfill hits a credential read failure or a failed promote, rebind or bind write
- **WHEN** the run ends
- **THEN** the completion marker SHALL NOT be recorded
- **AND** the backfill SHALL run again until it completes

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

#### Scenario: Agent-scoped monitoring rule fallback
- **GIVEN** before upgrade, an SNMP-mode job's fallback resolved to an enabled SNMP monitoring rule scoped to its agent
- **WHEN** the one-time backfill runs
- **THEN** the job SHALL reference that rule's secret

#### Scenario: Ambiguous or empty legacy fallback
- **GIVEN** a partition-assigned SNMP-mode job whose pre-upgrade fallback resolves to different credentials on different agents, or to no credential
- **WHEN** the one-time backfill runs
- **THEN** the job SHALL remain without a referenced credential and SHALL show the missing-credential warning

#### Scenario: Backfill runs once
- **GIVEN** the backfill has completed
- **AND** an operator later clears a job's SNMP credential
- **WHEN** core restarts
- **THEN** the backfill SHALL NOT run again and SHALL NOT rebind the job
