## ADDED Requirements

### Requirement: SNMP Requirement Manifest Block

`plugin.yaml` SHALL support an optional top-level `snmp_requirements:` block
declaring the SNMP data the package needs but cannot collect itself.
`ServiceRadar.Plugins.Manifest` SHALL parse and validate the block during
package import and SHALL reject the package when any entry is malformed,
exactly as it does for `actions`, `producer_schedules`, `signal_schemas`, and
`alert_rules`.

Each entry SHALL be composed of exactly the following keys and no others:

- `name` - a non-empty string, unique within the package.
- `description` - a human-readable string explaining what the OIDs yield and
  why the plugin cannot collect them itself.
- `category` - a short grouping label.
- `default_poll_interval_seconds`, `default_timeout_seconds`, `default_retries`
  - positive integers, used **only** to seed the profile at creation.
- `target_hint` - an SRQL query string used **only** to seed the profile's
  `target_query` at creation.
- `oids` - a non-empty list, each entry composed of exactly `oid`, `name`,
  `data_type`, and optionally `scale`, `delta`, `mode`, `max_rows`,
  `walk_timeout_seconds`.

Any other key SHALL be a validation error rather than an ignored value.

#### Scenario: Well-formed snmp_requirements block is accepted

- **WHEN** a package is imported whose `plugin.yaml` declares an
  `snmp_requirements` entry with a `name`, a `description`, and a non-empty
  `oids` list
- **THEN** `Manifest` SHALL parse it into a normalized SNMP requirement
  descriptor
- **AND** the descriptor SHALL be available to the control plane for
  materialization on approval

#### Scenario: A package with no snmp_requirements is unaffected

- **WHEN** a package without an `snmp_requirements` block is imported, approved,
  denied, or revoked
- **THEN** no SNMP template or profile row SHALL be created, read, or modified

### Requirement: A Manifest Cannot Express SNMP Credentials

An `snmp_requirements` entry SHALL NOT contain any credential value or any
reference to one. The keys `version`, `community`, `username`,
`security_level`, `auth_protocol`, `auth_password`, `priv_protocol`,
`priv_password`, and `credential_secret_id` SHALL NOT be accepted, and a
manifest containing any of them SHALL be rejected at parse time.

SNMP credentials SHALL reach a materialized profile only by an operator binding
a credential rule managed under Settings -> Credential Rules. The
materialization catalog SHALL NOT write any credential attribute under any
circumstance.

#### Scenario: Manifest declaring a community string is rejected

- **WHEN** a package is imported whose `snmp_requirements` entry carries
  `community`, `auth_password`, or `credential_secret_id`
- **THEN** manifest validation SHALL reject the package
- **AND** the package SHALL NOT be stored as importable

### Requirement: A Manifest Cannot Arm Its Own Polling

An `snmp_requirements` entry SHALL NOT be able to express `enabled`,
`is_default`, `priority`, `agent_ids`, `host`, or `port`. A manifest containing
any of them SHALL be rejected at parse time.

This is the SNMP counterpart of the rule that an `alert_rules` entry cannot
express `enabled`. A package author SHALL NOT be able to cause outbound SNMP
traffic, to make their profile the instance default, or to outrank an
operator's profile in `SNMPProfile.resolve_profile`'s `priority: :desc`
ordering.

#### Scenario: Approval never starts polling on its own

- **WHEN** a package declaring `snmp_requirements` is approved
- **THEN** every materialized profile SHALL have `enabled: false`,
  `is_default: false`, `priority: 0`, and an empty `agent_ids`
- **AND** no SNMP request SHALL be emitted until an operator enables the
  profile and binds a credential

### Requirement: Declared OIDs Are Validated Against The Agent's Own Rules

Manifest validation SHALL apply the same constraints the Go agent applies, so
that a package which would be rejected at the agent cannot be imported.

Each declared OID SHALL start with `.1.3.6.1.` and consist only of numeric
arcs; each `name` SHALL be non-empty and at most 64 characters; `data_type`
SHALL be one of `counter`, `gauge`, `boolean`, `bytes`, `string`, `float`;
`mode` SHALL be one of `get` or `walk` when present; `scale`, `max_rows`, and
`walk_timeout_seconds` SHALL be non-negative when present.

This is a correctness requirement, not a convenience one. `ValidateForAgent`
rejects an entire agent SNMP config on the first invalid target, and
`ApplyProtoConfig` stops the running service before rebuilding it, so a single
malformed OID from one package would disable SNMP collection for every other
profile on that agent.

#### Scenario: Malformed OID is refused at import, not at the agent

- **WHEN** a package declares an OID that does not start with `.1.3.6.1.`, or a
  `data_type` outside the allowlist
- **THEN** manifest validation SHALL reject the package
- **AND** no agent SHALL ever receive the malformed OID

### Requirement: Materialized OID Names Are Namespaced

The catalog SHALL prefix every materialized OID `name` with the package
identifier before writing it.

The agent rejects duplicate OID *names* within a target
(`errOIDDuplicate`, `go/pkg/agent/snmp/config.go:199`), while
`load_template_oids/2` dedupes by OID *string* only. Two templates that name the
same metric differently-addressed - a plugin shipping `ifInOctets` next to an
operator template that already has one - would otherwise collide.

The blast radius is one target, not the agent: `ValidateForAgent` returns
`([]TargetRejection, error)` and drops the offending target while keeping the
rest of the config (`config.go:333-380`). An earlier version of this note said
the collision "rejects the whole agent config"; that was true before
`ValidateForAgent` was changed to drop targets individually, and is no longer
the justification. Namespacing still matters, because a dropped target is a
silently missing metric, and because it is currently the *only* name-level
defence - the compiler-side backstop in `compile_oids/1`
(`snmp_compiler.ex:578-583`) does not exist.

#### Scenario: A plugin template cannot collide with an operator template

- **WHEN** a materialized template and an operator-authored template are both
  selected on one profile and both declare an OID named `ifInOctets`
- **THEN** the materialized template's OID SHALL carry a package-qualified name
- **AND** the compiled agent config SHALL be accepted

#### Scenario: An alert rule references an OID the same package declares

- **WHEN** a package's `alert_rules` entry sets `match.metric_name` to
  `{snmp_oid: <name>}` naming an OID declared in the same package's
  `snmp_requirements`
- **THEN** manifest validation SHALL accept it, and materialization SHALL store
  the namespaced name the SNMP catalog writes for that OID
- **AND** the stored name SHALL be derived by calling the same naming function
  that writes `SNMPOIDTemplate.oids`, never by re-deriving the string

#### Scenario: An unresolvable or misplaced reference is refused at import

- **WHEN** the referenced OID name is not declared by that package, or an
  `snmp_oid` reference appears anywhere in `match` other than `metric_name`
- **THEN** manifest validation SHALL reject the package naming the offending path
- **AND** no rule matching every metric record SHALL ever be materialized

#### Scenario: Two declared names that truncate to one are refused

- **WHEN** two OIDs in different `snmp_requirements` entries have declared names
  that materialize to the same 64-character name
- **THEN** manifest validation SHALL reject the package
- **AND** a bare `snmp_oid` reference SHALL never resolve ambiguously
