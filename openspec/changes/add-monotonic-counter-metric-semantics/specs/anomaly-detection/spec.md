## ADDED Requirements

### Requirement: Counter-Aware Anomaly Samples
The anomaly extractor SHALL evaluate cumulative monotonic counters as normalized rates or deltas, not raw cumulative values.

#### Scenario: Cumulative counter does not ramp forever
- **GIVEN** a cumulative monotonic counter grows steadily over time
- **WHEN** samples are extracted for anomaly detection
- **THEN** the detector SHALL evaluate the derived rate or delta
- **AND** the raw cumulative ramp SHALL NOT create a permanent z-score breach

#### Scenario: Reset interval is suppressed
- **GIVEN** a cumulative counter reset is detected by anchor change or value decrease
- **WHEN** anomaly samples are extracted
- **THEN** the reset interval SHALL be dropped or marked non-evaluable
- **AND** it SHALL NOT be emitted as an anomaly spike
