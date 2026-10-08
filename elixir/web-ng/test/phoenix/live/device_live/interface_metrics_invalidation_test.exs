defmodule ServiceRadarWebNGWeb.DeviceLive.InterfaceMetricsInvalidationTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.AgentConfig.ConfigInvalidator
  alias ServiceRadarWebNGWeb.DeviceLive.InterfaceComponents
  alias ServiceRadarWebNGWeb.DeviceLive.InterfaceData
  alias ServiceRadarWebNGWeb.DeviceLive.InterfaceRuntime

  @moduletag :db_free

  test "bulk enable of 51 interfaces invalidates SNMP config once" do
    parent = self()
    Process.put(:serviceradar_config_invalidation_mode, :async)
    sup = Module.concat(__MODULE__, TaskSupervisor)

    start_supervised!({Task.Supervisor, name: sup})

    start_supervised!(
      {ConfigInvalidator,
       name: ConfigInvalidator,
       task_supervisor: sup,
       debounce_ms: 1_000,
       cache: fn _type -> :ok end,
       push: fn type, scope -> send(parent, {:pushed, type, scope}) end,
       schedule: fn message, _delay ->
         send(parent, {:timer, message})
         make_ref()
       end}
    )

    id = "interface-metrics-invalidation-#{System.unique_integer([:positive])}"
    {:ok, _} = Application.ensure_all_started(:telemetry)

    :ok =
      :telemetry.attach(
        id,
        ConfigInvalidator.telemetry_event(),
        fn _event, measurements, metadata, _config ->
          send(parent, {:telemetry, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)

    rows = for n <- 1..51, do: {"if-#{n}", true}

    count =
      InterfaceData.persist_metrics_rows(:scope, "device-01", rows, fn _scope, _device, _uid, enabled? ->
        assert enabled?
        {:ok, :saved}
      end)

    assert count == 51
    _ = :sys.get_state(ConfigInvalidator)
    assert_received {:timer, {:fire, :snmp, ref}}
    refute_received {:timer, _message}
    send(ConfigInvalidator, {:fire, :snmp, ref})

    assert_receive {:pushed, :snmp, scope}
    assert scope == MapSet.new([{:device, "device-01"}])
    assert_receive {:telemetry, measurements, metadata}
    assert measurements.coalesced == 1
    assert measurements.duration >= 0
    assert metadata.status == :ok
    assert metadata.config_type == :snmp
    refute_receive {:pushed, _type, _scope}
  end

  test "a burst of interface metric toggles schedules one save" do
    {socket, timers} =
      Enum.reduce(1..51, {metrics_socket(), []}, fn n, {socket, timers} ->
        socket = InterfaceRuntime.toggle_metrics(socket, "if-#{n}", :unused)
        {socket, [socket.assigns.interface_metrics_flush_timer | timers]}
      end)

    [current | cancelled] = timers

    assert socket.assigns.interface_metrics_busy
    assert map_size(socket.assigns.interface_metrics_pending) == 51
    assert Enum.all?(socket.assigns.network_interfaces, & &1["metrics_enabled"])
    assert is_integer(Process.read_timer(current))
    assert Enum.all?(cancelled, &(Process.read_timer(&1) == false))
    refute_received {:flush_interface_metrics, _token}, 0

    Process.cancel_timer(current)
  end

  test "metric controls stay disabled while a save is in flight" do
    html = render_interfaces(true)

    assert html =~ ~s(id="interface-metrics-toggle-if-1")
    assert html =~ ~s(phx-disable-with="Saving...")
    assert button_disabled?(html, "interface-metrics-toggle-if-1")
    assert button_disabled?(html, "enable-favorited-interface-metrics")

    idle = render_interfaces(false)
    refute button_disabled?(idle, "interface-metrics-toggle-if-1")
    refute button_disabled?(idle, "enable-favorited-interface-metrics")
  end

  defp button_disabled?(html, id) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query_by_id(id)
    |> LazyHTML.attribute("disabled") != []
  end

  defp render_interfaces(busy?) do
    render_component(&InterfaceComponents.interfaces_tab_content/1,
      interfaces: [
        %{
          "interface_uid" => "if-1",
          "if_name" => "Gi0/1",
          "metrics_enabled" => false
        }
      ],
      selected_interfaces: MapSet.new(),
      favorited_interfaces: MapSet.new(["if-1"]),
      device_uid: "device-01",
      timezone: "Etc/UTC",
      interface_metrics: %{
        favorited_count: 1,
        has_favorited: true,
        error: nil,
        panels: [],
        action: :enable_favorited_metrics,
        message: "Collection is off for favorited interfaces."
      },
      interface_metrics_busy: busy?
    )
  end

  defp metrics_socket do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        metrics_enabled_interfaces: MapSet.new(),
        interface_metrics_pending: %{},
        interface_metrics_busy: false,
        interface_metrics_flush_token: nil,
        interface_metrics_flush_timer: nil,
        network_interfaces:
          for n <- 1..51 do
            %{"interface_uid" => "if-#{n}", "if_name" => "Gi0/#{n}", "metrics_enabled" => false}
          end
      }
    }
  end
end
