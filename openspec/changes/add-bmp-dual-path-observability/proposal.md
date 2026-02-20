# Change: Add Dual-Path BMP Observability (Raw Routing + Curated OCSF)

## Why
BMP route monitoring traffic is high-volume and low-signal at raw granularity. Forcing all BMP updates into `ocsf_events` reduces search quality, increases storage pressure, and weakens cross-domain correlation workflows.

ServiceRadar already has a dedicated `bmp_routing_events` path and a separate OCSF event model. We need to formalize a dual-path architecture so raw BMP telemetry remains queryable and replayable while only promoted/high-signal BMP events enter OCSF.

## What Changes
- Define BMP dual-path ingestion behavior:
  - Raw/high-volume routing updates persist to `platform.bmp_routing_events`.
  - Only promoted/high-signal BMP events persist to `platform.ocsf_events`.
- Add a first-class SRQL entity for BMP routing events (`in:bmp_events`) backed by `platform.bmp_routing_events`.
- Add an Observability BMP UI surface for searching/filtering raw BMP routing events without polluting general OCSF event workflows.
- Preserve and document correlation requirements between raw BMP rows and promoted OCSF events using stable identities/topology keys.
- Add query/index expectations for high-cardinality BMP investigations.

## Impact
- Affected specs:
  - `observability-signals`
  - `srql`
- Affected code (expected):
  - `elixir/serviceradar_core/lib/serviceradar/event_writer/processors/causal_signals.ex`
  - `elixir/serviceradar_core/priv/repo/migrations/*` (BMP query/index tuning)
  - `rust/srql/src/parser.rs`
  - `rust/srql/src/query/mod.rs`
  - `rust/srql/src/query/viz.rs`
  - `rust/srql/src/query/bmp_events.rs` (new)
  - `web-ng/lib/serviceradar_web_ng_web/srql/catalog.ex`
  - `web-ng/lib/serviceradar_web_ng_web/live/observability_bmp_live/*` (new)
  - `web-ng/lib/serviceradar_web_ng_web/router.ex`
- Breaking changes:
  - No API-breaking change expected for existing `in:events` or `in:logs` SRQL entities.
