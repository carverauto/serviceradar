defmodule ServiceRadar.Observability.TemplateSeederTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.StatefulAlertRuleTemplate
  alias ServiceRadar.Observability.TemplateSeeder
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "seeds default camera relay stateful alert templates" do
    actor = %{id: "system", role: :admin}

    assert :ok = TemplateSeeder.seed_all()

    query =
      StatefulAlertRuleTemplate
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(
        name in [
          "camera_relay_failure_burst",
          "camera_relay_gateway_saturation",
          "camera_relay_viewer_idle_churn"
        ]
      )
      |> Ash.Query.sort(name: :asc)

    assert {:ok, templates} = Ash.read(query, actor: actor)

    assert Enum.map(templates, & &1.name) == [
             "camera_relay_failure_burst",
             "camera_relay_gateway_saturation",
             "camera_relay_viewer_idle_churn"
           ]

    assert Enum.any?(templates, fn template ->
             template.name == "camera_relay_failure_burst" and
               template.event["log_name"] == "camera.relay.alert.failure_burst"
           end)

    assert Enum.any?(templates, fn template ->
             template.name == "camera_relay_gateway_saturation" and
               template.event["log_name"] == "camera.relay.alert.gateway_saturation"
           end)

    assert Enum.any?(templates, fn template ->
             template.name == "camera_relay_viewer_idle_churn" and
               template.event["log_name"] == "camera.relay.alert.viewer_idle_churn"
           end)
  end
end
