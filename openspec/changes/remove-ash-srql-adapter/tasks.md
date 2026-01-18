# Tasks: Remove Ash SRQL Adapter

## 1. Delete Ash Adapter Code

- [x] 1.1 Delete `web-ng/lib/serviceradar_web_ng/srql/ash_adapter.ex`
- [x] 1.2 Delete `web-ng/test/serviceradar_web_ng/srql/ash_adapter_test.exs`

## 2. Simplify SRQL Module

- [x] 2.1 Remove AshAdapter alias
- [x] 2.2 Remove `ash_srql_enabled?/0` function
- [x] 2.3 Remove `execute_ash_query/5` function
- [x] 2.4 Remove `parse_srql_params/3` and all AST conversion helpers
- [x] 2.5 Simplify `query_request/1` to always use SQL path
- [x] 2.6 Update telemetry to remove `:ash` path references
- [x] 2.7 Remove unused `scope` parameter from internal functions

## 3. Remove Feature Flag

- [x] 3.1 Remove `ash_srql_adapter` from `config/config.exs`
- [x] 3.2 Verify no other references to the flag exist

## 4. Verify Compilation

- [x] 4.1 Run `mix compile --warnings-as-errors`
- [x] 4.2 Confirm no compilation errors

## 5. Testing (Manual verification needed after deployment)

- [ ] 5.1 Test `in:devices` queries with various filters
- [ ] 5.2 Test `in:logs` queries with time filters
- [ ] 5.3 Test `in:agents` queries
- [ ] 5.4 Test `in:gateways` queries
- [ ] 5.5 Test `in:events` queries
- [ ] 5.6 Test `in:alerts` queries
- [ ] 5.7 Test `in:services` queries
- [ ] 5.8 Test metric entity queries (cpu_metrics, memory_metrics, etc.)

## 6. Cleanup

- [ ] 6.1 Archive `fix-srql-query-engine` change (superseded by this change)
- [ ] 6.2 Close GitHub issues #2255, #2254, #2234 if resolved
