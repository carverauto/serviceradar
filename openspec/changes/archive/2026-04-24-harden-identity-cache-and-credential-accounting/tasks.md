## 1. Implementation
- [x] 1.1 Replace full-table identity cache eviction with a bounded strategy that does not call `:ets.tab2list/1` on the full cache.
- [x] 1.2 Make API token usage accounting atomic under concurrent requests.
- [x] 1.3 Make OAuth client usage accounting atomic under concurrent requests.
- [x] 1.4 Eliminate the first-user admin bootstrap race under concurrent registration.

## 2. Verification
- [x] 2.1 Add focused tests for bounded identity cache eviction behavior.
- [x] 2.2 Add focused tests for atomic API token and OAuth client usage counting.
- [x] 2.3 Add focused tests for deterministic first-user admin assignment under concurrency.
- [ ] 2.4 Run `mix compile` in `elixir/serviceradar_core` and the focused identity/auth test targets.
