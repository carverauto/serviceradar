## ADDED Requirements
### Requirement: Camera Analysis Worker Probe Telemetry
The platform SHALL emit operational telemetry for active camera analysis worker probing.

#### Scenario: Probe succeeds
- **WHEN** the platform successfully probes a registered camera analysis worker
- **THEN** it emits a probe success signal including worker identity and adapter metadata

#### Scenario: Probe fails
- **WHEN** the platform fails to probe a registered camera analysis worker
- **THEN** it emits a probe failure signal including worker identity and normalized failure reason

#### Scenario: Probe changes worker health state
- **WHEN** an active probe causes a worker health transition
- **THEN** the platform emits a health transition signal with the previous and new health states
