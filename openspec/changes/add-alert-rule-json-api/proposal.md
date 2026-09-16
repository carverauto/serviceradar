# Expose StatefulAlertRule provisioning over JSON:API

## Why

`add-proxmox-host-outage-alerting` (this session, farm01 control-plane VM
outage follow-up) needed a way to provision alert rules by script/automation
rather than by hand in the UI, and found that no such API exists:
`ServiceRadar.Observability` — the domain that owns `StatefulAlertRule` — is
not mounted on `ServiceRadarWebNGWeb.AshJsonApiRouter` (only `Inventory`,
`Infrastructure`, `Monitoring`, `Notifications` are). That proposal routed
around the gap using the plugin-manifest `alert_rules:` mechanism instead,
but flagged the JSON:API gap as worth its own change. This is that change.

Investigation (background research workflow, this session) found the actual
mechanics are more involved than "add one domain to a list":

- `StatefulAlertRule` is built through a shared macro,
  `ServiceRadar.Observability.PresetRuleResource`
  (`elixir/serviceradar_core/lib/serviceradar/observability/preset_rule_resource.ex`),
  also used by `StatefulAlertRuleTemplate`, `LogPromotionRule`, and
  `LogPromotionRuleTemplate`. The macro's single `use Ash.Resource` call has
  no `extensions:` key, so `AshJsonApi.Resource` — required for any `json_api
  do ... end` block to compile at all — isn't available to any of its four
  callers today. A bare `json_api do end` block typed into
  `stateful_alert_rule.ex` would fail to compile.
- The codebase already has a precedented, safe pattern for this: the sibling
  `ZenPresetResource` macro threads `extra_actions`/`extra_code_interface`/
  `extra_operator_actions` options through `__using__`, defaulting to `[]` so
  only the caller that passes them is affected
  (`zen_preset_resource.ex:16-18`, confirmed by direct read). The same
  technique — extended with a new `extensions:` opt-in — lets
  `stateful_alert_rule.ex` alone gain `AshJsonApi.Resource` and a `:by_id`
  read action, while `StatefulAlertRuleTemplate`/`LogPromotionRule`/
  `LogPromotionRuleTemplate` pass nothing new and are provably unaffected.
