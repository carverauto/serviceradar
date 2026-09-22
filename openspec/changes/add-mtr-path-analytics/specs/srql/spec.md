## ADDED Requirements

### Requirement: Ratio-of-sums and weighted-mean stats aggregates

The SRQL service SHALL provide the aggregate functions `loss_ratio(<sent>, <received>)` and `wavg(<value>, <weight>)` in a `stats:` clause, computing a ratio of sums and a weight-weighted mean respectively rather than a mean of per-row ratios.

`loss_ratio(a, b)` computes `100 * (SUM(a) - SUM(b)) / SUM(a)`. `wavg(a, b)` computes `SUM(a * b) / SUM(b)`. Both SHALL return NULL for a group whose denominator sums to zero, and SHALL NOT raise a division error or substitute zero. A NULL group SHALL still be returned as a row so a caller can distinguish "no samples" from "no loss".

An entity SHALL reject a column pairing it does not support, and SHALL reject a one-argument call to either function, with an invalid-request error. Existing aggregates are unchanged: `avg` continues to compile to `AVG`.

Each function SHALL be implemented in every dialect that serves an entity offering it, or refused by that dialect with an invalid-request error. The two dialects SHALL NOT return numerically different answers for the same query. This is the aggregate-level instance of the fail-closed and parity requirements owned by `extend-starrocks-to-all-telemetry`; it does not restate or redefine them.

#### Scenario: Loss is a ratio of sums, not a mean of ratios
- **GIVEN** a group containing one hop with `sent=1, received=0` and one hop with `sent=500, received=500`
- **WHEN** a client sends `in:mtr_hops stats:loss_ratio(sent, received) as loss by addr`
- **THEN** the group's loss is approximately `0.2` percent
- **AND** it is not `50` percent, which is what averaging the two per-hop percentages would return

#### Scenario: Weighted latency discounts a low-sample hop
- **GIVEN** a group containing one hop with `avg_us=100000, received=1` and one hop with `avg_us=1000, received=100`
- **WHEN** a client sends `in:mtr_hops stats:wavg(avg_us, received) as latency by addr`
- **THEN** the result is weighted toward the hop with 100 received packets
- **AND** it is lower than the unweighted mean of the two `avg_us` values

#### Scenario: Zero denominator yields NULL rather than zero
- **GIVEN** a group in which every hop has `sent=0`
- **WHEN** a client sends `in:mtr_hops stats:loss_ratio(sent, received) as loss by addr`
- **THEN** the group is returned with `loss` NULL
- **AND** no division error is raised

#### Scenario: Unsupported column pairing is refused
- **WHEN** a client sends `in:mtr_hops stats:loss_ratio(hop_number, received) as loss by addr`
- **THEN** SRQL returns an invalid-request error naming the unsupported pairing

#### Scenario: One-argument call is refused
- **WHEN** a client sends `in:mtr_hops stats:wavg(avg_us) as latency by addr`
- **THEN** SRQL returns an invalid-request error describing the required second argument

#### Scenario: A dialect that cannot express the aggregate refuses it
- **GIVEN** a dialect whose compiler does not implement `wavg`
- **WHEN** a client sends a `wavg` query that the dialect serves
- **THEN** SRQL returns an invalid-request error
- **AND** it does not fall back to an unweighted mean

### Requirement: Time bucket as a stats group dimension

The SRQL service SHALL accept `time:<duration>` as a group dimension in a `stats:` clause, so an aggregation can be grouped by a time bucket alongside other dimensions using `stats:<agg> as <alias> by <dimension>,time:<duration>`.

This dimension is distinct from the `bucket:`/`downsample:` clause and SHALL NOT change it. When `limit:` truncates a bucketed result the newest buckets SHALL be retained, and rows SHALL still be returned in ascending bucket order. Bucket boundaries SHALL be derived identically whether a query is served from raw tables or from a materialized rollup, so the same query resolves to the same bucket regardless of rollup freshness.

A dialect that cannot express a requested bucket duration SHALL refuse it with an invalid-request error, and SHALL NOT silently coarsen it to a duration it does support.

#### Scenario: Aggregate grouped by address and hour
- **WHEN** a client sends `in:mtr_hops time:last_24h stats:loss_ratio(sent, received) as loss by addr,time:1h`
- **THEN** each result row carries an address, a bucket timestamp, and the loss for that address in that hour
- **AND** rows are ordered by bucket ascending

#### Scenario: Limit keeps the newest buckets
- **GIVEN** a 30-day window bucketed at `time:5m`
- **WHEN** a client sends the query with `sort:time:desc limit:100`
- **THEN** the 100 most recent buckets are returned
- **AND** they are rendered in ascending bucket order

#### Scenario: Duration on a non-time dimension is refused
- **WHEN** a client sends `in:mtr_hops stats:loss_ratio(sent, received) as loss by addr:1h`
- **THEN** SRQL returns an invalid-request error

#### Scenario: Unsupported bucket duration is refused, not coarsened
- **GIVEN** a dialect whose bucketing function supports only named units
- **WHEN** a client requests `time:7m` on that dialect
- **THEN** SRQL returns an invalid-request error
- **AND** it does not silently round the bucket to an hour

### Requirement: Relational entity modules refuse stats clauses they cannot execute

The SRQL service SHALL refuse a `stats:` clause with an invalid-request error in every relational entity module that implements no aggregation, and SHALL NOT discard the clause and return a page of raw rows.

This closes the relational-path instance of a defect already required to fail closed on the warehouse path by `extend-starrocks-to-all-telemetry`. It applies to every entity reachable from any authorized surface, including the HTTP API and MCP, not only those exposed in the web UI catalog.

#### Scenario: Entity without aggregation support refuses the clause
- **WHEN** a client sends a `stats:` clause against a relational entity module that implements no aggregation
- **THEN** SRQL returns an invalid-request error naming the entity
- **AND** it does not return a page of raw rows with a success status

#### Scenario: Refusal covers surfaces outside the UI catalog
- **GIVEN** an entity absent from the web UI SRQL catalog
- **WHEN** an API or MCP caller sends a `stats:` clause against it
- **THEN** the clause is refused rather than discarded
