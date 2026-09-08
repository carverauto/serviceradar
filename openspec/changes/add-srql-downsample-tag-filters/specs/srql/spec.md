# srql

## ADDED Requirements

### Requirement: Bucketed queries may be filtered by a tag key

SRQL SHALL accept `tags.<key>:<value>` as a filter on a `bucket:`/`agg:`
(downsample) query over `timeseries_metrics`, evaluated as `tags->>'<key>'`.

The key SHALL be validated with the same rule used for tag filtering, grouping
and series splitting — ASCII alphanumerics, underscore and hyphen, at most 64
characters — before it is interpolated into the predicate. An invalid key SHALL
return an error and SHALL NOT reach the generated SQL.

A tag filter SHALL compose with `series:tags.<key>`, so a query may be both
scoped to one tag value and split by another.

Filter fields the downsample path cannot apply SHALL continue to return an
error rather than being omitted from the query.

#### Scenario: Scope a bucketed aggregate to one site
- **GIVEN** metrics carry a `site_code` tag
- **WHEN** a client sends `in:timeseries_metrics tags.site_code:ORD time:last_1h bucket:10m agg:sum series:tags.ssid`
- **THEN** the generated SQL contains a predicate on `tags->>'site_code'`
- **AND** it still splits the series by `tags->>'ssid'`

#### Scenario: An unsafe downsample tag key is rejected
- **WHEN** a client sends `in:timeseries_metrics tags.a'b:x time:last_1h bucket:10m agg:sum series:metric_name`
- **THEN** SRQL returns an error naming the invalid tag key
- **AND** no SQL is generated containing that key

#### Scenario: Unknown downsample filter fields still error
- **WHEN** a client sends `in:timeseries_metrics nonsense_field:x time:last_1h bucket:10m agg:sum series:metric_name`
- **THEN** SRQL returns an error
- **AND** SRQL does NOT return an unfiltered aggregate
