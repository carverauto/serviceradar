# Change: Add management device fallback for SNMP polling

## Why

GitHub Issue: #2783

When the mapper discovers a device's interfaces via SNMP, those interfaces often carry public IP addresses that are routed through the device but not directly reachable from the poller's network (e.g., behind a firewall). DIRE creates new device records for these interface IPs, and when SNMP polling is configured for those devices, the SNMP compiler uses the unreachable public IP as the polling target. There is no mechanism to fall back to polling via the parent device that originally exposed the interface.

Example: A router at `192.168.1.1` has a WAN interface with IP `203.0.113.5`. The mapper discovers the interface, DIRE creates device `sr:abc` with `ip = 203.0.113.5`. SNMP polling tries to reach `203.0.113.5` directly, which fails because it's behind a firewall. The router at `192.168.1.1` is the only SNMP-reachable path.

## What Changes

- **Device schema**: Add `management_device_id` (nullable text FK to `ocsf_devices.uid`) to `ocsf_devices`. This records "to manage/poll this device, go through that device instead."
- **Mapper ingestor**: When the mapper creates a device from a discovered interface IP, set `management_device_id` to the parent device that the interface was discovered on.
- **SNMP compiler**: When compiling a polling target, if the device has `management_device_id` set, use the management device's IP and SNMP credentials as the polling host (the OIDs still target the child device's interfaces).

## Impact

- Affected specs: `snmp-checker`, `device-inventory`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/inventory/device.ex` (add attribute)
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/mapper_results_ingestor.ex` (set management_device_id on creation)
  - `elixir/serviceradar_core/lib/serviceradar/agent_config/compilers/snmp_compiler.ex` (fallback to management device IP)
