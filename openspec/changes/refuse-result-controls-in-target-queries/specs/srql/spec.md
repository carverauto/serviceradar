## ADDED Requirements
### Requirement: Target queries refuse result-bounding and aggregation tokens
The control plane SHALL refuse to save an operator-written target query that contains `limit:`, `stats:`, `rollup_stats:`, `other:`, `bucket:` or `downsample:`, with a validation error that names each refused token.

A target query is the SRQL that selects the records a feature acts on: the target query of a credential rule, SNMP, sysmon or visibility profile, sweep group, add-on profile or producer schedule; a composite check scope; an availability source profile, reverse-DNS cohort or ephemeral-expiry exclusion query; a plugin target policy input; a producer schedule `target_input` query; and an MTR policy selector query. Its readers act on the whole selection, so a limit would be silently ignored and an aggregation or time bucket returns rows that are not records to target. `sort:` and `time:` SHALL remain allowed. Every such resource SHALL apply one shared validator. The rule SHALL apply when a target query is created or changed; a query stored before the rule SHALL keep being read whole and SHALL NOT block an update that leaves it unchanged.

#### Scenario: Saving a target query with a limit
- **WHEN** an operator saves a credential rule whose target query is `in:devices vendor_name:Example limit:50`
- **THEN** the save fails with an error naming `limit:50` and stating that it cannot be used in a target query
- **AND** the stored rule is unchanged

#### Scenario: Saving a target query with an aggregation
- **WHEN** an operator saves a target query containing `stats:` or `bucket:`
- **THEN** the save fails with an error naming the refused token

#### Scenario: Sorting is allowed
- **WHEN** an operator saves a target query `in:devices hostname:host01* sort:hostname:asc`
- **THEN** the query is accepted

#### Scenario: A stored query is not re-validated by an unrelated edit
- **GIVEN** a credential rule stored before this rule with target query `in:devices sort:uid:asc limit:1`
- **WHEN** an operator renames the rule without changing its target query
- **THEN** the update succeeds and the rule keeps selecting every device its filters match
