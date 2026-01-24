# Change: Fix SRQL builder sort assembly crash

## Why
The SRQL builder crashes when assembling queries for `/devices` and `/observability`, returning 500s in the web UI (GitHub Issue #2474). The error shows the builder calling list concatenation with a string token, which happens while appending `sort:` tokens. This makes core inventory and logs pages unusable in staging.

This regression was introduced by the SRQL array-field builder work in PR #2464 (Issue #2363). The builder pipeline now passes the entity string into `maybe_add_sort/3` due to an argument-order mismatch, so `sort:` tokens try to append to a string instead of a token list. We should restore correct token assembly and add tests to prevent regressions.

## What Changes
- Ensure the SRQL builder preserves token list assembly when applying filters so `sort:` and `limit:` tokens are appended safely.
- Add regression coverage for default queries on devices and logs (observability) and for filtered queries.
- Update SRQL requirements to capture builder query assembly expectations.

## Impact
- Affected specs: srql
- Affected code:
  - `web-ng/lib/serviceradar_web_ng_web/srql/builder.ex`
  - `web-ng/test/serviceradar_web_ng_web/` (SRQL builder tests)
