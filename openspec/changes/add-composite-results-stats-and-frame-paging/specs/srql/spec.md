## ADDED Requirements

### Requirement: Composite Results Stats GROUP BY

The SRQL service SHALL honour `stats:` on the `composite_results` entity.
`in:composite_results stats:count() as <alias> by <fields>` SHALL return one
JSON object per group, each object containing the group field values and the
count under `<alias>`, ordered by count descending.

Supported group fields:

- `check` / `check_slug` / `slug` (response key `check`)
- `check_name`
- `verdict`
- `status`
- `input_key`, `input_value`, `input_stale` (unnest `inputs` jsonb)

`count()` SHALL be the only supported aggregation. Combinations of group
fields SHALL be legal. Filters on `check`, `verdict`, `status`, `device_uid`,
and `time` SHALL apply before GROUP BY.

An unsupported aggregation or group field SHALL return `InvalidRequest` and
SHALL NOT fall back to a plain row dump. Grouped stats SHALL default to a
limit of 100 and SHALL cap at 500.

The JSON keys SHALL be identical on the Rust execute path and the Elixir NIF
translate path.

#### Scenario: Count by check and verdict

- **GIVEN** two enabled checks with mixed verdicts
- **WHEN** a client sends `in:composite_results stats:count() as n by check,verdict`
- **THEN** SRQL returns one object per `(check, verdict)` pair
- **AND** each object has keys `check`, `verdict`, and `n`
- **AND** results are ordered by `n` descending
- **AND** `check` is the check slug, not the column name `slug`

#### Scenario: Filter then group

- **GIVEN** results for checks `pci-isolation` and `armis-agent-coverage`
- **WHEN** a client sends `in:composite_results check:pci-isolation stats:count() as n by verdict`
- **THEN** every returned group belongs to `pci-isolation`
- **AND** the counts are of all matching result rows, not of a truncated sample

#### Scenario: Count by status

- **WHEN** a client sends `in:composite_results stats:count() as n by status`
- **THEN** SRQL returns at most one row per `healthy` / `degraded` / `down` / `unknown` value that is present

#### Scenario: Unsupported group field errors

- **WHEN** a client sends `in:composite_results stats:count() as n by hostname`
- **THEN** SRQL returns `InvalidRequest`
- **AND** does not return plain composite result rows

#### Scenario: Unsupported aggregation errors

- **WHEN** a client sends `in:composite_results stats:sum(bytes) as n by verdict`
- **THEN** SRQL returns `InvalidRequest`

#### Scenario: Stats without a by clause counts the matching set

- **WHEN** a client sends `in:composite_results check:pci-isolation stats:count() as n`
- **THEN** SRQL returns a single object `{"n": <total matching rows>}`

### Requirement: Composite Results Input Unnest Stats

When a `stats:` group field is `input_key`, `input_value`, or `input_stale`,
SRQL SHALL unnest `device_composite_check_results.inputs` with
`jsonb_each`. Each key in the snapshot is one vantage-point (or other
input) observation. `input_value` is `value->>'value'`; `input_stale` is
`(value->>'stale')::boolean`.

A result row whose `inputs` is NULL or `{}` SHALL contribute zero unnest
rows. Combining `input_*` fields with `check` / `verdict` / `status` SHALL
be legal.

#### Scenario: Vantage-point rollup

- **GIVEN** a check whose inputs include `dfw_edge` and `ord_edge`
- **WHEN** a client sends `in:composite_results check:pci-isolation stats:"count() as n by input_key, input_value"`
- **THEN** SRQL returns one object per `(input_key, input_value)` pair
- **AND** `n` is the number of devices whose snapshot had that key at that value

#### Scenario: Stale split

- **WHEN** a client sends `in:composite_results stats:"count() as n by check, input_key, input_value, input_stale"`
- **THEN** each object includes `input_stale` as a boolean
- **AND** stale and fresh observations of the same key/value are separate groups

#### Scenario: Empty inputs are omitted

- **GIVEN** a result row with `inputs` = `{}`
- **WHEN** a vantage unnest stats query runs
- **THEN** that row SHALL NOT appear in any group

