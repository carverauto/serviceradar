## 1. EventRule JSON:API

- [x] 1.1 Added `extensions: [AshJsonApi.Resource]` to `use Ash.Resource` in
      `event_rule.ex`.
- [x] 1.2 Added `:by_id` read action (`argument :id, :uuid; get? true; filter
      expr(id == ^arg(:id))`) and `define :get_by_id` to `code_interface`.
- [x] 1.3 Added `json_api do end` block: `type "event-rule"`,
      `base "/event-rules"`, routes `get :by_id`, `index :read`,
      `index :active, route: "/active"`, `post :create`, `patch :update`,
      `delete :destroy`.
- [x] 1.4 No router change needed: `ServiceRadar.Observability` is already
      mounted on `AshJsonApiRouter`.
- [x] 1.5 Regenerated `priv/static/openapi.json` via
      `mix serviceradar.openapi.dump`.

## 2. Tests

- [x] 2.1 Added `event_rule_fixture/1` to
      `elixir/web-ng/test/support/ash_test_helpers.ex`, mirroring
      `stateful_alert_rule_fixture/1`.
- [x] 2.2 Extended `ash_json_api_test.exs` with describe blocks for
      `GET /api/v2/event-rules`, `GET /api/v2/event-rules/active`,
      `POST /api/v2/event-rules` (operator lifecycle + viewer denied + unauth
      denied), `PATCH /api/v2/event-rules/:id`, `DELETE /api/v2/event-rules/:id`
      (non-existent + operator-can-destroy), and a log-promotion integration
      test confirming a rule created via the API is visible to
      `LogPromotion.active_log_rules/0`.
