defmodule ServiceRadar.Observability.RuleSeederTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.RuleSeeder
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "seeds the endpoint inventory vulnerability stateful alert rule" do
    actor = SystemActor.system(:test)

    assert :ok = RuleSeeder.seed_all()

    query =
      StatefulAlertRule
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(name == "endpoint_inventory_vulnerability")

    assert {:ok, [rule]} = Ash.read(query, actor: actor)
    assert rule.enabled
    assert rule.signal == :event
    assert rule.match["subject_prefix"] == "signals.causal.inventory"
    assert rule.match["attribute_equals"] == %{"signal_type" => "inventory"}
    assert rule.group_by == ["device"]
    assert rule.threshold == 1
    assert rule.event["log_name"] == "alert.security.endpoint_inventory.vulnerability"
    assert rule.alert["severity"] == "critical"
  end
end
