# srql

## ADDED Requirements

### Requirement: Downsampled series may be split by a tag key

SRQL SHALL accept `series:tags.<key>` on the timeseries-backed metric entities
(`timeseries_metrics`, `snmp_metrics`, `rperf_metrics`), splitting a
`bucket:`/`agg:` query into one display series per distinct value of
`tags->>'<key>'`.

The key SHALL be validated with the same rule used for tag filtering and tag
grouping — ASCII alphanumerics, underscore and hyphen, at most 64 characters —
before it is interpolated into the series expression. An invalid key SHALL
return an error and SHALL NOT reach the generated SQL.

`series:core_id` SHALL continue to resolve to `tags->>'core_id'` on these
entities, unchanged, as a pre-existing alias.

Entities whose series fields are real columns rather than tags SHALL continue to
reject `tags.<key>`.

#### Scenario: Split a bucketed sum by SSID
- **GIVEN** metrics carry an `ssid` tag
- **WHEN** a client sends `in:timeseries_metrics metric_name:aruba.ssid.client_count time:last_1h bucket:10m agg:sum series:tags.ssid`
- **THEN** the generated SQL groups by `tags->>'ssid'`
- **AND** each bucket carries one summed value per distinct SSID

#### Scenario: Bucketing at the poll cadence avoids summing repeated polls
- **GIVEN** a collector emitting one point per series every 10 minutes
- **WHEN** a client buckets at `10m` and sums, split by a tag
- **THEN** each bucket aggregates a single poll per series
- **AND** the newest bucket is a true fleet total rather than a multiple of one

#### Scenario: The pre-existing core_id alias is unchanged
- **WHEN** a client sends `in:timeseries_metrics time:last_1h bucket:5m agg:avg series:core_id`
- **THEN** the generated SQL still groups by `tags->>'core_id'`

#### Scenario: An unsafe series tag key is rejected
- **WHEN** a client sends `in:timeseries_metrics time:last_1h bucket:5m agg:avg series:tags.a'b`
- **THEN** SRQL returns an error naming the invalid tag key
- **AND** no SQL is generated containing that key

#### Scenario: Entities without a tags column still reject tag series
- **WHEN** a client sends `in:cpu_metrics time:last_1h bucket:5m agg:avg series:tags.ssid`
- **THEN** SRQL returns an unsupported series field error
