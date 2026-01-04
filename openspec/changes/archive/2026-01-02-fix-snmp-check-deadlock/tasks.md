## 1. Fix
- [x] 1.1 Remove recursive `RWMutex` read locking in `SNMPService.Check()` (do not call `GetStatus()` while holding `RLock()`, or refactor to share a locked snapshot)
- [x] 1.2 Ensure status snapshot returned by `Check()` remains thread-safe and consistent with `GetStatus()` output expectations

## 2. Tests
- [x] 2.1 Add a regression test that prevents `Check()` from combining `s.mu.RLock()` with a call to `GetStatus()` (static AST assertion)
- [x] 2.2 Ensure the regression test fails on the pre-fix implementation and passes post-fix

## 3. Validation
- [x] 3.1 Run `go test ./pkg/checker/snmp/...`
- [x] 3.2 Run `make lint`
- [x] 3.3 Run `openspec validate fix-snmp-check-deadlock --strict`
