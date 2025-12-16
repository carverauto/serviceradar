# Change: Fix SNMP checker health check deadlock

## Why
GitHub issue `#2141` reports a deadlock in the SNMP checker service caused by recursive `sync.RWMutex` read locking: `SNMPService.Check()` acquires `RLock()` and then calls `GetStatus()`, which also calls `RLock()`. If a writer is waiting (e.g., `handleDataPoint()` attempting `Lock()`), Go’s write-preferring `RWMutex` blocks new readers, so the nested `RLock()` blocks indefinitely while still holding the outer `RLock()`. This can hang health checks and make the SNMP checker unresponsive.

## What Changes
- Update `SNMPService.Check()` and/or `SNMPService.GetStatus()` so health checks cannot deadlock under concurrent datapoint updates.
- Add regression test coverage that reproduces the deadlock scenario and verifies the fix.

## Impact
- Affected specs: `snmp-checker`
- Affected code:
  - `pkg/checker/snmp/service.go`
  - `pkg/checker/snmp/*_test.go`
- Risk: low; change is localized to lock usage in health/status paths.

