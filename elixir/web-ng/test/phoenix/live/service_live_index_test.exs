defmodule ServiceRadarWebNGWeb.ServiceLiveIndexTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Observability.PluginResultIngestor
  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Observability.ServiceStateRegistry
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage

  setup :register_and_log_in_user

  defmodule ReplayHandler do
    @moduledoc false

    def put_outcomes(outcomes), do: Process.put({__MODULE__, :outcomes}, outcomes)
    def supports?(_payload, _status), do: true

    def ingest(_payload, _status, _opts) do
      case Process.get({__MODULE__, :outcomes}, []) do
        [outcome | rest] ->
          Process.put({__MODULE__, :outcomes}, rest)
          outcome

        [] ->
          :ok
      end
    end
  end

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

  test "renders display contract from a recovered real plugin result", %{conn: conn} do
    gateway = gateway_fixture()
    agent = agent_fixture(gateway)

    package =
      approved_plugin_package_fixture(
        "Display Contract Plugin",
        "serviceradar.plugin_result.v1",
        display_contract: %{"schema_version" => 1, "widgets" => ["stat_card"]}
      )

    _assignment = plugin_assignment_fixture(agent.uid, package.id)
    previous_handlers = Application.get_env(:serviceradar_core, :plugin_result_handlers)

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])
    on_exit(fn -> restore_env(:plugin_result_handlers, previous_handlers) end)
    ReplayHandler.put_outcomes([{:error, :transient_failure}, :ok])

    observed_at = DateTime.utc_now() |> DateTime.add(-5, :second) |> DateTime.truncate(:microsecond)

    payload = %{
      "status" => "OK",
      "summary" => "display result recovered",
      "observed_at" => DateTime.to_iso8601(observed_at),
      "schema_version" => 1,
      "labels" => %{"plugin_id" => package.plugin_id},
      "display" => [
        %{"widget" => "stat_card", "label" => "Imported hosts", "value" => 20},
        %{"widget" => "table", "columns" => ["host"], "rows" => [%{"host" => "blocked"}]}
      ]
    }

    status = %{
      source: "plugin-result",
      agent_id: agent.uid,
      gateway_id: agent.gateway_id,
      partition: "default",
      service_type: "plugin",
      service_name: package.name,
      available: true
    }

    assert {:error, {:plugin_result_handlers_failed, [{ReplayHandler, ":transient_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert :ok = PluginResultIngestor.ingest(payload, status)

    params = %{
      "service_name" => package.name,
      "service_type" => "plugin",
      "gateway_id" => agent.gateway_id,
      "agent_id" => agent.uid,
      "partition" => "default",
      "timestamp" => observed_at |> DateTime.add(2, :microsecond) |> DateTime.to_iso8601()
    }

    {:ok, view, html} = live(conn, ~p"/services/check?#{params}")

    assert html =~ "UI schema version 1"
    assert has_element?(view, "div", "Imported hosts")
    assert has_element?(view, "div", "20")
    refute html =~ "blocked"
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

  defp approved_plugin_package_fixture(name, output, opts \\ []) do
    plugin_id = "service-live-plugin-#{System.unique_integer([:positive])}"
    display_contract = Keyword.get(opts, :display_contract, %{})

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
        display_contract: display_contract,
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

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
