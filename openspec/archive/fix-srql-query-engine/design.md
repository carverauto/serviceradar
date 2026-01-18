# Design: Fix SRQL Query Engine

## Context

SRQL (ServiceRadar Query Language) is a DSL written in Rust that translates user queries to SQL. The web-ng Elixir app calls it via Rustler NIF. For Ash-backed entities, the SRQL AST is converted to Ash queries instead of raw SQL.

### Current Query Flow

```
User Query: "ip:%172.16.80%"
    ↓
Rust Parser: Creates QueryAst with Filter{field: "ip", op: Like, value: "%172.16.80%"}
    ↓
NIF parse_ast(): Serializes AST to JSON → FAILS for TimeFilterSpec
    ↓
Elixir convert_ast_to_params(): Maps "like" → "contains"
    ↓
Ash Adapter apply_filter_op(): No LIKE support, silently ignored
    ↓
Result: Query returns all records (no filter applied)
```

## Goals

- All SRQL filter operations work correctly through Ash adapter
- Quick filters work without user modification
- Array fields use correct PostgreSQL operators
- TimeFilterSpec serializes correctly

## Non-Goals

- Change SRQL DSL syntax
- Add new filter operators beyond current spec
- Redesign Ash adapter architecture

## Decisions

### Decision 1: Quick Filter URL Format

**What**: Add `in:devices` prefix to all device quick filter URLs.

**Why**: SRQL parser requires entity token. This is by design for multi-entity search.

**Example**:
```html
<!-- Before -->
<.link navigate={~p"/devices?q=discovery_sources:sweep"}>

<!-- After -->
<.link navigate={~p"/devices?q=in:devices discovery_sources:(sweep)"}>
```

### Decision 2: LIKE Operator Handling

**What**: Implement proper LIKE handling in Ash adapter.

**Approach**: Strip `%` wildcards and use Ash `ilike` filter for case-insensitive matching:

```elixir
# In apply_filter_op/5
"like" ->
  # Strip % wildcards for Ash ilike
  pattern = String.replace(value, "%", "")
  Ash.Query.filter_input(query, %{field_atom => %{ilike: "%#{pattern}%"}})

"not_like" ->
  pattern = String.replace(value, "%", "")
  Ash.Query.filter(query, not(ilike(^ref(field_atom), ^"%#{pattern}%")))
```

### Decision 3: Array Field Detection

**What**: Detect array fields and use `in` operator instead of LIKE.

**Known array fields**: `discovery_sources`, `agent_list`, `groups`

```elixir
@array_fields MapSet.new(["discovery_sources", "agent_list", "groups"])

defp apply_filter_op(query, entity, field, op, value) when is_binary(field) do
  if MapSet.member?(@array_fields, field) do
    apply_array_filter(query, field, op, value)
  else
    apply_scalar_filter(query, entity, field, op, value)
  end
end

defp apply_array_filter(query, field, _op, value) do
  # Convert to list for array containment
  values = if is_list(value), do: value, else: [value]
  Ash.Query.filter_input(query, %{field_atom => %{contains_any: values}})
end
```

### Decision 4: TimeFilterSpec Serialization

**What**: Fix serde attributes on TimeFilterSpec enum.

The current attributes should work, but there may be a version mismatch:

```rust
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", content = "value", rename_all = "snake_case")]
pub enum TimeFilterSpec {
    RelativeHours(i64),
    RelativeDays(i64),
    // ...
}
```

Expected JSON output:
```json
{"type": "relative_hours", "value": 24}
```

If adjacently-tagged doesn't work with newtype variants, change to externally-tagged:

```rust
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TimeFilterSpec {
    RelativeHours { hours: i64 },
    RelativeDays { days: i64 },
    // ...
}
```

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| LIKE semantics differ from SQL | Document that `%` is substring match only |
| Array detection hardcoded | Add schema introspection later if needed |
| Breaking change to quick filter URLs | No external API, internal only |

## Migration Plan

1. Fix Rust TimeFilterSpec first (unblocks time queries)
2. Add LIKE/array support to Ash adapter
3. Update quick filter URLs
4. Remove tenant code
5. Test all scenarios from GitHub issues
6. Archive outdated `fix-services-page-srql` proposal

## Open Questions

- Should we support anchor patterns (`hostname:cam%` for starts-with)?
- Should array field list come from Ash resource introspection?
