## 1. Implementation
- [x] 1.1 Enable system-wide Oban orphan recovery in core Oban configuration.
- [x] 1.2 Make the recovery threshold configurable at runtime.
- [x] 1.3 Add shared stale-conflict recovery to `ObanSupport.safe_insert/2`.
- [x] 1.4 Route Armis manual enqueue through the shared stale-conflict recovery path.
- [x] 1.5 Preserve explicit manual enqueue failure when a stale uniqueness conflict cannot be cleared immediately.
- [x] 1.6 Add regression tests for stale manual enqueue conflicts.

## 2. Validation
- [x] 2.1 Run focused Oban/Armis regression tests.
- [x] 2.2 Validate the OpenSpec change in strict mode.

## 3. Follow-Up
- [ ] 3.1 Replace remaining subsystem-specific stale Oban reapers with a shared enqueue/recovery helper where their status bookkeeping permits.
- [ ] 3.2 Add operator-facing documentation for `OBAN_LIFELINE_RESCUE_AFTER_MS` and duplicate-execution trade-offs.
