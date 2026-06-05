# Change: Improve attributed flow investigation UX

## Why

The attributed flows page currently exposes raw joined rows but is hard to use for
real investigation: it mixes unmatched rows into the primary table, lacks
pagination and live-update controls, forces horizontal scrolling, and does not
connect attributed records back to NetFlow details, map paths, agent provenance,
reverse DNS, bytes, or threat-intel context.

## What Changes

- Make `/observability/flows/attributed` an investigation surface with paginated
  rows, a logs-style live update toggle, clickable stat-card filters, compact
  human-readable table cells, and a row details workflow.
- Default the page to attributed rows while preserving explicit filters for
  unmatched/all rows when an operator needs gap analysis.
- Link every attributed row to the underlying NetFlow flow details and surface the
  collecting agent, process/container context, reverse DNS names when available,
  human-readable bytes/packets, and CTI/OTX hit state.
- Add attribution awareness to the dashboard NetFlow map so paths can show whether
  a flow reached a known process and can drill into the same flow details.
- Keep page updates bounded and queryable through deterministic pagination rather
  than growing a horizontally scrolling live table.

## Impact

- Affected specs: `build-web-ui`, `observability-netflow`
- Affected code:
  - `elixir/web-ng/**` attributed flows LiveView/components/routes
  - `elixir/web-ng/**` NetFlow map/dashboard components
  - `elixir/serviceradar_core/**` attributed-flow query/API shape if web-ng needs
    additional fields
  - Existing reverse-DNS, CTI/OTX, and flow details helpers where reusable
