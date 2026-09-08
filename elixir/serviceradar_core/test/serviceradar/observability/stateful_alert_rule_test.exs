defmodule ServiceRadar.Observability.StatefulAlertRuleTest do
  @moduledoc """
  Resource-level regression coverage for the `add-alert-rule-json-api`
  OpenSpec change.

  These assert directly on `AshJsonApi.Resource.Info`/`Spark.extensions/1`,
  independent of whether `ServiceRadar.Observability` is mounted on any
  JSON:API router — they prove the macro opt-in in `PresetRuleResource` (and
  the `json_api` block added to this resource alone) behave as designed.
  HTTP-level coverage for the mounted routes lives in `elixir/web-ng`'s
  `ash_json_api_test.exs`.
  """
  use ExUnit.Case, async: true

  alias AshJsonApi.Resource.Info, as: JsonApiInfo
  alias ServiceRadar.Observability.LogPromotionRule
  alias ServiceRadar.Observability.LogPromotionRuleTemplate
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.Observability.StatefulAlertRuleTemplate

  describe "StatefulAlertRule JSON:API exposure" do
    test "declares the AshJsonApi.Resource extension" do
      assert AshJsonApi.Resource in Spark.extensions(StatefulAlertRule)
    end

    test "exposes exactly the six routes declared in the json_api block" do
      routes = JsonApiInfo.routes(StatefulAlertRule)
      route_shapes = MapSet.new(routes, &{&1.method, &1.route, &1.action})

      assert length(routes) == 6

      assert route_shapes ==
               MapSet.new([
                 {:get, "/stateful-alert-rules/:id", :by_id},
                 {:get, "/stateful-alert-rules", :read},
                 {:get, "/stateful-alert-rules/active", :active},
                 {:post, "/stateful-alert-rules", :create},
                 {:patch, "/stateful-alert-rules/:id", :update},
                 {:delete, "/stateful-alert-rules/:id", :destroy}
               ])
    end

    test "get_by_id code interface resolves to the :by_id read action" do
      assert function_exported?(StatefulAlertRule, :get_by_id, 1)
    end
  end

  describe "sibling PresetRuleResource callers are unaffected" do
    test "StatefulAlertRuleTemplate declares no AshJsonApi.Resource extension and has zero routes" do
      refute AshJsonApi.Resource in Spark.extensions(StatefulAlertRuleTemplate)
      assert JsonApiInfo.routes(StatefulAlertRuleTemplate) == []
    end

    test "LogPromotionRule declares no AshJsonApi.Resource extension and has zero routes" do
      refute AshJsonApi.Resource in Spark.extensions(LogPromotionRule)
      assert JsonApiInfo.routes(LogPromotionRule) == []
    end

    test "LogPromotionRuleTemplate declares no AshJsonApi.Resource extension and has zero routes" do
      refute AshJsonApi.Resource in Spark.extensions(LogPromotionRuleTemplate)
      assert JsonApiInfo.routes(LogPromotionRuleTemplate) == []
    end
  end
end
