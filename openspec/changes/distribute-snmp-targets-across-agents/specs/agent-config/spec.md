## ADDED Requirements

### Requirement: SNMP targets are delivered as revisioned deltas
The system SHALL deliver an agent's SNMP target placements outside the compiled agent config, through a paged, revisioned delta endpoint, to every agent that advertises the `snmp-target-deltas:v1` capability.
Each agent has a monotonically increasing SNMP target revision. A request carries the agent's last applied revision. The response carries the added, changed and revoked targets since that revision, in pages of bounded encoded size and count, followed by the new revision. When the requested revision is older than the agent's retained history, or unknown, the response is a full snapshot in the same paged form and is marked as a snapshot.

#### Scenario: Delta proportional to change
- **GIVEN** an agent at SNMP target revision 120 holding 20,000 targets
- **WHEN** two targets are added and one is revoked, and the agent requests changes since revision 120
- **THEN** the response carries three target entries and revision 123
- **AND** no page carries the other targets

#### Scenario: Snapshot after history is compacted
- **GIVEN** an agent whose last applied revision is older than its retained revision history
- **WHEN** it requests changes since that revision
- **THEN** the response is a paged snapshot of every target with an active or draining placement on it, marked as a snapshot
- **AND** the agent replaces its target set with the snapshot once the final page validates

#### Scenario: Interrupted delivery
- **GIVEN** a delta delivered in four pages
- **WHEN** the stream ends after the second page
- **THEN** the agent applies nothing from the incomplete delivery and keeps its last applied revision

### Requirement: SNMP profile definitions stay in the compiled config
For an agent that advertises `snmp-target-deltas:v1`, the compiled agent config SHALL carry the SNMP profile definitions its placed targets reference: profile id, OID sets, interval, timeout and retries. It SHALL NOT carry those targets.
For such an agent, the config version SHALL change when a referenced profile definition changes, and when the set of referenced profiles changes: a placement adds the first target of a profile, or revokes the last one. It SHALL NOT change when a placement change leaves that set and those definitions unchanged.
Core SHALL publish the config version that adds a profile no later than the SNMP target revision that first places a target of it, and SHALL drop a profile from the config only after the agent acknowledges a revision that revokes the profile's last target. The agent SHALL start a collector only for a target in its applied deltas whose profile is in its applied config, and SHALL hold any other target until that config is applied. When the agent applies a config whose definition of a profile changed, it SHALL update its collectors for that profile in place to the new OID set, interval, timeout and retries.

#### Scenario: Placement change leaves the config version alone
- **GIVEN** an agent receiving SNMP targets through deltas
- **AND** it already holds a target of profile A
- **WHEN** another device of profile A is placed on it
- **THEN** its SNMP target revision advances
- **AND** its agent config version is unchanged

#### Scenario: First target of another profile
- **GIVEN** an agent receiving SNMP targets through deltas that holds targets of profile A only
- **WHEN** a device of profile B is placed on it
- **THEN** its SNMP target revision advances
- **AND** its agent config version changes, and its compiled config carries profile B's definition
- **AND** if the delta is applied before that config, the agent starts no collector for the device until profile B's definition is applied

#### Scenario: OID template change
- **GIVEN** a profile whose OID template gains an OID
- **WHEN** the change is saved
- **THEN** the config version of every agent holding a target of that profile changes
- **AND** no target entry is re-sent because of it
- **AND** each such agent's collectors for that profile poll the new OID once the config is applied

### Requirement: SNMP delta availability is pushed as a hint
The gateway SHALL notify a connected agent that a newer SNMP target revision exists with a control-stream message that carries only that revision, and the agent SHALL then request the delta. The periodic config poll SHALL also report the current revision, so an agent that missed a hint still catches up.

#### Scenario: Hint triggers a pull
- **GIVEN** a connected agent at SNMP target revision 40
- **WHEN** placement advances it to revision 41
- **THEN** the control stream carries a hint naming revision 41 and no target payload
- **AND** the agent requests changes since revision 40

### Requirement: SNMP target entries never persist secret material
The system SHALL store, for each placed SNMP target, a reference to its credential and a digest of the resolved credential's version, and SHALL NOT store community strings, SNMPv3 passwords or keys in placement or revision rows. Secret material SHALL be resolved through the unified credential model when a page is served. A change to a credential's material SHALL advance the revision of every placed target that resolves to it.

#### Scenario: Credential rotation reaches its targets
- **GIVEN** a reusable SNMPv3 credential that 300 placed targets resolve to, across four agents
- **WHEN** an operator rotates the credential
- **THEN** each of the four agents receives a delta changing only its own targets that use the credential
- **AND** no placement row contains the old or new password

### Requirement: Legacy agents receive their placed share monolithically
The system SHALL deliver an agent without `snmp-target-deltas:v1` only its placed SNMP targets, inside the compiled `SNMPConfig` as before. That agent's placement SHALL be bounded by the legacy ceiling. Its agent config version SHALL change when its placement changes, when a referenced profile definition changes, or when a placed target's resolved credential digest changes.

#### Scenario: Mixed-version partition
- **GIVEN** a partition with one upgraded agent and one legacy agent
- **WHEN** placement spreads 6,000 devices across them
- **THEN** the legacy agent's compiled `SNMPConfig` holds only its placed targets, no more than the legacy ceiling
- **AND** the upgraded agent receives its own placed share as deltas
- **AND** no device is placed on both agents unless its desired owner count, from redundancy or `replicate`, is greater than one
