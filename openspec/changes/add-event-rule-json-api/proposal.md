# Expose EventRule (log-to-event promotion rules) over JSON:API

## Why

`EventRule` — the resource that defines which log patterns are promoted to
OCSF events (`ServiceRadar.Observability.EventRule`,
`elixir/serviceradar_core/lib/serviceradar/observability/event_rule.ex`) —
can only be managed today through the Settings → Events UI. An external
application that ships OTel error logs wants to manage promotion rules
programmatically at deploy time without human UI interaction. No such API
exists: the resource has no `AshJsonApi.Resource` extension and no
`json_api` block.

`ServiceRadar.Observability` is already mounted on
`ServiceRadarWebNGWeb.AshJsonApiRouter` (added in `add-alert-rule-json-api`),
so adding `AshJsonApi.Resource` plus a `json_api` block to `EventRule` is
sufficient — no router change is needed.

## What Changes

- `event_rule.ex`: add `extensions: [AshJsonApi.Resource]` to
  `use Ash.Resource`; add a `:by_id` read action (`argument :id, :uuid,
  allow_nil?: false; get? true; filter expr(id == ^arg(:id))`); add a
  `code_interface define` for `:get_by_id`; add a `json_api do end` block
  with `type "event-rule"`, `base "/event-rules"`, routes `get :by_id`,
  `index :read`, `index :active, route: "/active"`, `post :create`,
  `patch :update`, `delete :destroy`.
- No router change: `ServiceRadar.Observability` is already mounted.
- Regenerate `priv/static/openapi.json` (`mix serviceradar.openapi.dump`).
- Tests: extend `ash_json_api_test.exs` with `/api/v2/event-rules` GET/
  POST/PATCH/DELETE coverage; add `event_rule_fixture/1` to
  `ash_test_helpers.ex`; add one test confirming a rule created via the API
  is visible to `LogPromotion.active_log_rules/0`.

## Impact

- Affected specs: `event-rule-json-api` (new capability).
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/observability/event_rule.ex`
  - `elixir/web-ng/priv/static/openapi.json` (regenerated)
  - `elixir/web-ng/test/phoenix/controllers/api/ash_json_api_test.exs`
  - `elixir/web-ng/test/support/ash_test_helpers.ex`
- No migration needed: no schema change.
- No router change needed.
- Known accepted risk (pre-existing, tracked in issue #329): OAuth2 scope
  is unenforced on `/api/v2/*`; authorization is role-based. This change
  extends that existing surface to `EventRule` mutations. Out of scope here.
