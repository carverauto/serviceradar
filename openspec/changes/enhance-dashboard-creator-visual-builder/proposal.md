# Change: Enhance dashboard creator visual builder

## Why
The first dashboard creator implementation proves that users can save SRQL-backed dashboards, but the authoring surface is still too primitive for production use. Panel queries are edited as raw text instead of reusing the existing SRQL query builder, visualizations are not bound to explicit query output fields, table cells can leak raw JSON, and dashboard URLs expose UUIDs instead of operator-friendly identifiers.

ServiceRadar needs a richer first-party dashboard generator where users can compose multiple SRQL datasets, bind visuals to specific output fields, configure labels and layout, and render high-signal tables and charts without writing custom JavaScript.

## What Changes
- Replace the dashboard creator's raw SRQL-only panel editor with the existing SRQL builder component/state model, while retaining raw SRQL escape hatch behavior for unsupported queries.
- Model authored dashboards as one or more named SRQL datasets, then bind visualizations to explicit dataset output fields and transforms.
- Add a richer visualization registry for gauges, availability ratios, status/icon fields, sparklines, stat cards, categorical charts, and table cell renderers.
- Improve table rendering so object/JSON fields use configured extraction, summaries, expandable details, or hidden columns rather than dumping raw JSON inline.
- Add dashboard layout and label controls for panel placement, size, visual captions, units, thresholds, legends, and per-visual display labels.
- Replace user-facing dashboard UUID URLs with unique short numeric dashboard IDs, and allow optional unique slugs.
- Restore the SDK-built `service-availability-noc` dashboard package as the `/dashboards` default landing target and make dashboard discovery searchable with SRQL.
- Update the `/dashboards` shell so the navbar/header context says "Dashboards" next to the logo and exposes the SRQL input bar for dashboard filtering.

## Impact
- Affected specs: dashboard-creator, srql
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/authored_dashboard_live/**`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/components/srql_components.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/srql/builder.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/dashboards/**`
  - `elixir/serviceradar_core/lib/serviceradar/dashboards/**`
  - `elixir/serviceradar_core/priv/repo/migrations/**`
  - `elixir/web-ng/test/**`
