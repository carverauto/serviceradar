## 1. Implementation

- [x] 1.1 Add `:agent_id` to `@identifier_types` in `DeviceIdentifier` resource
- [x] 1.2 Add `agent_id` priority 0 to the `priority` calculation in `DeviceIdentifier`
- [x] 1.3 Prepend `:agent_id` to `@identifier_priority` in `IdentityReconciler`
- [x] 1.4 Add `agent_id` field to `strong_identifiers` type
- [x] 1.5 Extract `agent_id` from `metadata["agent_id"]` in `extract_strong_identifiers/1`
- [x] 1.6 Add `agent_id` check to `has_strong_identifier?/1`
- [x] 1.7 Add `agent_id` as first case in `highest_priority_identifier/1`
- [x] 1.8 Add `get_identifier_value/2` clause for `:agent_id`
- [x] 1.9 Add `"agent"` seed to `generate_deterministic_device_id/1`
- [x] 1.10 Register `:agent_id` in `register_identifiers/3`
- [x] 1.11 Thread `agent_id` into `build_device_update_from_agent/2` in `AgentGatewaySync`

## 2. Testing

- [x] 2.1 Add test: `agent_id` resolves to same device after IP change
- [x] 2.2 Add test: `agent_id` takes priority over IP for device resolution

## 3. Verification

- [x] 3.1 `mix compile --warnings-as-errors` passes
- [x] 3.2 `mix credo` passes with no issues
- [x] 3.3 Integration tests pass with database (`mix test --include integration`)
- [ ] 3.4 Deploy to demo and verify: restart agent pod, confirm same `device_uid` is reused
