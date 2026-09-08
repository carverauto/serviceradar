## Context
The requested dashboard is a new web-ng experience inspired by the provided screenshot: a left icon rail/sidebar, dense KPI cards, a prominent topology and traffic map, security event trends, FieldSurvey/Wi-Fi heatmap, camera operations, observability metrics, posture/risk cards, and a SIEM activity feed. ServiceRadar already has NetFlow dashboards, MTR diagnostics, camera surfaces, wireless survey concepts, and a topology God-View built with deck.gl/luma, so this proposal should compose those existing capabilities rather than inventing a separate visualization stack.

## Goals
- Provide a polished dashboard entry point for operators with a stable sidebar shell shared across web-ng routes.
- Make the operations sidebar shell the default authenticated app frame so primary routes no longer mix old and new navigation chrome.
- Match the reference density and information architecture: top KPI strip, map plus event trend row, operations detail row, and bottom investigation widgets.
- Render the primary network topology/traffic map with deck.gl/luma using observed NetFlow/IPFIX summaries, not synthetic traffic.
- Provide a separate NetFlow map mode in the same dashboard widget that maps GeoIP-enriched flow data without topology or MTR overlays.
- Animate MTR diagnostic overlays on the map to show path health, latency, packet loss, or route-change evidence.
- Include camera fleet and Wi-Fi/FieldSurvey regions that use existing data where available and explicit empty states where data is unavailable.
- Provide a camera-first multiview route with selectable 2/4/8/16/32 layouts that opens real relay-backed streams from existing camera inventory where available.
- Compose dashboard panels from configured collectors, materialized service checks, plugin results, and persisted data so deployments without optional collectors still show useful source status.
- Establish the collector-liveness direction for follow-on plumbing: agents check collector reachability and publish status through NATS rather than core polling edge-local collector endpoints directly.
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
- Decision: The map selector switches between distinct view contracts, not a single overloaded scene. `Topology + Traffic` combines topology-oriented positions, observed flow animation, and optional MTR overlays; `NetFlow Map` uses GeoIP flow coordinates and suppresses topology/MTR layers.
- Decision: MTR animation inputs will be read-only summaries from existing MTR diagnostic state. Opening the dashboard must not launch new diagnostics.
- Decision: Vulnerable asset and SIEM alert cards are shell cards for future feeds. They may show empty or unavailable states, but must not imply production ingest exists yet.
- Decision: Camera dashboard and camera multiview panels may open existing on-demand relay sessions immediately when relay-capable camera sources are available. NVR-style always-live recording remains out of scope.
- Decision: The Cameras primary navigation item targets the new multiview operations route. Existing camera relay diagnostics and worker management remain available under observability routes for operators who need them.
- Decision: FieldSurvey/Wi-Fi dashboard panels will be read-only summary panels in this change. Any new survey authoring workflow belongs in follow-up proposals if missing from existing capabilities.
- Decision: The first dashboard composition pass is system-selected rather than user-authored. Panels are shown with states derived from collector packages, persisted records, service checks, and plugin outputs; user-designed dashboards remain a future enhancement.
- Decision: Collector liveness should be agent mediated. Agents are the component expected to reach edge-local collectors; they will publish collector heartbeat/status observations over the existing mTLS/NATS path for core to materialize. Core/web-ng must not assume it can dial arbitrary collector gRPC endpoints directly.
- Decision: NATS JetStream/KV is the preferred heartbeat router for collector liveness because it matches the existing collector publication model and avoids requiring routable collector endpoints from the control plane. The implementation may use a compact stream or KV bucket depending on operational fit, but messages must be bounded, authenticated, and materialized into queryable status for UI use.

## Risks / Trade-offs
- Risk: Reusing God-View rendering internals too directly could couple the dashboard to topology snapshot performance constraints. Mitigation: share only stable rendering utilities/layer conventions, and keep map data contracts dashboard-specific.
- Risk: NetFlow datasets can be high-cardinality. Mitigation: require top-N/time-windowed summaries and server-side bounding for map inputs.
- Risk: Placeholder security cards could mislead operators. Mitigation: require explicit empty/unconnected states until follow-up OpenSpec proposals define real feeds.
- Risk: A global sidebar can disrupt existing page layouts. Mitigation: implement behind shared web-ng layout boundaries and test representative routes at desktop and mobile widths.
- Risk: Collector liveness can become misleading if it relies only on configured packages. Mitigation: show package/configured state separately from recent observed data now, and add agent-published NATS heartbeat materialization before treating a collector as live.

## Migration Plan
1. Add the shared sidebar shell and route-level layout wiring without removing existing routes.
2. Add the dashboard route and static layout states.
3. Add bounded NetFlow summary queries and deck.gl/luma traffic map rendering.
4. Add read-only MTR overlay summaries and animation states.
5. Add adaptive source/collector state cards using existing collector packages, service status, plugin camera checks, and persisted data.
6. Define and begin the NATS-backed collector heartbeat contract for follow-on agent/core plumbing.
7. Add placeholder vulnerable asset and SIEM alert cards with follow-up issue/proposal links in project tracking, not runtime fake data.
8. Add the camera multiview route and wire primary camera navigation to it while retaining the relay diagnostics route.
9. Validate with OpenSpec, LiveView/component tests, and browser/screenshot checks for desktop and mobile layouts.

## Follow-up Proposal Seeds
- `add-vulnerable-asset-tracking`: define asset exposure ingestion, CVE or finding correlation, severity posture, top vulnerable asset ranking, and dashboard card drill-down behavior.
- `add-siem-alert-feed-ingestion`: define SIEM/event source ingestion, alert normalization, severity mapping, acknowledgement state, and the dashboard feed contract.
- `add-user-authored-dashboards`: define saved dashboard layouts, operator-selected panels, role-aware defaults, and migration from the system-selected dashboard.

## Open Questions
- Should the dashboard become the authenticated root route, or should it live at a new route such as `/dashboard` until the shell is proven?
- Which sidebar navigation groups should be in the first shared shell versus deferred until the broader app navigation cleanup?
- Should the first traffic map render geographic flow arcs, topology-relative links, or both depending on available enrichment?
- Should collector heartbeats be stored first in a JetStream KV bucket for latest-state lookup, or as a compacted stream with a database materializer for historical status?
