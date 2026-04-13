## ADDED Requirements

### Requirement: Armis northbound availability updates
ServiceRadar SHALL support a northbound Armis update cycle for enabled Armis sources that define a `custom_field`, so it can push post-sweep availability state back to Armis for previously discovered devices.

#### Scenario: Armis-discovered device is updated after sweep
- **GIVEN** an enabled Armis integration source has discovered a device and stored its `armis_device_id`
- **AND** ServiceRadar has computed current availability for that device from agent ICMP/TCP sweep results
- **WHEN** the northbound Armis reconciliation cycle runs
- **THEN** ServiceRadar SHALL send an update to Armis for that `armis_device_id`
- **AND** the update SHALL write the device's current availability state to the configured `custom_field`

#### Scenario: Northbound updates are disabled when no target field is configured
- **GIVEN** an enabled Armis integration source does not define `custom_field`
- **WHEN** ServiceRadar completes discovery and sweep processing for Armis-discovered devices
- **THEN** ServiceRadar SHALL NOT issue northbound Armis custom-property updates for that source

### Requirement: Armis northbound correlation uses Armis device identity
Northbound Armis updates SHALL be correlated by `armis_device_id`, not by individual sweep targets or transient IP rows.

#### Scenario: One Armis device has multiple sweep targets
- **GIVEN** a single Armis device fans out to multiple sweep targets or IP addresses
- **AND** those targets all carry the same `armis_device_id`
- **WHEN** ServiceRadar computes the device's consolidated availability
- **THEN** ServiceRadar SHALL emit exactly one northbound update for that `armis_device_id`
- **AND** the outbound value SHALL reflect the consolidated device availability rather than a per-target intermediate state

### Requirement: Armis northbound updates read canonical database-backed state
Northbound Armis updates SHALL read the latest consolidated device availability from the database-backed inventory/observability state and SHALL NOT depend on legacy NATS KV payloads as their source of truth.

#### Scenario: Latest Armis availability is derived from persisted state
- **GIVEN** Armis-discovered device availability has already been ingested and consolidated by ServiceRadar
- **WHEN** a northbound Armis update job executes
- **THEN** the job SHALL query persisted state from the database
- **AND** SHALL NOT require replaying or reading a KV-managed sweep payload to decide what to send to Armis

### Requirement: Only Armis-identifiable devices are updated northbound
ServiceRadar SHALL skip northbound Armis updates for records that cannot be confidently matched to an Armis device.

#### Scenario: Device state is missing Armis identity
- **GIVEN** a device state originated from Armis discovery but does not contain a usable `armis_device_id`
- **WHEN** the northbound reconciliation cycle prepares outbound updates
- **THEN** ServiceRadar SHALL skip that record
- **AND** SHALL continue processing other valid Armis device updates in the same cycle

### Requirement: Armis northbound outcomes are persisted separately from inbound sync lifecycle
ServiceRadar SHALL persist northbound Armis update status separately from inbound discovery status so operators can distinguish discovery failures from outbound update failures.

#### Scenario: Discovery succeeds but northbound update fails
- **GIVEN** an Armis integration source has a successful inbound discovery run
- **AND** a subsequent northbound Armis update run fails
- **WHEN** operators inspect the source status
- **THEN** the system SHALL retain the successful discovery status
- **AND** SHALL also persist a northbound failure status with its own timestamp and error details

### Requirement: Armis northbound updates use bulk custom-property writes
ServiceRadar SHALL send Armis northbound availability updates through the Armis bulk custom-properties API, SHALL batch updates for large device populations, and SHALL report failures through persisted status/logging.

#### Scenario: Batch update succeeds
- **GIVEN** ServiceRadar has multiple Armis device availability updates ready for a source
- **WHEN** the runtime sends them to Armis
- **THEN** the runtime SHALL submit them in batch requests to the Armis custom-properties bulk endpoint
- **AND** SHALL record the update cycle as successful when Armis accepts the batch

#### Scenario: Batch update fails
- **GIVEN** ServiceRadar attempts a northbound Armis batch update
- **WHEN** Armis rejects the request or returns a non-success response
- **THEN** the runtime SHALL record the failure reason in persisted status/logging
- **AND** operators SHALL be able to distinguish northbound update failures from inbound discovery failures

### Requirement: Armis northbound runs emit metrics and event records
ServiceRadar SHALL emit per-run metrics and persisted success/failure events for northbound Armis update execution.

#### Scenario: Successful northbound run emits observability data
- **GIVEN** a northbound Armis update run completes successfully
- **WHEN** the run finishes
- **THEN** the system SHALL emit metrics for run count, duration, and updated device count
- **AND** SHALL persist a success event describing the run outcome

#### Scenario: Failed northbound run emits observability data
- **GIVEN** a northbound Armis update run fails
- **WHEN** the run finishes
- **THEN** the system SHALL emit failure metrics for the run
- **AND** SHALL persist a failure event with the integration source identifier and error summary
