# srql

## ADDED Requirements

### Requirement: Timeseries metrics tag filtering

SRQL SHALL support filtering the `timeseries_metrics` entity by arbitrary JSONB
tag keys using the syntax `tags.<key>:<value>`, extracted as `tags->>'<key>'`.

The key SHALL be validated before it is used to build SQL, accepting only
ASCII alphanumerics, underscore, and hyphen, with a maximum length of 64
characters. An invalid key SHALL return an error and SHALL NOT reach the
generated SQL.

Tag filters SHALL support the same operators as other text filters on the
entity: equality, inequality, `LIKE`/`NOT LIKE`, and list membership
(`IN`/`NOT IN`).

#### Scenario: Filter metrics to one site
- **GIVEN** timeseries metrics carry a `site_code` tag
- **WHEN** a client sends `in:timeseries_metrics tags.site_code:ORD`
- **THEN** SRQL returns only rows whose `tags->>'site_code'` equals `ORD`

#### Scenario: Filter metrics to several bands
- **GIVEN** timeseries metrics carry a `band` tag
- **WHEN** a client sends `in:timeseries_metrics tags.band:in:[2.4GHz,5GHz]`
- **THEN** SRQL returns only rows whose `tags->>'band'` is one of those values

#### Scenario: Tag filter applies on the stats path
- **GIVEN** timeseries metrics carry a `site_code` tag
- **WHEN** a client sends `in:timeseries_metrics tags.site_code:ORD stats:avg(value) as v by device_id`
- **THEN** the generated SQL contains a predicate on `tags->>'site_code'`
- **AND** the aggregate covers only that site

#### Scenario: Invalid tag key is rejected
- **WHEN** a client sends `in:timeseries_metrics tags.bad'key:x`
- **THEN** SRQL returns an error naming the invalid tag key
- **AND** no SQL is generated containing the key

### Requirement: Timeseries metrics tag grouping

SRQL SHALL support grouping `timeseries_metrics` stats by a tag key using
`stats:<agg>(<field>) as <alias> by tags.<key>`.

The grouped value SHALL be projected under the key `tags.<key>` in the result
payload so a caller can distinguish it from a column of the same name. Rows
whose tag is absent SHALL be grouped under a single null/unknown group rather
than being dropped, so a total computed from the groups still reconciles.

The tag key SHALL be validated identically to tag filtering before being
interpolated into the group expression.

#### Scenario: Aggregate a fleet metric per site
- **GIVEN** timeseries metrics carry a `site_code` tag
- **WHEN** a client sends `in:timeseries_metrics metric_name:aruba.ap.clients stats:sum(value) as clients by tags.site_code`
- **THEN** SRQL returns one row per distinct `site_code` with the summed value

#### Scenario: Group by a tag alongside a column
- **WHEN** a client sends `in:timeseries_metrics stats:avg(value) as v by metric_name, tags.band`
- **THEN** SRQL groups by both the column and the tag expression

#### Scenario: Rows missing the tag are still counted
- **GIVEN** some rows have no `site_code` tag
- **WHEN** a client groups by `tags.site_code`
- **THEN** those rows appear as a single unknown group rather than being discarded

#### Scenario: Invalid group tag key is rejected
- **WHEN** a client sends `in:timeseries_metrics stats:count() as n by tags.a"b`
- **THEN** SRQL returns an error and generates no SQL containing that key

## MODIFIED Requirements

### Requirement: Timeseries stats filters are never silently discarded

The `timeseries_metrics` stats path SHALL reject a filter field it cannot apply,
returning the same class of error as the non-stats path, instead of omitting the
predicate and running the query unfiltered.

Previously the stats path ended in a catch-all that returned no clause for any
unrecognised field, so `tags.site_code:ORD stats:avg(value) by device_id`
produced a fleet-wide average with the site predicate absent from the SQL and no
diagnostic anywhere.

#### Scenario: Unsupported stats filter field errors
- **WHEN** a client sends `in:timeseries_metrics nonsense_field:x stats:avg(value) as v by device_id`
- **THEN** SRQL returns an error naming the unsupported filter field
- **AND** SRQL does NOT return an unfiltered aggregate

#### Scenario: A typo does not silently widen the query
- **WHEN** a client misspells a supported field, such as `metric_nmae:cpu`
- **THEN** SRQL returns an error rather than aggregating across every metric

### Requirement: CAGG routing never changes which filters apply

A `timeseries_metrics` stats query SHALL NOT be routed to the hourly continuous
aggregate when any of its filters cannot be expressed against that aggregate.
Such a query SHALL fall back to the raw hypertable and apply every filter.

This invariant is already upheld by the routing check. What changes is that the
CAGG filter builder SHALL now return an error for a field it cannot apply,
instead of silently omitting the predicate, so that the invariant fails loudly
rather than silently widening a result if routing and filtering ever drift out
of agreement.

#### Scenario: A filter the CAGG cannot express disables CAGG routing
- **GIVEN** a stats query whose time range would otherwise route to the hourly CAGG
- **WHEN** it filters on `gateway_id`, which the aggregate does not carry
- **THEN** SRQL queries the raw hypertable instead
- **AND** the generated SQL contains the `gateway_id` predicate

#### Scenario: CAGG routing still applies when every filter is expressible
- **GIVEN** a stats query filtering only on `device_id` and `metric_name`
- **WHEN** its time range reaches the routing threshold
- **THEN** SRQL still routes to the hourly CAGG

#### Scenario: The CAGG filter builder refuses a field it cannot apply
- **GIVEN** the CAGG stats builder is reached with a filter outside its projection
- **THEN** it SHALL return an error naming the field
- **AND** it SHALL NOT emit SQL that omits the predicate
