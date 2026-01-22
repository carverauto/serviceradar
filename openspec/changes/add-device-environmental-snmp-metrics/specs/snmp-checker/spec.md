## ADDED Requirements
### Requirement: Device-level environmental SNMP polling
The SNMP collector SHALL support polling device-level environmental metrics based on user-selected OIDs and emit results into the `timeseries_metrics` pipeline.

#### Scenario: Poll enabled environmental metrics
- **GIVEN** a device with environmental metrics enabled and configured OIDs
- **WHEN** the SNMP collector runs
- **THEN** it SHALL poll the configured environmental OIDs
- **AND** emit datapoints into `timeseries_metrics` tagged with `device_id`, `metric_name`, and units

#### Scenario: Polling disabled
- **GIVEN** a device where environmental metrics are not enabled
- **WHEN** the SNMP collector runs
- **THEN** it SHALL NOT poll environmental OIDs for that device

---

### Requirement: Use discovered metrics for configuration
The SNMP configuration workflow SHALL use discovered environmental metrics to populate selectable OID options for a device.

#### Scenario: Discovery list drives selectable options
- **GIVEN** a device inventory record with `available_environmental_metrics`
- **WHEN** SNMP metrics configuration is generated
- **THEN** only metrics present in the discovery list SHALL be offered for selection
