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

## Inherited OpenAPI Reconciliation

The complete regeneration also reconciles 43 non-EventRule semantic differences
with the resource DSL already present at the intended base,
`a5644da9a221453eed1bdb0330f95b14fed02ca1`. These changes are included explicitly
so `mix serviceradar.openapi.dump --check` continues to validate the complete
artifact. This proposal does not change those resources or their runtime behavior.
All paths below are router-relative under `/api/v2`.

| Existing API surface | Regenerated contract | Semantic differences |
| --- | --- | --- |
| `device_cleanup_settings` resource and filters | Add `ephemeral_expiry_enabled`, `ephemeral_expiry_days`, `ephemeral_expiry_exclusion_query`, `ephemeral_expiry_max_fraction`, and `ephemeral_expiry_guard_override` to the attribute schema and filter schema; add each field's filter definition. The resource's required-attribute list now also includes the four non-null fields (all except `ephemeral_expiry_exclusion_query`). | 16 |
| `/device-cleanup-settings` GET/POST and `/device-cleanup-settings/{id}` PATCH | Add those five fields to POST and PATCH request attributes; update the sparse-field examples on all three operations to include them. | 13 |
| `/timeseries_metrics_disk_hourly` GET | Document the existing read-only hourly disk-metric endpoint, its resource schema, filter schema, and ten field-filter definitions: `avg_value`, `bucket`, `device_id`, `max_value`, `metric_name`, `metric_type`, `min_value`, `mount_point`, `sample_count`, and `series_key`. | 13 |
| `/devices` GET | Correct the pagination `page.limit` example from `5000` to `250`, reflecting the existing resource DSL. This is an example correction, not a new pagination limit. | 1 |

The reconciliation accounts for all 43 inherited differences separately from the
three EventRule paths and ten EventRule schemas introduced by this feature.
