## 1. Read API
- [ ] 1.1 Add `GET /api/v1/dashboard-packages` and `GET /api/v1/dashboard-packages/:id` in `router.ex`, in a scope gated by `:api_key_auth` WITHOUT `:require_dashboard_publish_scope` — that pipeline demands a CLI publish-scoped token, which a read caller does not have.
- [ ] 1.2 Add a read controller alongside `DashboardPackagePublishController`, reusing its per-action RBAC helper shape. Gate on the existing `dashboards.packages.view_all`.
- [ ] 1.3 Resolve `:id` as the MANIFEST id first, via the existing `:by_dashboard_id` read action, falling back to the instance-internal id so the identifier the publish response returns also resolves. Manifest-id addressing is the gap that made every probe 404.
- [ ] 1.4 Join the instance's `route_slug` and `enabled` where an instance exists; report the package plainly when none does.
- [ ] 1.5 Exclude `signature`, `settings_schema` and `wasm_object_key` from the response. A version endpoint must not leak signing material or storage layout.
- [ ] 1.6 Return a 404 that is distinguishable from a missing route — a structured body saying the package is not installed.

## 2. CLI
- [ ] 2.1 `serviceradar-cli dashboard list --instance <url>` — manifest id, version, route, enabled, one row per package.
- [ ] 2.2 `serviceradar-cli dashboard status --instance <url>` — read the project's `dashboard.config.mjs`, query the instance for that manifest id, and state whether local and installed versions differ.
- [ ] 2.3 `doctor` reports the installed version for the current project's manifest id when an instance is configured, next to the SDK and CLI versions it already prints.
- [ ] 2.4 Handle "not installed" as information, not an error: exit non-zero only for a real failure (auth, transport), not for a project that simply has not been published.
- [ ] 2.5 Update `cli.ts` help text and `js/cli/CHANGELOG.md`.

## 3. web-ng UI
- [ ] 3.1 Surface version and `content_hash` in the dashboard packages administration view, alongside the route and enabled state already shown.
- [ ] 3.2 Confirm the view is reachable by someone holding `dashboards.packages.view_all` and no publish permission.

## 4. Tests
- [ ] 4.1 Index returns installed packages with manifest id, version and enabled state.
- [ ] 4.2 Show resolves by manifest id.
- [ ] 4.3 Show resolves by instance-internal id too.
- [ ] 4.4 A caller with `dashboards.packages.view_all` and no publish permission succeeds.
- [ ] 4.5 A caller lacking `dashboards.packages.view_all` is refused.
- [ ] 4.6 The response omits `signature`, `settings_schema` and `wasm_object_key` — assert absence explicitly, since this is a security property.
- [ ] 4.7 An uninstalled id returns the structured not-installed body, not a bare 404.
- [ ] 4.8 CLI: `list` renders rows from a canned response; `status` reports match and mismatch; not-installed exits zero. Use the existing black-box harness in `js/cli/tests/publish-errors.test.mjs` (canned HTTP server, real CLI subprocess, assert printed output) rather than adding a new idiom.
- [ ] 4.9 Note which suites need a database and which are db-free, and record what was actually run.

## 5. Verification
- [ ] 5.1 `mix compile --warnings-as-errors` clean; `scripts/elixir_quality.sh --project elixir/web-ng --phoenix --lint-only` exits 0 (this is the real CI gate — format AND Credo).
- [ ] 5.2 `js/cli` `npm run ci` exits 0.
- [ ] 5.3 If any new `DateTime.to_iso8601` call site appears, register it in `test/fixtures/timestamp_formatter_inventory.json`; get fingerprints from the inventory test's own discovery, not by hand.
- [ ] 5.4 Exercise against the live instance: confirm `GET /api/v1/dashboard-packages` reports the deployed dashboard package at the version actually installed, which is the case that could not be answered at all before.

## 6. Hand-off
- [ ] 6.1 Record that no version history is available — the resource holds the current row per package, so the API reports now, not a timeline.
- [ ] 6.2 Record that the CLI cannot publish `0.1.8` until the npm trusted publisher is configured (issue #4571), so any CLI change here ships on the next release rather than immediately.
