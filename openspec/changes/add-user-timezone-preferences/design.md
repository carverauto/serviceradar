## Context

ServiceRadar stores and transports timestamp instants in UTC. That is the correct invariant for telemetry ingestion, SRQL filtering, correlation, ordering, exports, and APIs, and this change does not alter it.

The interactive web UI does not currently have one presentation contract. Some Phoenix views call `Calendar.strftime/2` directly and append `UTC`; some JavaScript charts call `toISOString()`; some views call `toLocaleString()` or `toLocaleTimeString()` without an explicit timezone; and the existing `LocalTime` hook uses the browser's local timezone instead of a saved user preference. There are timestamp formatters spread across observability, NetFlow, device, dashboard, admin, audit, and settings modules.

The BEAM applications intentionally do not ship `tzdata` or another IANA timezone database. Notification schedule code already validates and converts zones through PostgreSQL's `pg_timezone_names` catalog and `AT TIME ZONE`. Performing a database query for every rendered timestamp would be too expensive, while adding a second independently updated timezone database solely for UI presentation would duplicate infrastructure.

This proposal therefore separates rare preference validation from frequent display formatting: PostgreSQL validates a saved IANA identifier, while the browser formats canonical instants with `Intl.DateTimeFormat` and an explicit `timeZone` option.

## Goals / Non-Goals

### Goals

- Let each authenticated user select and persist an IANA timezone.
- Render all human-visible absolute timestamps in the interactive web UI using that preference.
- Handle daylight-saving transitions using the browser's installed IANA rules.
- Replace fragmented UI formatting with a reusable, testable contract.
- Keep the original UTC instant available for accessibility, support, and copying.
- Preserve every existing UTC storage, query, correlation, API, and export invariant.

### Non-Goals

- Reinterpreting source timestamps that arrived without timezone context.
- Changing ingestion, database column types, event ordering, or effective log timestamp selection.
- Changing SRQL syntax, relative windows, absolute query bounds, or chart selection payloads.
- Localizing REST/JSON responses, CSV/downloadable exports, cold-tier data, notifications, reports, or schedule evaluation.
- Adding locale, date-format, or 12/24-hour preferences beyond the browser locale used by `Intl`.
- Broadcasting a changed preference into every already-open browser tab without a reload.
- Adding a BEAM timezone database dependency.

## Decisions

### Persist one timezone on the user resource

Add a public, non-null `timezone` string attribute to `ServiceRadar.Identity.User`, backed by `platform.ng_users.timezone`, with a default and migration backfill of `Etc/UTC`.

Do not add the field to the existing generic `:update` action. That action also authorizes actors with `settings.auth.manage` and is used by admin user management. Add a dedicated `:update_timezone_preference` action that accepts only `timezone` and has a self-targeting policy with no user-management override. The resource's existing system-actor bypass remains available for internal migration and repair operations, but product administrators cannot set another user's display preference.

The authenticated scope already contains the loaded user resource, so the preference does not belong in JWT claims or separate session state. New HTTP requests and LiveView mounts load the current value through Guardian's existing user lookup. A successful profile submit replaces the current socket's user with the returned resource so the setting takes effect on that view immediately. Other open tabs use the new value after their next reload or mount.

### Share the existing PostgreSQL timezone catalog

Introduce a neutral `ServiceRadar.TimeZone` module and make `ServiceRadar.Notifications.TimeZone` delegate its existing generic behavior to it. The neutral module SHALL parameterize catalog queries and expose separate profile-preference operations:

- `profile_timezones/0` returns a finite, sorted server catalog consisting of `Etc/UTC` plus IANA area/location identifiers from `pg_timezone_names`. The query excludes abbreviations, POSIX-prefixed entries, and the fixed-offset `Etc/GMT+<n>` / `Etc/GMT-<n>` family (while retaining the exact identifier `Etc/UTC`);
- `normalize_preference/1` trims input and maps accepted UTC aliases (`UTC`, `GMT`, `Etc/GMT`, `Z`, `Zulu`, and existing case variants) to the sole persisted UTC value `Etc/UTC`; and
- preference validation accepts only a normalized value present in `profile_timezones/0`.

IANA link identifiers containing an area/location separator remain valid profile values when PostgreSQL includes them; the contract does not claim to rewrite every historical IANA link to its current canonical target. Blank values, abbreviations, fixed-offset strings (including direct submissions such as `Etc/GMT+5`), and names outside the filtered profile catalog are rejected.

The profile form SHALL load the bounded server catalog once per mount. Its JavaScript control SHALL retain `Etc/UTC` and the current saved value, then filter the remaining choices by attempting `Intl.DateTimeFormat` construction with each zone. `Intl.supportedValuesOf("timeZone")` may accelerate that intersection when available but is not the sole capability test. If `Intl` is unavailable, the control SHALL preserve the current value and offer `Etc/UTC`; normal rendering continues to use the UTC fallback.

Browser capability is a selector concern, not a server security claim: a direct client may submit only a normalized member of the server profile catalog, and a particular outdated browser may still fall back to UTC if it cannot format that valid saved zone. The update action SHALL reject invalid identifiers even if a client bypasses the form. Catalog-query or validation failures SHALL leave the previous preference unchanged and return a form error.

Catalog loading and validation happen only while mounting or submitting the relatively infrequent profile form, never once per rendered timestamp. The initial implementation does not add a process or long-lived cache solely for this finite query.

### Render through one canonical HTML and JavaScript contract

Add a shared Phoenix function component and one external JavaScript hook/utility for absolute timestamps. Each rendered timestamp SHALL carry:

