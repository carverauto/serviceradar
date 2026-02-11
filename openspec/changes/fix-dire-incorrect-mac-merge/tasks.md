## 1. Revert agent_id in interface MAC registration

- [x] 1.1 Set `agent_id: nil` in `register_interface_mac` ids map in `mapper_results_ingestor.ex`
- [x] 1.2 Remove `agent_id` extraction (line 176) and parameter from `register_interface_identifiers` and `register_interface_mac`
- [x] 1.3 Add test: interface MAC registration for a polled device does not include the polling agent's ID

## 2. Mapper device creation for unresolved IPs

- [x] 2.1 In `resolve_device_ids`, when no device found for a device_ip, call DIRE to create a device with `sr:` UUID
- [x] 2.2 Create the device in `ocsf_devices` with `discovery_sources: ["mapper"]`, IP, and partition
- [x] 2.3 Invalidate any existing IP aliases on other devices when a new device is created at that IP
- [x] 2.4 Add tests: mapper creates device when no existing device matches the polled IP
- [x] 2.5 Add tests: mapper-created device gets correct `sr:` UUID and discovery_sources

## 3. MAC Classification (Defensive Layer)

- [x] 3.1 Add `locally_administered_mac?/1` function to `IdentityReconciler` that checks IEEE bit 1 of first octet
- [x] 3.2 Update `register_interface_mac` to set confidence based on MAC classification
- [x] 3.3 Update `merge_conflicting_devices` to skip merge when all shared identifiers are medium-confidence only
- [x] 3.4 Add warning log when a medium-confidence-only merge is blocked
- [x] 3.5 Add tests for MAC classification and confidence-gated merge behavior

## 4. Hostname Conflict Guard (Safety Net)

- [x] 4.1 Add hostname lookup before merge in `merge_conflicting_devices`
- [x] 4.2 Block merge and log warning when both devices have different non-empty hostnames
- [x] 4.3 Add tests for hostname conflict guard

## 5. Device Unmerge

- [x] 5.1 Add `unmerge_device/2` function to `IdentityReconciler` using merge_audit trail
- [x] 5.2 Add unmerge_audit recording for traceability
- [x] 5.3 Add tests for unmerge behavior

## 6. Data Cleanup (one-time, after deploy)

- [x] 6.1 Write migration to reclassify existing locally-administered MAC identifiers from `strong` to `medium` confidence
- [x] 6.2 Remove farm01's MACs from tonka01: delete `device_identifiers` rows on `sr:7588d12c` where `identifier_value` matches `F492BF75C7%` or `F692BF75C7%`
- [x] 6.3 Remove `agent-dusk` identifier from tonka01: delete `device_identifiers` row on `sr:7588d12c` where `identifier_type='agent_id'` and `identifier_value='agent-dusk'`
- [x] 6.4 Remove farm01's IP aliases from tonka01: delete `device_alias_states` on `sr:7588d12c` for `152.117.116.178`, `192.168.1.1`, `192.168.2.1`
- [ ] 6.5 Verify: after next mapper/sweep cycle, farm01 appears as a new `sr:` device with correct identifiers
