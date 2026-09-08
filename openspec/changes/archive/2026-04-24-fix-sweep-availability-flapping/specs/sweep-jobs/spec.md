## MODIFIED Requirements

### Requirement: Sweep Job Execution Tracking

The system SHALL track sweep job execution status and history with accurate host totals and availability counts derived from sweep results. The ICMP scanner SHALL send multiple packets per target for reliable availability detection.

#### Scenario: Agent reports sweep completion
- **GIVEN** an agent completing a sweep job
- **WHEN** the sweep finishes
- **THEN** core SHALL record total hosts scanned, hosts available, and hosts failed for the execution
- **AND** the completion time and duration SHALL be recorded
- **AND** the values SHALL reflect cumulative results for the execution (not per-batch deltas)

#### Scenario: Active scan progress updates
- **GIVEN** an in-progress sweep execution
- **WHEN** progress batches are ingested
- **THEN** core SHALL update the execution with cumulative progress metrics
- **AND** the Active Scans UI SHALL display the current totals and completion percentage

#### Scenario: Response time is preserved on result update
- **GIVEN** a sweep host result exists with a non-zero response time
- **WHEN** a subsequent sweep result is ingested with response_time_ms = 0 or nil
- **THEN** the system SHALL preserve the existing non-zero response time
- **AND** log that response time was preserved

## ADDED Requirements

### Requirement: Multi-Packet ICMP Scanning

The ICMP scanner SHALL send multiple echo requests per target to improve reliability and reduce false-negative availability detection.

#### Scenario: Send configurable number of ICMP packets
- **GIVEN** an ICMP sweep configuration with `icmp_count = 3`
- **WHEN** scanning a target host
- **THEN** the scanner SHALL send 3 ICMP echo requests to the target
- **AND** use incrementing sequence numbers (1, 2, 3)
- **AND** wait for the configured timeout for all replies

#### Scenario: Host available with partial replies
- **GIVEN** 3 ICMP packets sent to a target
- **WHEN** 1 or more replies are received
- **THEN** the host SHALL be marked as available
- **AND** packet_loss SHALL be calculated as `(sent - received) / sent * 100`
- **AND** response_time SHALL be the average of all received reply times

#### Scenario: Host unavailable only when all packets fail
- **GIVEN** 3 ICMP packets sent to a target
- **WHEN** 0 replies are received within the timeout
- **THEN** the host SHALL be marked as unavailable
- **AND** packet_loss SHALL be 100%
- **AND** response_time SHALL be 0

#### Scenario: Default ICMP count when not configured
- **GIVEN** no explicit `icmp_count` configuration
- **WHEN** the ICMP scanner initializes
- **THEN** the scanner SHALL use a default of 3 packets per target

### Requirement: Availability Hysteresis

The system SHALL require multiple consecutive failed sweep results before marking a device as unavailable, to prevent transient network issues from causing status flapping.

#### Scenario: Device remains available during transient failures
- **GIVEN** a device previously marked as available
- **AND** `unavailable_threshold` is set to 2
- **WHEN** a single sweep reports the device as unavailable
- **THEN** the device availability status SHALL remain available
- **AND** the consecutive failure count SHALL increment to 1

#### Scenario: Device marked unavailable after threshold exceeded
- **GIVEN** a device with consecutive failure count of 1
- **AND** `unavailable_threshold` is set to 2
- **WHEN** a second consecutive sweep reports the device as unavailable
- **THEN** the device availability status SHALL change to unavailable
- **AND** the consecutive failure count SHALL be 2

#### Scenario: Failure count resets on success
- **GIVEN** a device with consecutive failure count of 1
- **WHEN** a sweep reports the device as available
- **THEN** the consecutive failure count SHALL reset to 0
- **AND** the device availability status SHALL be available

### Requirement: Response Time Capture

The system SHALL ensure ICMP response times are accurately captured from sweep results and preserved in the database.

#### Scenario: Parse ICMP response time from sweep results
- **GIVEN** sweep results containing ICMP round-trip timing
- **WHEN** the results are processed by SweepResultsIngestor
- **THEN** the `response_time_ms` field SHALL be populated from `icmp_response_time_ns` divided by 1,000,000
- **AND** support both `icmp_response_time_ns` and `icmpResponseTimeNs` field names

#### Scenario: Calculate average response time from multiple packets
- **GIVEN** 3 ICMP packets sent with responses received at 5ms, 7ms, and 6ms
- **WHEN** the result is processed
- **THEN** the response_time SHALL be 6ms (average)
- **AND** packet_loss SHALL be 0%

#### Scenario: Response time from partial packet success
- **GIVEN** 3 ICMP packets sent with only 1 response received at 8ms
- **WHEN** the result is processed
- **THEN** the response_time SHALL be 8ms
- **AND** packet_loss SHALL be 66.67%
- **AND** the host SHALL be marked as available
