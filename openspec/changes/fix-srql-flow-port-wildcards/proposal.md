# Change: Allow wildcard port filters in SRQL flows queries

## Why
SRQL flows queries reject wildcard port filters (for example, `dst_port:%443%`) with "dst_port must be an integer," which blocks contains/starts_with searches in the SRQL query builder and raw SRQL. This is reported in GitHub Issue #2672.

## What Changes
- Accept `%` wildcard patterns for `src_port`/`dst_port` (and endpoint aliases) when using like-style operators
- Keep integer-only validation for equality and list operators
- Add tests for wildcard port filtering and validation behavior

## Impact
- Affected specs: srql
- Affected code:
  - `rust/srql/src/query/flows.rs`
  - `rust/srql/src/query/mod.rs` (if shared helper changes are needed)
  - `rust/srql/src/query/flows.rs` tests
