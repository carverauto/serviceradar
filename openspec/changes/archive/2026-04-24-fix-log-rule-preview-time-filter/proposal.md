# Change: Fix log rule preview time filter token

## Why
The log promotion rule preview currently builds `timestamp:>now-1h`, which SRQL treats as a normal filter field and rejects for logs. This causes the "Test Rule" preview to fail with "unsupported filter field for logs: 'timestamp'" and blocks rule creation workflows.

## What Changes
- Use the SRQL `time:` filter token (e.g. `time:last_1h`) when building preview queries for log promotion rules.
- Update preview query tests to assert the correct time filter token.

## Impact
- Affected specs: observability-rule-management
- Affected code: web-ng rule builder preview query assembly
