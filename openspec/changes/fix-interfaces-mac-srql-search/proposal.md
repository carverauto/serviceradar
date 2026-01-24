# Change: Fix SRQL interface MAC address searches

## Why
Operators cannot reliably search interfaces by MAC address via SRQL (e.g., `in:interfaces mac:%0e:ea:14:32:d2:78%`), which currently yields a "Not Found" failure in staging. This blocks common troubleshooting workflows that depend on partial or formatted MAC lookups. GitHub Issue: #2472.

## What Changes
- Define SRQL behavior for interface MAC filters, including case-insensitive, separator-insensitive matching and wildcard patterns.
- Ensure SRQL queries containing `%` wildcards execute successfully when sent through URL-encoded query parameters.
- Add regression coverage for interface MAC searches (exact and wildcard patterns).

## Impact
- Affected specs: srql
- Affected code:
  - `rust/srql/src/query/interfaces.rs`
  - `rust/srql/src/parser.rs` (if parser normalization changes are needed)
  - `web-ng/lib/serviceradar_web_ng_web/srql/*` (if query encoding requires adjustments)
