## 1. Change module
- [x] 1.1 Implement `ServiceRadar.Inventory.Changes.RemoveDeviceFacts` mirroring `MergeDeviceFacts`: validate keys, enforce caller-owns-provenance, remove value and provenance entry atomically in one SQL UPDATE.

## 2. Ash action and policy
- [x] 2.1 Add `Device.remove_facts` update action with `argument :keys, {:array, :string}` and `change RemoveDeviceFacts`.
- [x] 2.2 Add `action_with_permission(:remove_facts, @devices_facts_write_check)` policy alongside `write_facts`.

## 3. Controller and route
- [x] 3.1 Add `DeviceController.delete_metadata/2` handler for `DELETE /api/devices/:uid/metadata/facts/:key`.
- [x] 3.2 Add route in the `/api` scope in `router.ex`.

## 4. Tests
- [x] 4.1 Core action tests (`device_remove_facts_test.exs`): remove existing fact, remove missing key (no-op), provenance entry removed, non-fact metadata untouched, unauthorized caller denied, reserved key rejected, invalid key format rejected, empty key list rejected, concurrent metadata write preserved.
- [x] 4.2 Controller tests (`device_remove_facts_controller_test.exs`): HTTP 200 on remove, 200 no-op on missing key, provenance gone on GET after remove, 401 unauthenticated, 404 unknown device, 422 other source's fact, 403 missing permission, 422 reserved key.
- [x] 4.3 Add `device_remove_facts_test.exs` to `INTEGRATION_SOURCE_DISPOSITIONS.tsv`.

## 5. OpenSpec
- [x] 5.1 Write `proposal.md` and `tasks.md` under `openspec/changes/add-device-fact-retract-api/`.
