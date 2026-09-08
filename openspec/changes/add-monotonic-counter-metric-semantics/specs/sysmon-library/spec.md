## ADDED Requirements

### Requirement: Sysmon Counter Semantics
The sysmon library SHALL distinguish gauge values from cumulative monotonic counters and emit counter metadata for every cumulative counter field.

#### Scenario: Network counters are cumulative sums
- **WHEN** sysmon collects interface byte, packet, error, or drop counters
- **THEN** those values SHALL be emitted as raw cumulative integer values
- **AND** they SHALL be tagged as monotonic cumulative sums with units and reset anchor metadata

#### Scenario: Host reboot anchor is present
- **WHEN** sysmon emits cumulative host counters
- **THEN** the sample SHALL include a host boot/reset anchor such as boot time, boot id, or uptime sufficient to detect host reboot between samples

### Requirement: Sysmon Disk IO Counters
The sysmon library SHALL support disk IO counters as cumulative monotonic sums in addition to existing disk capacity gauges.

#### Scenario: Disk IO counters collected
- **WHEN** disk IO collection is enabled
- **THEN** sysmon SHALL emit read/write bytes and read/write operation counters as raw cumulative values
- **AND** disk capacity used/total values SHALL remain gauges
