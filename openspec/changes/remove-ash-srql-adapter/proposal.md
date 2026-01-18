# Change: Remove Ash SRQL Adapter

## Why

The Ash SRQL adapter (`web-ng/lib/serviceradar_web_ng/srql/ash_adapter.ex`) is a code smell that duplicates logic already present in the Rust SRQL implementation:

1. **Duplicated type handling**: The Elixir adapter re-implements boolean field detection, array field handling, and operator translation that already exists in Rust's `query/*.rs` modules.

2. **Duplicated field mapping**: Field name mappings (e.g., `last_seen` → `last_seen_time`) are maintained in both Rust and Elixir.

3. **Unnecessary complexity**: The adapter adds ~700 lines of Elixir code that intercepts SRQL queries and rebuilds them using Ash, when Rust SRQL already generates correct SQL.

4. **Policy enforcement not needed**: The Ash policies only check "is this an authenticated user?" which is already enforced by LiveView session authentication. Tenant isolation is handled by PostgreSQL `search_path`, not Ash policies.

5. **Bug surface area**: Every SRQL bug requires investigation in both Rust and Elixir to determine where the issue lies. Fixes often end up as workarounds in the adapter rather than proper fixes in Rust.

## What Changes

### Remove Ash Adapter for SRQL Reads
- Delete `web-ng/lib/serviceradar_web_ng/srql/ash_adapter.ex`
- Remove feature flag `ash_srql_adapter` from config
- Update `ServiceRadarWebNG.SRQL` to always use the SQL path (Rust NIF)
- Remove Ash adapter tests

### Keep Ash for Non-Read Operations
- Create/Update/Delete operations continue using Ash resources
- Code actions with business logic remain in Ash
- Relationships and aggregates remain in Ash

### Simplify SRQL Module
- Remove conditional routing logic
- Remove `parse_srql_params` and other adapter-specific helpers
- Direct path: SRQL query → Rust NIF → SQL → Ecto execution

## Impact

- **Affected specs**: `srql`
- **Affected code**:
  - `web-ng/lib/serviceradar_web_ng/srql/ash_adapter.ex` - DELETE
  - `web-ng/lib/serviceradar_web_ng/srql.ex` - Simplify
  - `web-ng/config/config.exs` - Remove feature flag
  - `web-ng/test/serviceradar_web_ng/srql/ash_adapter_test.exs` - DELETE

## Benefits

1. **Single source of truth**: All SRQL query logic lives in Rust
2. **Faster queries**: No Elixir query building overhead
3. **Simpler debugging**: SRQL bugs are in Rust, not split across two languages
4. **Less code to maintain**: ~700 fewer lines of adapter code
5. **Type safety**: Rust's type system catches errors at compile time

## Risks

- **Low**: Ash policies were permissive (allow all authenticated reads)
- **Low**: SQL path is already tested and used for non-Ash entities
- **Mitigation**: Verify authentication is enforced at endpoint level
