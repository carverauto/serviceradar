# Change: Clarify SPIFFE Workload API identity failures for Zen

## Why
Zen logs repeated "SPIFFE Workload API unavailable" warnings when SPIRE returns `PermissionDenied` with "no identity issued" (issue #2401). The current message is ambiguous, and operators do not get guidance that the SPIFFE registration is missing or mismatched.

## What Changes
- Detect SPIFFE Workload API `PermissionDenied`/"no identity issued" responses for the zen consumer and treat them as configuration errors.
- Emit an actionable log message that points to missing or mismatched SPIRE registration, including the trust domain used.
- Retry for a bounded interval (configurable) and then exit with a clear error instead of looping indefinitely.
- Add unit coverage for the new error classification and logging path.

## Impact
- Affected specs: `edge-architecture`
- Affected code: `rust/consumers/zen/src/spiffe.rs`, related tests
- No API or schema changes expected