- **The bigger finding:** `ServiceRadar.Observability` is not a blank slate.
  19 of its resources already carry complete, dormant, read-only
  `json_api do routes do index :read end end` blocks — `Log`,
  `ServiceStatus`, `CapacityForecast`, `CpuClusterMetric`, four OTel resources
  (`OtelMetric`, `OtelMetricPoint`, `OtelTrace`, `OtelTraceSummary`), and the
  five/six resources built from the shared `RawMetricResource`/
  `HourlyMetricResource` macros. None of them are reachable today only
  because the domain isn't mounted. Ash mounts JSON:API routes per domain
  with no per-resource allowlist (confirmed by reading the installed
  `ash_json_api` dependency's router source), so mounting `Observability` to
  reach `StatefulAlertRule` **simultaneously activates all 19** as a forced
  side effect of the mechanism, not an opt-in choice. This must be an
  explicit, reviewed part of this change, not something discovered after
  merge.
- A **pre-existing, platform-wide gap**: the `:ash_json_api` pipeline never
  enforces OAuth2 scope (`read`/`write`/`admin`/`mcp`) — `RequireOauthScope`
  isn't wired into it, and it never sets the `oauth_token_scope` assign that
  plug reads. Authorization on every `/api/v2/*` route is purely
  `actor.role`-based (`operator`/`admin`/`system`), confirmed end-to-end by
  tracing the bearer-token path from `Guardian.verify_token` through
  `set_ash_actor`. This means a `read`-scoped API client already has the same
  write access as a `write`-scoped one from the same user, for every
  currently-mounted resource. Exposing `StatefulAlertRule` extends this
  existing gap to a security-monitoring-relevant mutation surface (an
  attacker or bug with only a read-scoped token could silently disable an
  alert rule). This is not new to this change and fixing it pipeline-wide is
  a larger, separate effort — flagged here, not fixed here (see Non-Goals).
- `ServiceRadarWebNGWeb.Api.OpenApiV2Controller` (the live, authenticated
  `/api/v2/open_api` document behind SwaggerUI/Redoc) hardcodes its **own**
  `@domains` list rather than reading the router's, and it's already stale —
  missing `Notifications`, which the router does mount. Nothing catches this
  drift today.
- The committed `priv/static/openapi.json` drift check
  (`mix serviceradar.openapi.dump --check`) runs only on a **nightly cron
  against staging** (`buildbuddy.yaml`, `"Elixir Quality (daily)"` job) —
  it is not a PR-blocking CI check. Forgetting to regenerate it after adding
  routes merges cleanly and silently drifts for up to ~24h.

## What Changes

- Add `extensions:`, `extra_actions:`, `extra_code_interface:` opt-in
  parameters to `PresetRuleResource.__using__/1`
  (`preset_rule_resource.ex`), defaulting to `[]`, mirroring
  `ZenPresetResource`'s existing technique. `LogPromotionRule`,
  `StatefulAlertRuleTemplate`, and `LogPromotionRuleTemplate` pass nothing
  new; their macro expansion is unchanged.
- In `stateful_alert_rule.ex` only: pass `extensions: [AshJsonApi.Resource]`
  and an `extra_actions`/`extra_code_interface` pair adding a `:by_id` read
  action (`get? true`, filter by `id`), then add a `json_api do ... end`
  block:
  ```elixir
  json_api do
    type "stateful-alert-rule"
    routes do
      base "/stateful-alert-rules"
      get :by_id
      index :read
      index :active, route: "/active"
      post :create
      patch :update
      delete :destroy
    end
  end
  ```
- Add `ServiceRadar.Observability` to `ash_json_api_router.ex`'s `domains:`
  list; point its moduledoc to the API reference and generated OpenAPI
  inventory for the newly exposed routes.
- Deliberately let all 19 already-declared, dormant, read-only Observability
  resources go live alongside `StatefulAlertRule` (see Why) rather than find
  a way to suppress them. Audit each one's `policy action_type(:read)` block
  first to confirm it correctly scopes by actor rather than defaulting open;
  document the audit result per resource in `tasks.md`.
- Add `ServiceRadar.Observability` to `OpenApiV2Controller`'s hardcoded
  `@domains` list (and note, separately, that it's already missing
  `Notifications` — file that as its own follow-up, do not silently fold an
  unrelated fix into this change).
- Regenerate and commit `priv/static/openapi.json` (`mix
  serviceradar.openapi.dump`) in the same change, since PR CI does not
  enforce this; strengthen the existing `GET /api/v2/open_api` test in
  `ash_json_api_test.exs` to assert the new path appears in
  `response["paths"]` as a same-PR regression guard.
- Tests: extend `ash_json_api_test.exs` with `/api/v2/stateful-alert-rules`
  GET/POST/PATCH/DELETE coverage (mirroring the ServiceCheck/Alert blocks
  already there, including the status-tolerant `[201, 403]`/`[400, 403]`
  assertions this codebase uses for create); add `stateful_alert_rule_fixture/1`
  to `ash_test_helpers.ex`; register `StatefulAlertRule` in
  `policy_test_helpers.ex`'s `create_resource/1`; add an explicit
  operator-can-destroy test (the generic 3-tier RBAC matrix helper assumes
  operator cannot destroy, which is wrong for this resource — do not rely on
  it); add a policy/domain-level test file mirroring
  `service_check_test.exs`; add a regression test asserting
  `AshJsonApi.Resource.Info.routes/1` is `[]` for `StatefulAlertRuleTemplate`,
  `LogPromotionRule`, and `LogPromotionRuleTemplate`.

## Impact

- Affected specs: `alert-rule-json-api` (new capability).
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/observability/preset_rule_resource.ex`
    (macro opt-ins)
  - `elixir/serviceradar_core/lib/serviceradar/observability/stateful_alert_rule.ex`
    (extension + json_api block + `:by_id` action)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/ash_json_api_router.ex`
    (mount + moduledoc)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/open_api_v2_controller.ex`
    (`@domains` list)
  - `elixir/web-ng/priv/static/openapi.json` (regenerated, committed)
  - `elixir/web-ng/test/phoenix/controllers/api/ash_json_api_test.exs`,
    `elixir/web-ng/test/support/ash_test_helpers.ex`,
    `elixir/web-ng/test/support/policy_test_helpers.ex`, and a new
    `elixir/serviceradar_core/test/serviceradar/observability/stateful_alert_rule_test.exs`
    (or wherever the sibling convention for Observability domain tests
    actually lives — confirm before creating)
- **Not** modifying `add-proxmox-host-outage-alerting`'s spec deltas — that
  change already routes around this gap via the plugin-manifest mechanism and
  does not depend on this one landing.
- Known accepted risk, not fixed here: OAuth2 scope is unenforced on
  `/api/v2/*` (see Why); flagged via a GitHub issue, not remediated in this
  change.
- Bonus, intentionally kept rather than worked around: 19 already-declared,
  dormant, read-only Observability resources (logs, OTel traces/metrics,
  capacity forecasts, service status, cluster CPU) go live alongside
  `StatefulAlertRule`, because Ash's JSON:API router mounts per-domain, not
  per-resource. Someone already built and reviewed these `json_api` blocks
  expecting them to eventually be reachable; this change is what finally
  reaches them. Treated as a welcomed part of this change, not a side effect
  to route around — audited (task list) rather than avoided.
