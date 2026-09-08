# Change: Fix log-to-event rule builder flow

## Why
Creating an event (response) rule from a log entry currently crashes the rule builder LiveView because the prefilled params are not compatible with Phoenix form expectations. This blocks a key workflow for turning log signals into alerting rules.

## What Changes
- Normalize log-derived prefill data so the rule builder form renders without runtime errors.
- Ensure the rule builder can be opened from a log entry and saved with prefilled values.
- Add regression coverage for the log-to-event rule creation flow.

## Impact
- Affected specs: observability-rule-management
- Affected code: web-ng LiveView rule builder components and log detail UI
