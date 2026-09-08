## 1. Add management_device_id to device schema

- [x] 1.1 Add `management_device_id` attribute (nullable text) to `ServiceRadar.Inventory.Device` Ash resource
- [x] 1.2 Generate Ash migration with `mix ash.codegen add_management_device_id`
- [x] 1.3 Add test: device can be created with and without `management_device_id`

## 2. Set management_device_id during mapper ingestion

- [x] 2.1 In `mapper_results_ingestor.create_device_for_ip`, when creating a device from a discovered interface IP, set `management_device_id` to the parent device's UID (the device that owns the interface)
- [x] 2.2 Add test: mapper-created device from interface IP has `management_device_id` pointing to parent device

## 3. SNMP compiler management device fallback

- [x] 3.1 In `snmp_compiler.compile_device_target`, when `device.ip` is set but `device.management_device_id` is also set, load the management device and use its IP as the SNMP polling host
- [x] 3.2 Add test: SNMP target for device with `management_device_id` uses the management device's IP as host
- [x] 3.3 Add test: SNMP target for device without `management_device_id` uses its own IP as host (no regression)
