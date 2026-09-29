## ADDED Requirements

### Requirement: Compiled Sweep Targets Omit Unconsumed Metadata

The system SHALL emit, for each device target in the legacy sweep config
format, only `network`, `sweep_modes`, `query_label`, `source` and
`metadata.device_uid`. It SHALL NOT emit `metadata.sweep_group_id`,
`metadata.target_query`, `metadata.hostname` or `metadata.discovery_sources`,
because no agent or control-plane component reads them. Agents that predate
this requirement SHALL continue to sweep the same targets.

#### Scenario: Legacy target entry carries only consumed fields
- **GIVEN** a sweep group "lab-icmp" with `target_query`
  `in:devices tags.env:"lab"` matching device "sr:dev-0001" at 192.0.2.10
  with hostname host01.example.com
- **WHEN** sweep configuration is compiled in the legacy format
- **THEN** the group's device target for 192.0.2.10 SHALL contain `network`,
  `sweep_modes`, `query_label`, `source` and `metadata.device_uid`
  "sr:dev-0001"
- **AND** its metadata SHALL NOT contain `sweep_group_id`, `target_query`,
  `hostname` or `discovery_sources`

#### Scenario: An agent without the change sweeps the same targets
- **GIVEN** an agent release that predates this requirement
- **WHEN** it applies a legacy sweep config compiled with trimmed metadata
- **THEN** it SHALL sweep the same networks with the same modes and ports as
  before
- **AND** the sweep results it reports SHALL be unchanged

### Requirement: Target Queries Are Evaluated Once and Shared

The system SHALL evaluate each distinct normalized sweep `target_query` at
most once per compile, and SHALL share a query's result across the compiles of
different agents for a configurable TTL, 60 seconds by default. The TTL is kept
short because a compiled config built from shared results is itself cached, so
device membership can lag by both TTLs together. Changing a sweep group or
profile SHALL invalidate the shared results of the queries that group uses. A
query that fails SHALL NOT be cached.

#### Scenario: Equal queries run once per compile
- **GIVEN** several eligible groups whose target queries are equal after
  normalization
- **WHEN** sweep configuration is compiled for one agent in either format
- **THEN** that query SHALL be executed against inventory once for that
  compile
- **AND** every group using it SHALL receive the same device rows

#### Scenario: Leading/trailing whitespace and missing in:devices prefix are normalized before sharing
- **GIVEN** group A with `target_query` `"  in:devices tags.env:\"lab\"  "` (extra whitespace)
- **AND** group B with `target_query` `"in:devices tags.env:\"lab\""` (trimmed)
- **AND** group C with `target_query` `"tags.env:\"lab\""` (no in:devices prefix)
- **WHEN** sweep configuration is compiled
- **THEN** all three groups SHALL share one query evaluation, because all three
  normalize to `"in:devices tags.env:\"lab\""`
- **AND** group D with `target_query` `"in:devices  tags.env:\"lab\""` (internal double space)
  SHALL be evaluated separately, because its normalized form differs in internal whitespace

#### Scenario: Agents in one partition share query results
- **GIVEN** two agents eligible for the same partition-wide group
- **WHEN** both compile sweep configuration within the shared-result TTL
- **THEN** the group's target query SHALL be executed against inventory once

#### Scenario: Shared results expire after the TTL
- **GIVEN** a shared result for a target query
- **WHEN** the configured TTL elapses
- **THEN** the next compile SHALL execute that query against inventory again

#### Scenario: Editing a group's query takes effect on the next compile
- **GIVEN** a cached shared result for a group's target query
- **WHEN** the group's `target_query` is changed
- **THEN** the next compile SHALL use the new query's result, not the cached
  result of the old query

#### Scenario: A failing shared query degrades only the groups that use it
- **GIVEN** a shared target query that raises during a compile
- **AND** another group with a different, working query
- **WHEN** sweep configuration is compiled
- **THEN** every group using the failing query SHALL compile with no device
  targets, and the failure SHALL be logged with the group id and query
- **AND** the group with the working query SHALL compile its device targets
  normally
- **AND** the failure SHALL NOT be cached for later compiles

### Requirement: Compiled Sweep Config Is Independent of Row Order

The system SHALL emit compiled sweep groups sorted by group id, so that the
same groups, profiles and inventory always produce the same config version
regardless of the order in which the database returns rows.

#### Scenario: Row order does not change the config version
- **GIVEN** unchanged sweep groups, profiles and inventory, with no two
  matched devices sharing an IP
- **WHEN** sweep configuration is compiled twice, with groups and inventory
  rows returned in a different order each time
