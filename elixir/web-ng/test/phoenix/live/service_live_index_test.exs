defmodule ServiceRadarWebNGWeb.ServiceLiveIndexTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Observability.ServiceStateRegistry
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage

  setup :register_and_log_in_user

  test "renders plugin cards from durable service state", %{conn: conn} do
    gateway = gateway_fixture()
    agent = agent_fixture(gateway)
    package = approved_plugin_package_fixture("UniFi Protect Camera", "serviceradar.plugin_result.v1")
    _assignment = plugin_assignment_fixture(agent.uid, package.id)

    assert :ok =
             ServiceStateRegistry.upsert_from_status(%{
               agent_id: agent.uid,
               gateway_id: agent.gateway_id,
               partition: "default",
               service_type: "plugin",
               service_name: package.name,
               available: true,
               message: %{
                 "summary" => "camera check healthy",
                 "labels" => %{"plugin_id" => package.plugin_id}
               },
               observed_at:
                 DateTime.utc_now()
                 |> DateTime.add(-2, :hour)
                 |> DateTime.truncate(:microsecond)
             })

    {:ok, view, html} = live(conn, ~p"/services")

    assert html =~ "UniFi Protect Camera"
    assert has_element?(view, "#service-cards", "camera check healthy")
  end

  test "active plugin card read excludes non-plugin rows and large details" do
    observed_at =
      DateTime.utc_now()
      |> DateTime.add(-2, :minute)
      |> DateTime.truncate(:microsecond)

    insert_service_state!(%{
      agent_id: "agent-plugin",
      gateway_id: "gateway-plugin",
      partition: "default",
      service_type: "plugin",
      service_name: "Lightweight Plugin",
      available: true,
      message: "plugin ok",
      details: Jason.encode!(%{"payload" => String.duplicate("x", 10_000)}),
      last_observed_at: observed_at,
      state: "active"
    })

    insert_service_state!(%{
      agent_id: "agent-passive",
      gateway_id: "gateway-passive",
      partition: "default",
      service_type: "passive-netprobe",
      service_name: "Flow Payload",
      available: true,
      message: "passive ok",
      details: Jason.encode!(%{"payload" => String.duplicate("y", 10_000)}),
      last_observed_at: observed_at,
      state: "active"
    })

    states =
      ServiceState
      |> Ash.Query.for_read(:active_plugin_cards, %{}, actor: system_actor())
      |> Ash.read!(domain: ServiceRadar.Observability)

    assert [%ServiceState{service_name: "Lightweight Plugin"} = state] = states
    assert %Ash.NotLoaded{} = state.details
  end

  defp insert_service_state!(attrs) do
    ServiceState
    |> Ash.Changeset.for_create(:upsert, attrs, actor: system_actor())
    |> Ash.create!(domain: ServiceRadar.Observability)
  end

  defp approved_plugin_package_fixture(name, output) do
    plugin_id = "service-live-plugin-#{System.unique_integer([:positive])}"

    Plugin
    |> Ash.Changeset.for_create(
      :create,
      %{plugin_id: plugin_id, name: name},
      actor: system_actor()
    )
    |> Ash.create!()

    manifest = %{
      "id" => plugin_id,
      "name" => name,
      "version" => "1.0.0",
      "entrypoint" => "run_check",
      "runtime" => "wasi-preview1",
      "outputs" => output,
      "capabilities" => ["submit_result"],
      "resources" => %{
        "requested_memory_mb" => 32,
        "requested_cpu_ms" => 100,
        "max_open_connections" => 1
      }
    }

    PluginPackage
    |> Ash.Changeset.for_create(
      :create,
      %{
        plugin_id: plugin_id,
        name: name,
        version: "1.0.0",
        entrypoint: "run_check",
        runtime: "wasi-preview1",
        outputs: output,
        manifest: manifest,
        config_schema: %{},
        display_contract: %{},
        content_hash: "sha256:#{plugin_id}",
        signature: %{},
        source_type: :upload
      },
      actor: system_actor()
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(:approve, %{approved_by: "test"}, actor: system_actor())
    |> Ash.update!()
  end

  defp plugin_assignment_fixture(agent_uid, package_id) do
    PluginAssignment
    |> Ash.Changeset.for_create(
      :create,
      %{
        agent_uid: agent_uid,
        plugin_package_id: package_id,
        source: :manual,
        enabled: true,
        interval_seconds: 60,
        timeout_seconds: 10,
        params: %{}
      },
      actor: system_actor()
    )
    |> Ash.create!()
  end
end
