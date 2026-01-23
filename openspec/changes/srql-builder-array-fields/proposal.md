# Change: SRQL builder should auto-wrap array field values in list syntax

## Why
When users search for devices by `discovery_sources` using the SRQL query builder, entering a single value like `armis` generates `discovery_sources:armis` which returns 0 results. Users must manually use the list syntax `discovery_sources:(armis)` to get results.

Users should not need to know which fields are arrays vs scalars - the SRQL system should handle this automatically.

GitHub Issue: #2363

## What Changes

Two approaches are possible:

### Option A: Fix in SRQL Builder (Elixir - web-ng)
Add `array_fields` metadata to the SRQL Catalog for each entity, and modify the Builder to always wrap values for array fields in list syntax `()`.

**Pros:**
- Simple change in one place
- No changes to Rust SRQL engine
- Builder already has access to Catalog metadata

**Cons:**
- Only fixes the builder UI, not raw SRQL queries typed by users

### Option B: Fix in SRQL Parser (Rust)
Modify the Rust SRQL parser to automatically treat certain fields as arrays and convert scalar values to list syntax.

**Pros:**
- Works for all SRQL queries (builder and raw)
- Single source of truth

**Cons:**
- Requires schema knowledge in the parser
- More complex implementation
- May need per-entity field metadata

### Recommended: Option A
The builder is the primary user interface for SRQL queries. Fixing it there provides immediate value with minimal risk. Advanced users typing raw SRQL can learn the syntax.

## Impact
- Affected specs: srql
- Affected code:
  - `web-ng/lib/serviceradar_web_ng_web/srql/catalog.ex` - add `array_fields` metadata
  - `web-ng/lib/serviceradar_web_ng_web/srql/builder.ex` - wrap array field values in list syntax
