# Change: Upgrade attributed flow explorer and NetFlow process context

## Why

The attributed flows page currently behaves like a narrow debug table: it hard-limits
rows, auto-refreshes unconditionally, exposes confusing unmatched counts, and forces
horizontal scrolling for common investigation workflows. Operators need a first-class
flow investigation surface that can answer which agent observed the flow, which
process was involved, whether the flow matched threat intelligence, and how to drill
from maps or summary cards into details.

## What Changes

- Add paginated browsing with an explicit Live toggle matching the logs pane behavior.
- Make summary cards actionable filters, including a clear attributed-only view and a
  defensible unmatched/raw-flow mode.
- Add clickable rows that open a flow details view or modal with NetFlow tuple,
  attribution, agent, enrichment, and raw payload context.
- Reduce table width by showing high-signal columns first, human-readable byte units,
  compact endpoints, and detail disclosure for long fields.
- Surface collector agent identity for forensics and operational debugging.
- Add reverse-DNS names when known, using a shared enrichment helper/cache rather
  than one-off UI lookups.
- Show CTI/IOC matches from the existing threat-intel coverage pipeline when an IP,
  domain, or flow indicator is linked to AlienVault OTX or other imported intel.
- Integrate attribution state into the NetFlow map so operators can see and drill
  into flows that reached a known process.
- Fix observability chrome so `/observability/flows/attributed` displays
  "Attributed Flows" in the topbar next to the ServiceRadar logo.

## Impact

- Affected specs: `observability-netflow`, `observability-signals`,
  `netflow-analytics`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/flows/attributed_live.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/components/observability_components.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/components/layouts.ex`
  - NetFlow map/dashboard modules under `elixir/web-ng/lib/serviceradar_web_ng_web/live/dashboard_live/**`
  - Flow query/enrichment helpers under `elixir/web-ng/lib/serviceradar_web_ng/**`
  - Threat-intel/CTI enrichment read paths from `add-cti-signal-coverage`
