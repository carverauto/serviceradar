## ADDED Requirements
### Requirement: Logs queries use effective timestamps for time filters and ordering
For the logs entity, SRQL SHALL apply time filters and default ordering against an effective timestamp that coalesces `observed_timestamp` with the event `timestamp`.

#### Scenario: Time filter uses observed timestamp fallback
- **GIVEN** a log record with `observed_timestamp` set later than `timestamp`
- **WHEN** a client queries `in:logs time:last_1h`
- **THEN** SRQL SHALL evaluate the time range against the observed timestamp

#### Scenario: Default ordering uses effective timestamp
- **GIVEN** logs with mixed observed timestamps and event timestamps
- **WHEN** a client queries `in:logs sort:timestamp:desc`
- **THEN** SRQL SHALL order by the effective timestamp first
