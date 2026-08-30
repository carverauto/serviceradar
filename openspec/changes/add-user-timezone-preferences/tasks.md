## 1. User Preference and Validation

- [ ] 1.1 Introduce neutral `ServiceRadar.TimeZone` catalog/validation functions backed by PostgreSQL, delegate existing notification behavior to them, and preserve notification scheduling with focused tests.
- [ ] 1.2 Add a generated migration and resource snapshot/baseline updates for non-null `platform.ng_users.timezone` with default/backfill `Etc/UTC`.
- [ ] 1.3 Implement a finite profile catalog, trim inputs, normalize accepted UTC aliases to `Etc/UTC`, and reject abbreviations, POSIX entries, fixed offsets (including `Etc/GMT+<n>` / `Etc/GMT-<n>` catalog names), blank values, and names outside the profile catalog while retaining `Etc/UTC`.
- [ ] 1.4 Add the public `timezone` attribute to `ServiceRadar.Identity.User` and a dedicated `:update_timezone_preference` action/policy that accepts only the timezone and denies cross-user updates even to product administrators with `settings.auth.manage`.
- [ ] 1.5 Add DB-backed migration/resource/action tests for the UTC default/backfill, normalization, valid direct Ash update, invalid direct updates including `Etc/GMT+5`, catalog-query failure preserving the prior value, and self-only authorization.
- [ ] 1.6 Rebase and reconcile the user-resource/profile-shell edits with active `redesign-settings-catalog-nav` work before implementation is merged.

## 2. Profile Settings

- [ ] 2.1 Add a bounded server catalog listing and searchable timezone control to the existing authenticated `/settings/profile` catalog-shell LiveView; retain `Etc/UTC` and the saved value, and capability-filter other choices using browser `Intl` with and without `supportedValuesOf`.
- [ ] 2.2 Submit the timezone through an AshPhoenix form with `current_scope`, show validation failures inline, and replace the current socket's user with the successful update result.
- [ ] 2.3 Extend profile LiveView and JavaScript control tests for catalog intersection/fallback, rendering, validation, persistence across a fresh authenticated mount, and immediate use on the current page.
- [ ] 2.4 Verify the profile control in the current catalog shell and, if the active settings toggle has landed, under both original and catalog chrome modes.

## 3. Shared Timestamp Rendering

- [ ] 3.1 Add a shared semantic Phoenix `<time>` component with canonical UTC ISO input, explicit timezone/style metadata, deterministic UTC fallback, and accessible original-value and numeric-offset text.
- [ ] 3.2 Replace the duplicate/global local-time hooks with one external formatter based on `Intl.DateTimeFormat` and the saved timezone; support LiveView updates without implicit browser-zone fallback.
- [ ] 3.3 Add JavaScript formatter tests covering named styles, invalid values, unsupported zones, missing `Intl`, and both sides of the repeated autumn hour and spring DST transition in `America/Chicago`.
- [ ] 3.4 Expose the same formatter contract to chart axes and tooltips while retaining UTC/epoch scale and event values.

## 4. Interactive Web UI Coverage

- [ ] 4.1 Create a checked-in inventory classifying every direct `web-ng` timestamp-formatting call site as localized display, canonical machine use, relative time, or documented fixed-UTC exception.
- [ ] 4.2 Add a Bazel-backed source audit test that fails on unclassified new direct timestamp formatters without adding a shell script.
- [ ] 4.3 Migrate log list/detail, syslog, SNMP trap, OTEL log, event, and alert absolute timestamps to the shared renderer.
- [ ] 4.4 Migrate metric, trace, SRQL result, and correlated observability absolute timestamps while preserving existing UTC pivots and filters.
- [ ] 4.5 Migrate NetFlow explorer rows, detail surfaces, time-window labels, chart axes, and chart tooltips while preserving exact canonical range-selection bounds.
- [ ] 4.6 Migrate every remaining inventory entry classified as human display across dashboards, device/inventory, topology, admin, audit, and settings views; review each fixed-UTC exception.
- [ ] 4.7 Ensure relative durations continue to behave as durations and original UTC instants remain accessible for support and copying.

## 5. Coordination and Verification

- [ ] 5.1 Rebase and reconcile the complete active deltas from `refactor-otel-signal-correlation` and `improve-syslog-ingestion-fidelity`, preserving correlation pivots, effective timestamp selection, source-time parsing, and no-zone behavior.
- [ ] 5.2 Reconcile `add-netflow-chart-range-selection` and `improve-attributed-flow-investigation` call sites while preserving canonical bucket and flow timestamps.
- [ ] 5.3 Add representative LiveView/HTML tests asserting localized display metadata and canonical UTC `<time datetime>` values on observability, NetFlow, and non-telemetry surfaces.
- [ ] 5.4 Add regression tests proving SRQL ranges, URL parameters, chart selection events, REST/JSON responses, CSV/downloadable exports, notifications, and schedule evaluation remain canonical UTC.
- [ ] 5.5 Run formatting and focused Elixir/JavaScript/Bazel tests for all touched modules and confirm each newly added test actually executes.
- [ ] 5.6 Run `mix precommit` for `elixir/web-ng` and the repository's full `make test` contract before opening the implementation pull request.
