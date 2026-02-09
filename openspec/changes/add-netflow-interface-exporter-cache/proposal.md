# Change: Add NetFlow Interface + Exporter Cache (SRQL Dimensions)

## Why

Akvorado-style NetFlow analytics relies on interface and exporter metadata (interface names, speeds/capacity, exporter identity) to make charts and filters understandable and to support units like percent-of-capacity. Today, SRQL can group/filter flows by raw fields like `sampler_address` and numeric SNMP indices, but the UI cannot surface operator-friendly names without a metadata join.

## What Changes

- Add a small cache layer in `platform` that maps flow-side identifiers to inventory metadata:
  - exporter (`sampler_address`) → exporter name/label
  - interface (`sampler_address`, `if_index`) → `if_name`, `if_description`, `if_speed_bps`, and boundary classification (when available)
- Add SRQL dimensions for flows that project this cached metadata (no Ecto chart queries).
- Add a background refresh job to keep the cache up to date from inventory.

## Constraints

- Charts/widgets MUST remain SRQL-driven (no Ecto queries for chart data).
- All DB schema changes MUST be managed via Elixir migrations in `elixir/serviceradar_core/priv/repo/migrations/` with `prefix: "platform"`.

## Impact

- Affected code (planned):
  - `elixir/serviceradar_core/` (migrations + Ash resources + Oban worker)
  - `rust/srql/` (flows query: joins/projections for new dimensions)
  - `web-ng/` (dimension selector labels for exporter/interface dims; units work in follow-up change)
- Affected specs:
  - `srql`
  - `build-web-ui` (NetFlow Visualize dims list)

