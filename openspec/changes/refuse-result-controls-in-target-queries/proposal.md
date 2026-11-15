# Change: Refuse limit and aggregation tokens in saved target queries

## Why

Every reader of an operator-written target query now reads its whole
selection a page at a time with its own page limit
(`read-whole-policy-target-selections`), or matches records against the
query's filters. A `limit:` in a target query therefore never bounds the
selection: the reader's page limit replaces it and every matching record is
still targeted. Accepting the token hides that from the operator, who believes
the selection is capped. `stats:`, `rollup_stats:`, `other:` and `bucket:` /
`downsample:` return aggregate or time-bucketed rows, which are not records a
feature can target.

Each resource also validated its target query separately, in six modules and
one inline function, with different checks: add-on profiles never parsed the
query, and plugin target policies, producer schedules and MTR policies did not
validate theirs at all.

## What Changes

- `ServiceRadar.SRQLTargetQuery.validate/2` is the one target-query rule: it
  makes the entity explicit, optionally restricts it, parses the query, and
  refuses `limit:`, `stats:`, `rollup_stats:`, `other:` and `bucket:` /
  `downsample:` with a message naming each refused token. `sort:` and `time:`
  stay allowed.
- `ServiceRadar.Validations.TargetQuery` applies it to an Ash attribute,
  including atomic updates, and checks only on create or when the attribute
  changes, so a query stored before this rule does not block unrelated edits.
  It replaces the per-resource validators of credential rules, composite
  checks, availability source profiles, the ephemeral-expiry exclusion query,
  reverse-DNS settings and add-on profiles, and is added to plugin target
  policies (`input_definitions`), producer schedules (`target_query` and the
  contract's `target_input` param) and MTR policies
  (`target_selector.srql_query`). `ServiceRadar.Changes.ValidateTargetQuery`
  (SNMP, sysmon and visibility profiles, sweep groups) delegates to it.
- The NetBox credential profile no longer ships the default target query
  `in:devices sort:uid:asc limit:1`, which relied on `limit:` to stay small
  and is refused under this rule. The operator names the NetBox host's device
  record.
- No data migration: stored queries keep working, because readers already
  ignore these tokens. On the demo deployment one add-on profile query carries
  `limit:50` over an explicit 8-agent uid list, so the limit never bound it.

## Impact

- Affected specs: `srql`.
- Affected code: `ServiceRadar.SRQLTargetQuery`,
  `ServiceRadar.Validations.TargetQuery`,
  `ServiceRadar.Changes.ValidateTargetQuery`, and the resources listed above;
  `go/cmd/wasm-plugins/netbox/plugin.yaml` (0.4.1).
