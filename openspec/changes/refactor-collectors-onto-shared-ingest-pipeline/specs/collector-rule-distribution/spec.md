## ADDED Requirements

### Requirement: Rule bundles are distributed through a dedicated NATS bucket
Core SHALL publish each effective rule bundle to a NATS key-value bucket that holds only rule bundles, and collectors SHALL read and watch that bucket over their NATS connection without calling datasvc.

#### Scenario: A rule changes
- **WHEN** an operator creates, updates, enables or disables a rule for a subject
- **THEN** core writes the new bundle for that subject to the rules bucket
- **AND** a collector following that subject activates it without restarting

#### Scenario: A collector reads rules in the cluster
- **WHEN** a collector starts with a rules subject configured
- **THEN** it fetches the bundle from the rules bucket through NATS and then watches it
- **AND** it holds no datasvc endpoint, certificate role or client

#### Scenario: The rules bucket holds nothing else
- **WHEN** a collector's NATS user is granted read access to rule bundles
- **THEN** that grant gives it no access to agent configuration or any other key-value data

### Requirement: Edge collectors read rules from their local leaf
An edge leaf SHALL hold a read-only mirror of the rules bucket in its own JetStream domain, and an edge collector SHALL read rules from that mirror.

#### Scenario: An edge site is provisioned
- **WHEN** an edge site's leaf and collector bundles are generated
- **THEN** the leaf configuration provides the rules mirror
- **AND** the collector configuration names the rules subject it follows

#### Scenario: The site loses its connection to the hub
- **WHEN** an edge leaf is disconnected from the hub
- **THEN** the edge collector keeps applying the last mirrored bundle
- **AND** it activates newer bundles after the leaf reconnects and the mirror catches up

#### Scenario: Nothing new is exposed to the edge
- **WHEN** an edge collector follows its rules
- **THEN** it opens no connection to datasvc, core or any hub service other than the leaf it already uses

### Requirement: A collector without a ruleset passes records through
A collector that has no active ruleset SHALL publish records in the binary batch format with only its built-in field mapping, on the same `logs.normalized.<kind>` subject it uses for normalized batches, with the schema header and without the `Sr-Ruleset-Id` header, and SHALL NOT publish a different format for core to normalize. A batch on `logs.normalized.<kind>` without `Sr-Ruleset-Id` is authorized built-in-mapping pass-through: EventWriter SHALL store it without rules, SHALL NOT reject it, and SHALL record that no ruleset was applied. That trust comes from the NATS publish permission on `logs.normalized.`, which only collector identities and the edge leaf that forwards an edge collector's batches hold.

#### Scenario: Records arrive before the first ruleset
- **WHEN** a collector receives records and has not yet activated a ruleset
- **THEN** it publishes them as binary batches on `logs.normalized.<kind>` with the schema header and no `Sr-Ruleset-Id` header
- **AND** EventWriter stores them without running rules
- **AND** the stored rows show that no rules were applied

#### Scenario: A ruleset becomes active
- **WHEN** a collector activates its first ruleset
- **THEN** every batch it closes afterwards carries that ruleset's digest
- **AND** no batch mixes records normalized under different rulesets

#### Scenario: No rules are configured for a collector
- **WHEN** a collector is deployed with no rules subject
- **THEN** it runs as a pass-through collector and reports that it follows no ruleset

### Requirement: Core runs no rules on collector data
EventWriter SHALL store a collector binary batch on `logs.normalized.<kind>` without evaluating Zen rules, and SHALL evaluate Zen rules for JSON on a collector subject only through the release in which that subject's replacement publisher ships; from the following release it SHALL evaluate Zen rules only for records core itself produces.

#### Scenario: A normalized batch arrives
- **WHEN** EventWriter receives a collector's binary batch on `logs.normalized.<kind>`
- **THEN** it stores the records without running rules
- **AND** it records the ruleset digest the batch carries, if any

#### Scenario: An older collector publishes JSON in the release its replacement ships
- **WHEN** EventWriter receives a JSON record on a legacy collector subject in the release in which that subject's replacement publisher ships
- **THEN** it evaluates Zen on the record with the seeded and configured rules for that subject, as before

#### Scenario: An older collector publishes JSON after the removal release
- **WHEN** EventWriter receives a JSON record on a legacy collector subject in a release after the one in which that subject's replacement publisher shipped
- **THEN** it stores the record with the built-in field mapping and no rules

#### Scenario: Core's own logs
- **WHEN** core publishes an internal log record
- **THEN** EventWriter may apply the rules configured for that internal subject
