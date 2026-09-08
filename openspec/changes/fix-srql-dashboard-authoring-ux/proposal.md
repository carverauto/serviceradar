# Fix SRQL and Dashboard Authoring UX

## Why

Recent dashboard and SRQL editor changes made common workflows feel broken:

- SRQL topbar inputs behave like embedded code editors and can lose normal caret/edit behavior.
- The dashboard creator allows panel actions before a dashboard exists.
- Panel configuration exposes raw JSON fields instead of guided controls.
- Visualization choices are not clearly driven by the SRQL query output schema.
- A rendered table panel on `/dashboard/1000001` has a broken/unusable control.

These issues make dashboard creation a guessing process instead of an iterative workflow.

## What Changes

This change has two layers:

1. Stabilize the broken workflows immediately so users can edit SRQL normally, create dashboards safely, and add panels without raw JSON or invalid visual choices.
2. Establish the query-first dashboard builder model described in `dashboard-builder-redesign.md`: data first, outputs second, layout third.

- Use normal form inputs for compact SRQL search/filter bars across the product.
- Keep rich Monaco-backed SRQL editing opt-in for dashboard panel query authoring.
- Make `/analytics` create dashboard metadata only: title, description, and visibility.
- Move panel composition to saved dashboard settings where a dashboard identity already exists.
- Make panel authoring schema-guided: run/preview SRQL first, then constrain visualization and binding choices to compatible options.
- Replace raw panel JSON textareas with structured controls for data bindings, display options, visual options, and layout.
- Fix rendered dashboard panel controls so table/dropdown interactions are clickable and keyboard accessible.
- Define the next dashboard builder shape around reusable source queries and multiple outputs per query, so one SRQL result can produce several panels without duplicating the query.
- Treat visualization selection as user intent backed by schema constraints, not a free-form visual dropdown that can create impossible bindings.
- Add Armis-style metric/gauge dashlet support: panel action menus, comparison lookback settings, and trend direction/copy that can be driven by SRQL `stats:` or `bucket:` queries.
- Add Playwright regression coverage for SRQL input editing, metadata-only dashboard creation, panel authoring, and rendered dashboard panel controls.

## Impact

- Affected specs: `srql`, `dashboard-authoring`
- Affected code: `elixir/web-ng` LiveView dashboard pages, SRQL components, React dashboard canvas/editor components, Monaco SRQL integration, Playwright checks.
- Validation: compile web-ng, run asset checks, start local `mix phx.server` against demo CNPG, and exercise workflows with Playwright.