- a canonical UTC ISO-8601 instant in a semantic `<time datetime="...">` value;
- the saved IANA timezone and a named display style in data attributes or equivalent chart configuration;
- deterministic UTC fallback text produced by the server; and
- an accessible title or copy value containing the original UTC instant and selected timezone.

The hook SHALL call `Intl.DateTimeFormat` with the browser locale and explicit saved timezone. It SHALL support the small set of display styles needed by existing surfaces, such as full date-time, compact date-time, date only, and time only, instead of allowing each caller to supply arbitrary formatting logic. Full date-time values and tooltips SHALL include an unambiguous numeric offset through `timeZoneName: "shortOffset"` (with a tested compatible fallback); compact chart axes may omit the offset only when their corresponding tooltip or accessible value includes it. The hook SHALL reformat after LiveView DOM updates.

JavaScript chart renderers SHALL use the same formatter utility for human-visible axes and tooltips. They SHALL continue to use epoch or UTC ISO values for scales, point identity, selection, and events.

If the instant is invalid, the timezone is unsupported, or `Intl` is unavailable, the formatter SHALL retain the canonical UTC fallback rather than rendering blank or silently using the browser's implicit timezone.

### Localize presentation, never the underlying instant

Localization SHALL occur only at the last human-visible rendering boundary. The following remain canonical UTC and MUST NOT pass through the localized display formatter:

- database values and telemetry payloads;
- SRQL expressions, filtering, ordering, and pivots;
- URL parameters and LiveView event payloads containing time bounds;
- chart scale inputs and selected bucket boundaries;
- REST/JSON serialization;
- CSV and other downloadable exports;
- notification, report, and schedule evaluation; and
- cold-tier storage.

Relative durations such as "5 minutes ago" do not represent a wall-clock timezone and may continue to use their existing formatter.

### Migrate all interactive UI surfaces under the shared contract

Before migration, the implementation SHALL add a checked-in inventory that classifies every direct timestamp-formatting call site under `elixir/web-ng` as localized human display, canonical machine serialization/calculation, relative time, or a documented fixed-UTC exception. The inventory is the bounded acceptance artifact for the repository-wide UI scope.

The implementation SHALL first establish the component and formatter, then migrate representative high-value telemetry surfaces: log list/detail, syslog, SNMP traps, OTEL logs, events, alerts, metrics, traces, NetFlow explorer/detail, and NetFlow chart labels/tooltips. It SHALL then migrate every call site classified as human display across dashboards, device/inventory, topology, admin, audit, and settings views.

Direct `Calendar.strftime/2`, `DateTime.to_iso8601/1`, `toISOString()`, and implicit `toLocale*()` calls remain valid for canonical serialization or non-display calculations. A Bazel-backed source audit test SHALL fail when a new direct call is not classified in the inventory. Human-visible absolute timestamps SHALL use the shared contract unless the inventory documents why a fixed UTC presentation is required. The guard SHALL be implemented as a normal test target, not a shell script.

### Keep concurrent OpenSpec work composable

- The current profile route already renders inside `Settings.ShellHook` and `Shell.settings_chrome`; implementation SHALL extend that path rather than create a second route or scope mechanism. If `redesign-settings-catalog-nav` lands its planned `settings_ui` preference first, implementation SHALL rebase and combine compatible `ng_users` edits and verify the profile control under both original and catalog chrome modes.
- `refactor-otel-signal-correlation` modifies OTEL visibility and correlation requirements. This proposal adds a separate display requirement and SHALL not replace or weaken that change's full modified requirement.
- `add-netflow-chart-range-selection` relies on exact canonical bucket boundaries. Localized labels SHALL not alter the UTC bounds sent back to the server.
- `improve-syslog-ingestion-fidelity` owns source timestamp parsing. The user display preference SHALL not reinterpret source timestamps or change effective timestamp selection.

## Risks / Trade-offs

- Browser and PostgreSQL timezone catalogs can differ slightly by version. The server owns the persisted profile catalog, the selector capability-filters choices for the current browser, and rendering falls back to UTC if a valid saved zone is unsupported by an older browser.
- Client-side formatting means the disconnected or JavaScript-failed render initially shows UTC. That is an intentional correct fallback rather than an incorrect inferred local time.
- Migrating every UI timestamp is broad and may expose hidden one-off formatting. The checked inventory bounds completion, the source audit test catches unclassified new calls, and the shared component prevents new divergence.
- Updating the preference does not push state into already-open tabs. Reloading is predictable and avoids adding cross-tab or PubSub state solely for a display preference.
- Timezone abbreviations can be ambiguous. The semantic UTC value and title/copy representation retain the exact instant and full IANA zone.

## Migration Plan

1. Add and backfill `platform.ng_users.timezone` to `Etc/UTC`, then expose it on the Ash user resource and self-service update action.
2. Introduce shared normalized timezone catalog validation while preserving notification scheduling behavior.
3. Add the profile control and shared rendering component/formatter with UTC fallback.
4. Create the checked call-site inventory and regression guard, migrate telemetry and NetFlow surfaces, then migrate every remaining interactive human-display entry.
5. Verify canonical UTC behavior for queries, APIs, exports, and chart range payloads before rollout.

Rollback removes localized rendering first, which returns every surface to its UTC fallback without data loss. The stored preference column can remain inert during rollback; dropping it requires a later explicit migration.

## Open Questions

None for proposal approval. The product boundary is explicitly the interactive web UI; machine interfaces, exports, and scheduling remain UTC.