- **THEN** both compiles SHALL produce the same `config_hash` and the same
  config version

### Requirement: Shared Device Targets in Compiled Sweep Config

The system SHALL be able to compile an agent's sweep configuration in the
`shared-targets/v1` format. In that format each device selected by any
eligible group appears once in a `device_table`, keyed by device rather than
by IP; each distinct normalized `target_query` result appears once in
`target_sets`; and each group references its target set by key instead of
embedding `device_targets`. Group-level settings SHALL be stated once per
group. Static `targets` SHALL remain on the group unchanged.

#### Scenario: Three groups over one device set with different scan profiles
- **GIVEN** three sweep groups with the same `target_query`
  `in:devices tags.env:"lab"` matching devices at 192.0.2.10, 192.0.2.11 and
  192.0.2.12
- **AND** group "lab-icmp" uses modes ["icmp"]
- **AND** group "lab-icmp-tcp" uses modes ["icmp", "tcp"] with ports [80, 443]
- **AND** group "lab-tcp-alt" uses modes ["tcp"] with ports [22, 8080]
- **WHEN** sweep configuration is compiled in the `shared-targets/v1` format
- **THEN** `device_table` SHALL contain exactly one entry for each of the
  three devices
- **AND** `target_sets` SHALL contain exactly one set, referencing the three
  devices
- **AND** each of the three groups SHALL reference that set and carry its own
  modes and ports
- **AND** no group SHALL embed a `device_targets` list

#### Scenario: Partially overlapping queries share device entries
- **GIVEN** group A whose query matches the devices at 192.0.2.10 and
  192.0.2.11
- **AND** group B whose different query matches the devices at 192.0.2.11 and
  192.0.2.12
- **WHEN** sweep configuration is compiled in the `shared-targets/v1` format
- **THEN** `target_sets` SHALL contain two sets
- **AND** `device_table` SHALL contain three entries, with the device at
  192.0.2.11 listed once

#### Scenario: Two devices sharing an IP stay distinct
- **GIVEN** device "sr:dev-0001" and device "sr:dev-0002", both reporting IP
  192.0.2.20
- **AND** group A whose query matches only "sr:dev-0001"
- **AND** group B whose different query matches only "sr:dev-0002"
- **WHEN** sweep configuration is compiled in the `shared-targets/v1` format
- **THEN** `device_table` SHALL contain an entry for each device
- **AND** the agent SHALL rehydrate group A's target at 192.0.2.20 with
  `device_uid` "sr:dev-0001" and group B's with "sr:dev-0002", as the legacy
  format does

#### Scenario: Shared-targets document is deterministic
- **GIVEN** unchanged sweep groups, profiles and inventory, with no two
  matched devices sharing an IP
- **WHEN** sweep configuration is compiled twice in the `shared-targets/v1`
  format, with the inventory rows returned in a different order
- **THEN** both compiles SHALL produce the same `config_hash`
- **AND** `device_table` SHALL be ordered by device reference, `target_sets`
  by key, `groups` by id, and each set's references in a stable order

#### Scenario: Overlap diagnostics see the same declared targets
- **GIVEN** a compiled sweep config persisted for an agent in either format
- **WHEN** the device sweep overlap diagnostics are queried
- **THEN** they SHALL report the same declared (group, target, device) rows
  for both formats

### Requirement: Agent Rehydrates Shared Device Targets With Behavior Parity

The agent SHALL accept both the legacy and the `shared-targets/v1` sweep
formats. It SHALL rehydrate `shared-targets/v1` into the same per-group device
target model the legacy format produces, so sweep behavior and the sweep
results it reports are identical for equivalent configurations.

#### Scenario: Parsed targets are identical across formats
- **GIVEN** a legacy sweep config and a `shared-targets/v1` sweep config
  compiled from the same groups and inventory
- **WHEN** the agent parses each one
- **THEN** both SHALL produce equal per-group device targets, with the same
  network, sweep modes, query label, source and `device_uid`
- **AND** a sweep of either SHALL report the same results

#### Scenario: Agent with the capability still accepts the legacy format
- **GIVEN** an agent that advertises `sweep-config-shared-targets:v1`
- **WHEN** it receives a sweep config with no `format` field
- **THEN** it SHALL apply the config as the legacy format

#### Scenario: Unknown format keeps the current sweep config
- **GIVEN** an agent running a valid sweep config
- **WHEN** it receives a sweep section with a `format` value it does not
  recognize
- **THEN** it SHALL keep its current sweep config and log the unknown format
- **AND** it SHALL NOT clear its sweep targets
