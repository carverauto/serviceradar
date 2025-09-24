SRQL (ASQ‑Aligned) Syntax
=================================

SRQL keeps its name but uses an ASQ‑aligned key:value syntax. Queries parse through the ASQ pipeline and translate to SQL for Proton/ClickHouse.

Core Concepts
- Entities: Select the target via `in:` (e.g., `in:devices`, `in:services`, `in:activity` which aliases to `events`).
- Filters: Use `key:value` pairs. Nest with parentheses: `parent:(child:value, ...)`.
- Lists: `key:(v1,v2,...)` compiles to `IN (v1, v2, ...)` for scalar fields.
- Arrays: For array fields (e.g., `discovery_sources`), use repeated single‑value tokens to mean “contains all”: `discovery_sources:(sweep) discovery_sources:(armis)`.
- Negation: Prefix a key with `!` for NOT. Works with single values, lists, and nested groups.
- Wildcards: `%` in values uses `LIKE` / `NOT LIKE`.
- Time: `time:today|yesterday|last_7d|[start,end]` or `timeFrame:"7 Days"`.
- Stats/Windows: `stats:"count() by field"` and `window:5m` add aggregates and time bucketing.

Examples
- Services in a port set over 7 days
  - `in:services port:(22,2222) timeFrame:"7 Days"`

- Devices with a nested service name and a specific type, over 7 days
  - `in:devices services:(name:(facebook)) type:MRIs timeFrame:"7 Days"`

- Activity connection started with nested constraints, over 7 days
  - `in:activity type:"Connection Started" connection:(from:(type:"Mobile Phone") direction:"From > To" to:(partition:Corporate tag:Managed)) timeFrame:"7 Days"`

- Arrays: “contains both” semantics using repeated tokens
  - `in:devices discovery_sources:(sweep) discovery_sources:(armis)`
  - Emits both `has(discovery_sources, 'sweep')` and `has(discovery_sources, 'armis')` ANDed together.

- LIKE and NOT LIKE (wildcards)
  - `in:devices hostname:%cam%` → `hostname LIKE '%cam%'`
  - `in:devices !hostname:%cam%` → `NOT hostname LIKE '%cam%'`
  - Nested: `in:activity decisionData:(host:(%ipinfo.%))` → `decisionData_host LIKE '%ipinfo.%'`
  - Nested negation: `in:activity decisionData:(host:(!%ipinfo.%))` → `NOT decisionData_host LIKE '%ipinfo.%'`

- Boundary/partition alias
  - `boundary` is normalized to `partition` (also `.boundary` → `.partition`).

Tips
- Prefer repeated single‑value tokens for arrays to get “contains all”. Lists with commas are intended for scalars and compile to `IN`.
- Use `time:` or human `timeFrame:"N Units"` for date ranges.
- `in:activity` is an alias for `events` and automatically maps nested dot paths to valid SQL identifiers.

Pipeline
- Parse: query_parser.ml
- Plan: query_planner.ml (entity/attribute mapping, time, stats, window)
- Validate: query_validator.ml (aggregates vs group by, having)
- Translate: translator.ml (Sql IR → SQL)

