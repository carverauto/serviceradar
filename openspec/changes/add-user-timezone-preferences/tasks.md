## 1. User Preference and Validation

- [x] 1.1 Introduce neutral `ServiceRadar.TimeZone` catalog/validation functions backed by PostgreSQL, delegate existing notification behavior to them, and preserve notification scheduling with focused tests.
- [x] 1.2 Add a generated migration and resource snapshot/baseline updates for non-null `platform.ng_users.timezone` with default/backfill `Etc/UTC`.
- [x] 1.3 Implement a finite profile catalog, trim inputs, normalize accepted UTC aliases to `Etc/UTC`, and reject abbreviations, POSIX entries, fixed offsets (including `Etc/GMT+<n>` / `Etc/GMT-<n>` catalog names), blank values, and names outside the profile catalog while retaining `Etc/UTC`.
- [x] 1.4 Add the public `timezone` attribute to `ServiceRadar.Identity.User` and a dedicated `:update_timezone_preference` action/policy that accepts only the timezone and denies cross-user updates even to product administrators with `settings.auth.manage`.
- [x] 1.5 Add DB-backed migration/resource/action tests for the UTC default/backfill, normalization, valid direct Ash update, invalid direct updates including `Etc/GMT+5`, catalog-query failure preserving the prior value, and self-only authorization.
- [x] 1.6 Rebase and reconcile the user-resource/profile-shell edits with active `redesign-settings-catalog-nav` work before implementation is merged.

## 2. Profile Settings

- [x] 2.1 Add a bounded server catalog listing and searchable timezone control to the existing authenticated `/settings/profile` catalog-shell LiveView; retain `Etc/UTC` and the saved value, and capability-filter other choices using browser `Intl` with and without `supportedValuesOf`.
- [x] 2.2 Submit the timezone through an AshPhoenix form with `current_scope`, show validation failures inline, and replace the current socket's user with the successful update result.
- [x] 2.3 Extend profile LiveView and JavaScript control tests for catalog intersection/fallback, rendering, validation, persistence across a fresh authenticated mount, and immediate use on the current page.
- [x] 2.4 Verify the profile control in the current catalog shell and, if the active settings toggle has landed, under both original and catalog chrome modes.

## 3. Shared Timestamp Rendering

- [x] 3.1 Add a shared semantic Phoenix `<time>` component with canonical UTC ISO input, explicit timezone/style metadata, deterministic UTC fallback, and accessible original-value and numeric-offset text.
- [x] 3.2 Replace the duplicate/global local-time hooks with one external formatter based on `Intl.DateTimeFormat` and the saved timezone; support LiveView updates without implicit browser-zone fallback.
- [x] 3.3 Add JavaScript formatter tests covering named styles, invalid values, unsupported zones, missing `Intl`, and both sides of the repeated autumn hour and spring DST transition in `America/Chicago`.
- [x] 3.4 Expose the same formatter contract to chart axes and tooltips while retaining UTC/epoch scale and event values.

## 4. Interactive Web UI Coverage

- [x] 4.1 Create a checked-in inventory classifying every direct `web-ng` timestamp-formatting call site as localized display, canonical machine use, relative time, or documented fixed-UTC exception.
- [x] 4.2 Add a Bazel-backed source audit test that fails on unclassified new direct timestamp formatters without adding a shell script.
- [x] 4.3 Migrate log list/detail, syslog, SNMP trap, OTEL log, event, and alert absolute timestamps to the shared renderer.
- [x] 4.4 Migrate metric, trace, SRQL result, and correlated observability absolute timestamps while preserving existing UTC pivots and filters.
- [x] 4.5 Migrate NetFlow explorer rows, detail surfaces, time-window labels, chart axes, and chart tooltips while preserving exact canonical range-selection bounds.
- [x] 4.6 Migrate every remaining inventory entry classified as human display across dashboards, device/inventory, topology, admin, audit, and settings views; review each fixed-UTC exception.
- [x] 4.7 Ensure relative durations continue to behave as durations and original UTC instants remain accessible for support and copying.

## 5. Coordination and Verification

- [x] 5.1 Rebase and reconcile the complete active deltas from `refactor-otel-signal-correlation` and `improve-syslog-ingestion-fidelity`, preserving correlation pivots, effective timestamp selection, source-time parsing, and no-zone behavior.
- [x] 5.2 Reconcile `add-netflow-chart-range-selection` and `improve-attributed-flow-investigation` call sites while preserving canonical bucket and flow timestamps.
- [x] 5.3 Add representative LiveView/HTML tests asserting localized display metadata and canonical UTC `<time datetime>` values on observability, NetFlow, and non-telemetry surfaces.
- [x] 5.4 Add regression tests proving SRQL ranges, URL parameters, chart selection events, REST/JSON responses, CSV/downloadable exports, notifications, and schedule evaluation remain canonical UTC.
- [x] 5.5 Run formatting and focused Elixir/JavaScript/Bazel tests for all touched modules and confirm each newly added test actually executes.
- [x] 5.6 Run `mix precommit` for `elixir/web-ng` and the repository's full `make test` contract before opening the implementation pull request.

## Verification Evidence

- 2026-08-31: `mix format --check-formatted`, `git diff --check`, JSON validation, and `openspec validate add-user-timezone-preferences --strict` passed after the final UI audit fixes.
- 2026-08-31: focused browser timestamp/range tests passed in BuildBuddy invocation `16a9d518-c419-47be-8594-72f3aca13b8f`; the final combined timestamp, God View, Phoenix component, and signal-display regression set passed in `39f71a15-fe17-462f-ae07-2150bc383a5a`. The production `//elixir/web-ng/assets:god_view_elk_scene_bundle` target also built successfully. The independent-review follow-up for parent-template timezone forwarding passed in `c96c0a9d-4f45-4dd1-9111-7cc8f0114dcf`.
- 2026-08-31: the guarded shared-fixture selection ran exactly 56 DB-backed cases with 0 failures and 272 excluded cases. Its disposable database was dropped, and an independent `pg_database` query found 0 remaining `codex_tz3555%` databases.
- 2026-08-31: the DB-runner and formatter-inventory guards passed in BuildBuddy invocation `2406c32d-2e90-4afd-8271-b94691812306`.
- 2026-08-31: after a conflict-free rebase onto current `origin/staging` (`57e849b8ae16cb7143e7e5bd8e589aff6822d0db`), the repository `make test` contract passed all 210 test targets at feature commit `4265064de4` in BuildBuddy invocation `b34a5bbb-863d-4a04-95c1-960dadbf6835`.
- 2026-08-31: `mix precommit` was run and stopped only on four pre-existing Boundary warnings in `mcp/oauth/idp.ex`, `mcp/oauth/idp_session.ex`, and `mcp/oauth/server.ex`; all three files are unchanged from `origin/staging`. Formatting and the full Bazel test contract passed independently above.
