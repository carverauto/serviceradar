## ADDED Requirements

### Requirement: Edge add-on metric feed
The agent SHALL be able to stream its locally collected metric samples to a
co-located native add-on through a dedicated `AddonService` RPC, before those
samples are published to the gateway. The feed SHALL apply flow control so a slow
add-on cannot block the agent's own collection or its gateway publishing path. An
add-on SHALL only receive the metric sources it explicitly declares.

#### Scenario: Add-on subscribes to local sysmon samples
- **WHEN** a native add-on declares a subscription to the local sysmon metric source
- **THEN** the agent SHALL stream locally collected sysmon `MetricBatch` samples to that add-on over the metric-feed RPC
- **AND** it SHALL NOT stream sources the add-on did not declare

#### Scenario: Slow add-on does not stall the agent
- **GIVEN** a co-located add-on is consuming the local metric feed slower than samples are produced
- **WHEN** the add-on falls behind
- **THEN** the agent SHALL apply bounded flow control to the feed
- **AND** the agent's own collection and gateway publishing SHALL continue unaffected

### Requirement: Native add-on resource governance
Native add-on manifests SHALL declare CPU and memory limits, and the add-on
supervisor and systemd unit generator SHALL enforce those limits. An add-on that
approaches its limit SHALL shed work and report the shed rather than impacting
the host or the agent.

#### Scenario: Add-on runs within a declared budget
- **WHEN** a native add-on is deployed with declared CPU and memory limits
- **THEN** the supervisor or systemd unit SHALL enforce those limits (for example `MemoryMax` and `CPUQuota`)
- **AND** the add-on SHALL NOT exceed its declared budget

#### Scenario: Add-on sheds under pressure
- **GIVEN** an anomaly add-on is approaching its memory or CPU limit
- **WHEN** the incoming series rate would exceed its bounded capacity
- **THEN** the add-on SHALL shed analysis for excess series
- **AND** it SHALL emit a telemetry counter recording the shed

### Requirement: Edge-resident per-series anomaly detection
A native anomaly add-on SHALL run the shared per-series detector extracted from
the former central raw-stream analyzer and SHALL own its per-series state
locally, without central ownership or a distributed lease. Detection verdicts
produced at the edge SHALL be equivalent to the verdicts the shared detector
produces for the same input.

#### Scenario: Edge verdict matches shared detector verdict
- **GIVEN** a captured set of metric samples for a series
- **WHEN** the edge anomaly add-on and the shared detector each process those samples
- **THEN** they SHALL produce the same anomaly verdicts

#### Scenario: Add-on restart re-warms without a verdict gap
- **GIVEN** an anomaly add-on with established per-series baselines
- **WHEN** the add-on restarts
- **THEN** it SHALL re-warm baselines from a local checkpoint or the live feed
- **AND** it SHALL suppress verdicts during a bounded warm-up window to avoid cold-start false positives
