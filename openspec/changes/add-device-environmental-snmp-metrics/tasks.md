# Tasks: Add Device Environmental SNMP Metrics

## 1. Discovery & Capability Detection
- [ ] 1.1 Define standard environmental OID catalog (cpu, memory, temperature, power, fan, voltage) with data type, units, and category metadata
- [ ] 1.2 Probe environmental OIDs during mapper SNMP discovery and record per-device availability
- [ ] 1.3 Emit SNMP capability flag when mapper obtains valid SNMP responses for a device
- [ ] 1.4 Include available environmental metrics in mapper device payloads

## 2. Inventory & Persistence
- [ ] 2.1 Add device capability fields (e.g., `snmp_supported`) to device inventory model
- [ ] 2.2 Add `available_environmental_metrics` JSONB column to device inventory
- [ ] 2.3 Update ingestion pipeline to persist capability flags and environmental metrics
- [ ] 2.4 Ensure SRQL/device APIs expose capability + available metrics

## 3. SNMP Polling Configuration
- [ ] 3.1 Add device-level SNMP metrics settings (enabled metrics + interval)
- [ ] 3.2 Generate SNMP collector config from enabled environmental metrics
- [ ] 3.3 Emit environmental datapoints into `timeseries_metrics` with device tags

## 4. Web UI
- [ ] 4.1 Add Environmental Metrics section to device details edit view
- [ ] 4.2 Show discovered metric list and allow enabling/disabling polling
- [ ] 4.3 Hide the section when device lacks SNMP capability

## 5. Tests & Validation
- [ ] 5.1 Unit tests for environmental OID probing logic
- [ ] 5.2 Ingestion tests for device capabilities + metrics list
- [ ] 5.3 UI tests for capability gating and save flow
