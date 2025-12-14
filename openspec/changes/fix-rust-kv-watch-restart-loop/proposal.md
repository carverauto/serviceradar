# Change: Fix Rust service KV watch restart loops

## Why
Rust services with KV-backed configuration (flowgger, trapd, sysmon, rperf-client) immediately restart on startup because the NATS KV watcher sends the current value as its first event. This causes an infinite restart loop where services never stabilize. The zen consumer was already fixed with an `is_initial` guard, but other services were missed.

## What Changes
- Apply the same `is_initial` skip pattern to all Rust services using RestartHandle with KV watching:
  - flowgger (`cmd/flowgger/src/main.rs`)
  - trapd (`cmd/trapd/src/main.rs`)
  - sysmon (`cmd/checkers/sysmon/src/main.rs`)
  - rperf-client (`cmd/checkers/rperf-client/src/main.rs`)
- The fix skips the first KV watch event (the initial current value) and only triggers restart on subsequent real config changes

## Impact
- Affected specs: kv-configuration
- Affected code: `cmd/flowgger/src/main.rs`, `cmd/trapd/src/main.rs`, `cmd/checkers/sysmon/src/main.rs`, `cmd/checkers/rperf-client/src/main.rs`
