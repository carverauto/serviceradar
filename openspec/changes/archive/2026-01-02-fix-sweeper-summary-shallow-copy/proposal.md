# Change: Fix sweeper summary shallow-copy data races

## Why
Issue #2148 reports data races in `pkg/sweeper` summary collection/streaming caused by shallow-copying `models.HostResult` (`*host`) while holding shard locks, then returning those copies after releasing locks. Because `HostResult` contains pointer/slice/map fields (`PortResults`, `PortMap`, `ICMPStatus`), shallow copies retain references to the underlying shared data, allowing concurrent reads/writes once the lock is released.

This is observable via `go test -race` and can lead to undefined behavior, crashes, or corrupted summary data under concurrent `Process()` + summary access.

## What Changes
- Introduce a shared deep-copy helper for `models.HostResult` that produces a non-aliased snapshot (including `PortResults`, `PortMap`, and `ICMPStatus`).
- Update summary collection and streaming paths in `pkg/sweeper/base_processor.go` to use deep copies before releasing shard locks.
- Update `pkg/sweeper/memory_store.go` host result conversions to use the same deep-copy helper for consistency and to prevent accidental aliasing as the code evolves.
- Add regression tests (including a race-detector test derived from issue #2148) to ensure summaries are safe under concurrent reads/writes.

## Impact
- Affected specs: sweeper
- Affected code:
  - `pkg/models/sweep.go` (new deep-copy helper adjacent to `HostResult`)
  - `pkg/sweeper/base_processor.go` (deep-copy in summary collection/stream)
  - `pkg/sweeper/memory_store.go` (deep-copy in host slice conversion)
  - `pkg/sweeper/*_test.go` (new regression + race tests)
- Risk: Low (purely defensive copying); primary risk is increased CPU/memory during summary retrieval for large host sets.

## Trade-offs
- Deep copying increases per-summary allocation proportional to host/port cardinality, but avoids unsafe aliasing and makes summary consumption lock-free and race-free.
- Alternatives considered:
  - Holding locks while callers consume data (not viable; would leak internal locking to callers and degrade concurrency).
  - Removing `PortMap` from returned objects (would be a behavior change for internal consumers and still leaves `PortResults`/`ICMPStatus` aliasing).

