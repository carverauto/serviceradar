# Design: Remove Ash SRQL Adapter

## Current Architecture (Problematic)

```
User SRQL Query
       ↓
ServiceRadarWebNG.SRQL.query/2
       ↓
┌──────────────────────────────────────┐
│  Feature flag: ash_srql_adapter?     │
│                                      │
│  YES                    NO           │
│   ↓                      ↓           │
│  AshAdapter         Rust NIF         │
│   ↓                      ↓           │
│  Parse filters      translate()      │
│   ↓                      ↓           │
│  Build Ash Query    SQL + params     │
│   ↓                      ↓           │
│  Ash.read!()        Ecto.SQL.query   │
└──────────────────────────────────────┘
       ↓
   Results
```

**Problems:**
1. Two query execution paths = two places for bugs
2. AshAdapter duplicates type handling from Rust
3. Feature flag creates conditional complexity
4. Ash policies add no real value (just "allow authenticated")

## Target Architecture (Clean)

```
User SRQL Query
       ↓
ServiceRadarWebNG.SRQL.query/2
       ↓
Native.translate()  [Rust NIF]
       ↓
{sql, params, pagination}
       ↓
Ecto.Adapters.SQL.query()
       ↓
format_response()
       ↓
Results
```

**Benefits:**
1. Single code path = single place to debug
2. Rust handles all type detection, operators, SQL generation
3. No feature flags or conditional routing
4. Simpler, faster, more maintainable

## Authorization Model

### Current (Over-engineered)
```elixir
# In Ash resources
policies do
  bypass always() do
    authorize_if actor_attribute_equals(:role, :system)
  end

  policy action_type(:read) do
    authorize_if always()  # Allow any authenticated user
  end
end
```

### Target (Simpler)
```elixir
# In LiveView / API controllers
# Authentication already enforced by:
# 1. LiveView on_mount hooks (require_authenticated_user)
# 2. API plugs (verify_jwt)
# 3. PostgreSQL search_path (tenant isolation)
```

The Ash policies don't do row-level filtering or complex authorization - they just check if a user is authenticated. This is already handled at the endpoint level.

## Code Changes Summary

| File | Change |
|------|--------|
| `srql/ash_adapter.ex` | DELETE |
| `srql/ash_adapter_test.exs` | DELETE |
| `srql.ex` | Remove Ash routing, simplify to direct NIF path |
| `config/config.exs` | Remove `ash_srql_adapter` feature flag |

## SRQL Module After Refactor

```elixir
defmodule ServiceRadarWebNG.SRQL do
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.SRQL.Native

  def query(query, opts \\ %{}) when is_binary(query) do
    with {:ok, query, limit, cursor, direction, mode, _scope} <- normalize_request(opts),
         {:ok, translation} <- Native.translate(query, limit, cursor, direction, mode) do
      execute_translation(translation)
    end
  end

  defp execute_translation(%{"sql" => sql, "params" => params, "pagination" => pagination}) do
    case Ecto.Adapters.SQL.query(Repo, sql, params) do
      {:ok, %{rows: rows, columns: columns}} ->
        results = format_rows(rows, columns)
        {:ok, %{"results" => results, "pagination" => pagination}}
      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

## Rust SRQL Capabilities (Already Implemented)

The Rust SRQL implementation already handles everything the Ash adapter was trying to do:

| Feature | Rust Implementation |
|---------|---------------------|
| Boolean fields | `parse_bool()` in entity modules |
| Array fields | PostgreSQL `@>` containment |
| LIKE operator | `ILIKE` with proper wildcards |
| Field mapping | Per-entity column definitions |
| Pagination | Cursor-based with keyset |
| Time filters | `TimeFilterSpec` with ranges |
| Stats/aggregates | `stats:` and `rollup_stats:` |

## Migration Path

1. **Phase 1**: Remove feature flag, always use SQL path
2. **Phase 2**: Delete Ash adapter code
3. **Phase 3**: Simplify SRQL module
4. **Phase 4**: Clean up related tests

No data migration needed - this is purely a code path change.
