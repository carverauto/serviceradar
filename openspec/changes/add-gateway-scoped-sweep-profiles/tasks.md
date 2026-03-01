## 1. Database & Resource Changes

- [x] 1.1 Add `gateway_id` attribute to `SweepGroup` Ash resource
- [x] 1.2 Create Ecto migration for `sweep_groups.gateway_id` column
- [x] 1.3 Add database index on `gateway_id` for query performance
- [x] 1.4 Update `:create` and `:update` actions to accept `gateway_id`
- [x] 1.5 Update `:for_agent_partition` read action to filter by `gateway_id`

## 2. Sweep Compiler Updates

- [x] 2.1 Update `SweepCompiler.compile/3` to accept `gateway_id` option
- [x] 2.2 Update `load_sweep_groups/4` to filter by gateway_id
- [x] 2.3 Add logging for gateway-scoped config compilation

## 3. Agent Config Generator Updates

- [x] 3.1 Add `get_agent_gateway_id/1` helper function
- [x] 3.2 Update `load_sweep_config/1` to resolve and pass gateway_id
- [x] 3.3 Update ConfigServer calls to include gateway_id context

## 4. UI Changes

- [x] 4.1 Add gateway selector component to sweep group form
- [x] 4.2 Load available gateways for the partition in form assigns
- [x] 4.3 Display gateway name in sweep group list view
- [ ] 4.4 Add gateway filter option to sweep groups list

## 5. Testing

- [ ] 5.1 Add unit tests for gateway-scoped sweep group queries
- [ ] 5.2 Add unit tests for sweep compiler with gateway filtering
- [ ] 5.3 Verify backwards compatibility (nil gateway_id works for all gateways)
