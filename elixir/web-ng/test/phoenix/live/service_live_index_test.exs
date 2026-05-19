defmodule ServiceRadarWebNGWeb.ServiceLiveIndexTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Observability.ServiceState

  setup :register_and_log_in_user

  test "renders plugin cards from durable service state", %{conn: conn} do
    observed_at =
      DateTime.utc_now()
      |> DateTime.add(-2, :hour)
      |> DateTime.truncate(:microsecond)

    ServiceState
    |> Ash.Changeset.for_create(
      :upsert,
      %{
        agent_id: "agent-unifi-protect",
        gateway_id: "gateway-unifi-protect",
        partition: "default",
        service_type: "plugin",
        service_name: "UniFi Protect Camera",
        available: true,
        message: "streaming plugin ready",
        details:
          Jason.encode!(%{
            "plugin_id" => "unifi-protect-camera",
            "plugin_type" => "streaming"
          }),
        last_observed_at: observed_at,
        state: "active"
      },
      actor: system_actor()
    )
    |> Ash.create!(domain: ServiceRadar.Observability)

    {:ok, view, html} = live(conn, ~p"/services")

    assert html =~ "UniFi Protect Camera"
    assert has_element?(view, "[id^='service-card-']", "streaming plugin ready")
  end
end
