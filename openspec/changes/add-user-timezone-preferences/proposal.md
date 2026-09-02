# Change: Add user-selected timezone rendering to the web UI

## Why

[GitHub issue #3555](https://github.com/carverauto/serviceradar/issues/3555) asks for each signed-in user to choose a local timezone and see UTC timestamps in that timezone. ServiceRadar already preserves canonical UTC instants, but the web UI currently mixes hard-coded UTC strings, the browser's implicit local timezone, and raw ISO values. The same user can therefore see inconsistent times across logs, traps, OTEL views, NetFlow, charts, and settings pages.

## What Changes

- Persist a normalized IANA timezone preference on each user, defaulting existing and new users to `Etc/UTC`.
- Add a self-service-only timezone update action and selector to the existing authenticated profile settings page.
- Reuse a filtered PostgreSQL IANA timezone catalog for server-side validation, normalize UTC aliases to `Etc/UTC`, and filter selector choices against browser `Intl` support rather than adding a second BEAM timezone database.
- Introduce one shared web timestamp rendering contract based on canonical UTC ISO input and browser `Intl.DateTimeFormat` output with the user's explicitly selected timezone.
- Extend plugin display-contract fields and columns with optional `timestamp` / `unix_nano` presentation hints, and bump the affected display-contract and add-on package versions. This is an additive UI-rendering change only: payload schemas, field values, and event semantics remain unchanged.
- Apply that contract to every human-visible absolute timestamp in the interactive web UI, including logs, syslog, SNMP traps, OTEL logs, events, alerts, metrics, traces, NetFlow tables, chart axes, chart tooltips, dashboards, inventory, and settings surfaces.
- Preserve canonical UTC values for storage, ingestion, ordering, SRQL filters, URL/query bounds, chart selection, REST/JSON responses, CSV and other exports, notification delivery, and schedule evaluation.
- Preserve the original UTC instant in machine-readable HTML and an accessible title or copy value, and fall back visibly to UTC if browser localization is unavailable.
- Add a checked call-site inventory and regression guard so every direct timestamp formatter is classified as localized display, canonical machine use, relative time, or an intentional fixed-UTC exception.
- Add persistence, self-only authorization, repeated-hour DST, formatter fallback, representative surface, and UTC-invariant regression coverage.

## Impact

- Affected specs: `user-preferences` (new), `build-web-ui`, `observability-signals`, `observability-netflow`
- Affected data model: `platform.ng_users` and `ServiceRadar.Identity.User`
- Affected code: shared core timezone catalog/validation, authenticated profile settings, shared Phoenix timestamp component and JavaScript hook, chart formatters, timestamp-bearing `elixir/web-ng` views, the plugin display-contract validator, and affected add-on/plugin display manifests and package versions
- External dependencies: none; the design uses PostgreSQL's existing timezone catalog and browser `Intl`
- Coordination: implementation must reconcile the concurrent `redesign-settings-catalog-nav` user-resource and profile-shell work, preserve the complete timestamp behavior in `refactor-otel-signal-correlation` and `improve-syslog-ingestion-fidelity`, and leave `add-netflow-chart-range-selection` canonical range bounds unchanged
