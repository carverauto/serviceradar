# Change: Harden Identity Cache And Credential Accounting

## Why
Two real reliability/security flaws remain in the identity and authentication stack. The identity cache can self-inflict a denial of service when oversized eviction copies the full ETS table into memory, and access credential usage counters still lose updates under concurrent use. There is also a low-severity race during first-user bootstrap that can grant admin to more than one concurrent initial registrant.

## What Changes
- Replace full-table ETS eviction in the identity cache with bounded eviction that does not materialize the entire table in the GenServer process.
- Make API token and OAuth client usage accounting atomic so concurrent requests cannot lose `use_count` increments.
- Remove the first-user bootstrap race so initial admin assignment is deterministic under concurrent registration.

## Impact
- Affected specs: `device-identity-reconciliation`, `ash-authentication`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/identity/identity_cache.ex`
  - `elixir/serviceradar_core/lib/serviceradar/identity/access_credential_changes.ex`
  - `elixir/serviceradar_core/lib/serviceradar/identity/api_token.ex`
  - `elixir/serviceradar_core/lib/serviceradar/identity/oauth_client.ex`
  - `elixir/serviceradar_core/lib/serviceradar/identity/changes/assign_first_user_role.ex`
