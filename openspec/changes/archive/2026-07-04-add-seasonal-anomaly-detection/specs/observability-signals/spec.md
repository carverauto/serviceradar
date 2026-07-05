## ADDED Requirements

### Requirement: Central seasonal anomaly detection over aggregates
The system SHALL detect seasonal (time-of-day / day-of-week) metric anomalies
centrally by reading the hourly continuous aggregates, building a per-series
hour-of-week baseline distribution over a trailing window, and scoring the latest
bucket on the deseasonalized residual. This detection SHALL read aggregates only
and SHALL NOT consume the raw metrics stream or the per-sample detector.

#### Scenario: Busy time-of-day is not flagged
- **GIVEN** a series whose value is high at 9am every weekday but the current value is within its hour-of-week baseline distribution
- **WHEN** the seasonal detector scores the latest bucket
- **THEN** it SHALL NOT emit an anomaly verdict for that bucket

#### Scenario: Off-baseline-for-time is flagged
- **GIVEN** a series whose value at an hour-of-week is far outside that bucket's historical distribution (for example a weekday-9am level at Sunday 3am)
- **WHEN** the seasonal detector scores the latest bucket
- **THEN** it SHALL emit an "off-baseline-for-time" anomaly verdict
- **AND** the verdict SHALL be attributable to the central seasonal source

### Requirement: Insufficient seasonal baseline defers to the edge signal
The seasonal detector SHALL report an insufficient-baseline state and SHALL NOT
emit an anomaly verdict for an hour-of-week bucket that has fewer than the
configured minimum historical samples, so detection during cold-start relies on
the edge spike signal.

#### Scenario: Cold-start bucket is not flagged
- **GIVEN** an hour-of-week bucket with fewer than the minimum required historical samples
- **WHEN** the seasonal detector evaluates that bucket
- **THEN** it SHALL report insufficient seasonal baseline
- **AND** it SHALL NOT emit an anomaly verdict for that bucket

### Requirement: Edge spike and central seasonal verdicts are correlated
The system SHALL correlate edge spike verdicts with central seasonal context by
series and overlapping time window, and SHALL combine them so a single real event
yields one enriched alert. A spike explained by seasonality SHALL be suppressed or
downgraded; a spike that is also off-baseline for the time SHALL be escalated; a
seasonal deviation with no edge spike SHALL still be surfaced.

#### Scenario: Seasonal-expected spike is suppressed
- **GIVEN** an edge spike verdict for a series
- **AND** the central seasonal context says the current value is normal for this time-of-day/day-of-week
- **WHEN** the verdicts are correlated
- **THEN** the spike SHALL be suppressed or downgraded rather than alerted as an anomaly

#### Scenario: Spike that is also off-baseline is escalated
- **GIVEN** an edge spike verdict for a series
- **AND** the central seasonal context says the current value is also off-baseline for this time
- **WHEN** the verdicts are correlated
- **THEN** the system SHALL escalate it as a high-confidence anomaly

#### Scenario: Seasonal-only deviation is surfaced
- **GIVEN** no edge spike verdict for a series
- **AND** the central seasonal context says the series is off-baseline for this time
- **WHEN** the verdicts are correlated
- **THEN** the system SHALL surface a seasonal anomaly
