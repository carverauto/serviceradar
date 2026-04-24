# Change: Harden Admin API Transport and User Update Atomicity

## Why
The admin API adapters still have several safety gaps: HTTP path parameters are interpolated without encoding, local user updates are split across multiple independent writes, explicit role-profile removal is silently ignored, and list-user pagination accepts unbounded or malformed limits.

## What Changes
- URL-encode admin API path parameters before issuing internal HTTP requests.
- Make local admin user updates apply atomically instead of as a sequence of partially committed writes.
- Distinguish omitted `role_profile_id` from an explicit clear request so admins can revoke role profiles reliably.
- Clamp `list_users` limits to a safe maximum and accept integer inputs without crashing.

## Impact
- Affected specs: `ash-api`, `ash-authorization`
- Affected code: `elixir/web-ng/lib/serviceradar_web_ng/admin_api/http.ex`, `elixir/web-ng/lib/serviceradar_web_ng/admin_api/local.ex`, related tests
