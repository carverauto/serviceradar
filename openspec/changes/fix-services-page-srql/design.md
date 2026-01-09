# Design: Fix Services Page and SRQL Integration

## Context

The services page (`/services`) displays health check data from `ServiceRadar.Monitoring.ServiceCheck`. The page uses SRQL queries like `in:services time:last_1h sort:timestamp:desc` which are processed by the SRQL Rust NIF and then executed via the AshAdapter.

Two bugs prevent this from working:

1. **Serialization bug**: The Rust NIF fails to serialize time filter variants
2. **Tenant bug**: The AshAdapter doesn't pass tenant context to Ash queries

### Current Flow

```
LiveView mount/handle_params
  -> SRQL.query("in:services time:last_1h ...")
    -> Native.parse(query_string)  # Rust NIF parses SRQL
      -> FAILS: Cannot serialize TimeFilterSpec::RelativeHours
    -> AshAdapter.query(parsed_ast)
      -> Ash.read(ServiceCheck, ...)  # No tenant context
        -> FAILS: TenantRequired
```

## Goals

- Fix both bugs to restore services page functionality
- Ensure consistent tenant isolation for all SRQL queries
- Maintain backwards compatibility with existing SRQL queries

## Non-Goals

- Redesigning the services/health checks data model (future work)
- Adding new service check types
- Changing the SRQL query language syntax

## Decisions

### Decision 1: Fix Rust NIF Serialization

The `TimeFilterSpec` enum in the Rust NIF needs proper serde attributes for serialization.

**Current (broken)**:
```rust
#[derive(Serialize, Deserialize)]
enum TimeFilterSpec {
    RelativeHours(i32),  // Serializes as {"RelativeHours": 1}
    RelativeDays(i32),   // But fails with "cannot serialize tagged newtype"
    // ...
}
```

**Fix**: Use `#[serde(tag = "type", content = "value")]` or flatten the representation:
```rust
#[derive(Serialize, Deserialize)]
#[serde(tag = "type", content = "value")]
enum TimeFilterSpec {
    RelativeHours(i32),
    RelativeDays(i32),
    AbsoluteRange { start: DateTime, end: DateTime },
}
```

**Alternatives considered**:
- String-based serialization: Rejected, loses type safety
- Custom serializer: Overkill for this simple case

### Decision 2: Tenant Context Propagation Pattern

The AshAdapter needs to receive and propagate tenant context. We'll use the existing `actor` pattern.

**Approach**: Modify `SRQL.query/2` to accept an options map including `actor`:

```elixir
# Current
SRQL.query("in:services time:last_1h")

# Updated
SRQL.query("in:services time:last_1h", %{actor: current_user})
```

The AshAdapter will:
1. Extract `actor` from options
2. Extract `tenant_id` from actor for context-based multitenancy resources
3. Pass both `actor:` and `tenant:` options to Ash calls

**Resource tenant requirements**:
| Entity | Resource | Multitenancy Strategy | Needs Tenant |
|--------|----------|----------------------|--------------|
| services | ServiceCheck | :context | Yes |
| gateways | Gateway | :context | Yes |
| devices | Device | :context | Yes |
| events | Event | :context | Yes |
| logs | Log | None (global) | No |
| otel_* | Various | None (global) | No |

**Alternatives considered**:
- Process dictionary: Rejected, not explicit
- GenServer state: Overkill, adds complexity
- Context struct: Over-engineering for current needs

### Decision 3: LiveView Integration

LiveViews already have `current_scope` assigned which contains the authenticated user. We'll use this to pass actor to SRQL queries.

```elixir
# In LiveView
def mount(_params, _session, socket) do
  actor = get_actor(socket)
  # ...
end

defp get_actor(socket) do
  case socket.assigns do
    %{current_scope: %{user: user}} when not is_nil(user) -> user
    _ -> nil
  end
end

# In handle_params
case SRQL.query(query, %{actor: actor}) do
  {:ok, results} -> # ...
  {:error, _} -> # Handle gracefully
end
```

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Breaking existing SRQL queries | All changes are additive; queries without actor will fail gracefully |
| Performance impact of tenant filtering | Tenant filtering happens at DB level via policies, minimal overhead |
| Rust NIF rebuild required | Part of normal build process, well-tested |

## Migration Plan

1. Fix Rust NIF serialization (backwards compatible)
2. Update AshAdapter to accept actor option (backwards compatible)
3. Update LiveViews to pass actor to SRQL queries
4. Test thoroughly before deployment

**Rollback**: Revert commits; no data migration needed

## Resolved Questions

1. **Should we rename "Services" to "Health Checks"?** - No, keep as-is for now. May move/rename later.

2. **Do we need a separate `ServiceStatus` model for agent-pushed status?** - Yes. `ServiceCheck` represents scheduled checks (what to monitor), while `ServiceStatus` should represent agent-pushed status updates (current state). This matches the new architecture where agents push status -> Agent Gateway -> Core.

3. **Should SRQL queries fail hard or soft when tenant context is missing?** - **Fail hard.** Missing tenant context is a security issue, not a graceful degradation scenario. If tenant context is missing, the query MUST fail with a clear error. This is a security FEATURE, not a bug.
