## Context
The requested dashboard is a new web-ng experience inspired by the provided screenshot: a left icon rail/sidebar, dense KPI cards, a prominent topology and traffic map, security event trends, FieldSurvey/Wi-Fi heatmap, camera operations, observability metrics, posture/risk cards, and a SIEM activity feed. ServiceRadar already has NetFlow dashboards, MTR diagnostics, camera surfaces, wireless survey concepts, and a topology God-View built with deck.gl/luma, so this proposal should compose those existing capabilities rather than inventing a separate visualization stack.

## Goals
- Provide a polished dashboard entry point for operators with a stable sidebar shell shared across web-ng routes.
- Match the reference density and information architecture: top KPI strip, map plus event trend row, operations detail row, and bottom investigation widgets.
- Render the network traffic map with deck.gl/luma using observed NetFlow/IPFIX summaries, not synthetic traffic.
- Animate MTR diagnostic overlays on the map to show path health, latency, packet loss, or route-change evidence.
- Include camera fleet and Wi-Fi/FieldSurvey regions that use existing data where available and explicit empty states where data is unavailable.
- Show vulnerable asset and SIEM alert cards as honest placeholders that establish layout and follow-up integration points.
- Keep the first implementation additive and approval-gated.

## Non-Goals
- Building vulnerability ingestion, CVE correlation, asset risk scoring, or vulnerable asset workflow behavior.
- Building SIEM ingestion, alert normalization, escalation, or acknowledgement workflows.
- Building new camera ingest, Wi-Fi survey ingest, or floorplan management workflows beyond displaying existing data or empty states.
- Replacing God-View or changing its snapshot lifecycle.
- Adding multitenancy behavior or per-customer navigation modes.

## Decisions
- Decision: The sidebar shell will be implemented as project-owned Phoenix components/layouts in `elixir/web-ng`, with a single navigation model used by dashboard and subsequent app pages.
- Decision: The dashboard traffic map will use deck.gl/luma and should reuse established God-View hook/layer patterns where the abstractions fit, while keeping dashboard map data separate from full topology snapshot data.
- Decision: NetFlow map inputs will be bounded, time-windowed summaries of observed flows. The UI must avoid fake traffic animation when flow data is absent.
- Decision: MTR animation inputs will be read-only summaries from existing MTR diagnostic state. Opening the dashboard must not launch new diagnostics.
- Decision: Vulnerable asset and SIEM alert cards are shell cards for future feeds. They may show empty or unavailable states, but must not imply production ingest exists yet.
- Decision: Camera and FieldSurvey/Wi-Fi dashboard panels will be read-only summary panels in this change. Any new collection, survey authoring, or camera operations workflow belongs in follow-up proposals if missing from existing capabilities.

## Risks / Trade-offs
- Risk: Reusing God-View rendering internals too directly could couple the dashboard to topology snapshot performance constraints. Mitigation: share only stable rendering utilities/layer conventions, and keep map data contracts dashboard-specific.
- Risk: NetFlow datasets can be high-cardinality. Mitigation: require top-N/time-windowed summaries and server-side bounding for map inputs.
- Risk: Placeholder security cards could mislead operators. Mitigation: require explicit empty/unconnected states until follow-up OpenSpec proposals define real feeds.
- Risk: A global sidebar can disrupt existing page layouts. Mitigation: implement behind shared web-ng layout boundaries and test representative routes at desktop and mobile widths.

## Migration Plan
1. Add the shared sidebar shell and route-level layout wiring without removing existing routes.
2. Add the dashboard route and static layout states.
3. Add bounded NetFlow summary queries and deck.gl/luma traffic map rendering.
4. Add read-only MTR overlay summaries and animation states.
5. Add placeholder vulnerable asset and SIEM alert cards with follow-up issue/proposal links in project tracking, not runtime fake data.
6. Validate with OpenSpec, LiveView/component tests, and browser/screenshot checks for desktop and mobile layouts.

## Open Questions
- Should the dashboard become the authenticated root route, or should it live at a new route such as `/dashboard` until the shell is proven?
- Which sidebar navigation groups should be in the first shared shell versus deferred until the broader app navigation cleanup?
- Should the first traffic map render geographic flow arcs, topology-relative links, or both depending on available enrichment?
