## 1. Foundation (Already Complete)

- [x] 1.1 Add `DiscoveryInterval` field to `SourceConfig` struct in `pkg/models/sync.go`
- [x] 1.2 Add `discovery_interval` to sync config generator payload in Elixir
- [x] 1.3 Expose all three interval fields in Integration Sources UI (poll, discovery, sweep)
- [x] 1.4 Verify Go code compiles with new field

## 2. Interval Resolution

- [x] 2.1 Add `GetEffectiveDiscoveryInterval(source)` helper that returns per-source or global default
- [x] 2.2 Add `GetEffectivePollInterval(source)` helper (per-source or global)
- [x] 2.3 Add `GetEffectiveSweepInterval(source)` helper (per-source or global)
- [x] 2.4 Unit tests for interval resolution with various combinations

## 3. Per-Source Scheduler

- [ ] 3.1 Refactor discovery loop to track per-source last-run timestamps
- [ ] 3.2 Implement source-level scheduling: only run discovery for sources whose interval has elapsed
- [ ] 3.3 Handle dynamic config updates: reset timers when source intervals change
- [ ] 3.4 Log per-source discovery scheduling decisions for debugging

## 4. Integration Testing

- [ ] 4.1 Test source with explicit discovery_interval runs on its schedule
- [ ] 4.2 Test source without discovery_interval uses global default
- [ ] 4.3 Test mixed sources (some with intervals, some without)
- [ ] 4.4 Test config update changes discovery schedule

## 5. Documentation

- [ ] 5.1 Update sync service README with per-source interval documentation
- [ ] 5.2 Add example config showing per-source intervals
