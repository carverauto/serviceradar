defmodule ServiceRadarWebNGWeb.DeviceLive.IndexPaginationTest do
  use ExUnit.Case, async: false

  alias Phoenix.LiveView.Socket
  alias ServiceRadarWebNGWeb.DeviceLive.Index

  import Phoenix.LiveView, only: [start_async: 3, cancel_async: 2]
  alias ServiceRadarWebNGWeb.DeviceLive.IndexPath
  alias ServiceRadarWebNGWeb.DeviceLive.IndexRefresh
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @moduletag :db_free

  defmodule CursorSRQL do
    @moduledoc false

    def query(_query, opts) do
      send(opts[:scope], {:index_pagination_srql, opts[:cursor], opts[:limit]})

      case opts[:cursor] do
        "cursor-page-2" ->
          {:ok,
           %{
             "results" => [%{"uid" => "device-page-2", "hostname" => "host-page-2"}],
             "pagination" => %{"prev_cursor" => "cursor-page-1"}
           }}

        "cursor-page-1" ->
          {:ok,
           %{
             "results" => [%{"uid" => "device-page-1", "hostname" => "host-page-1"}],
             "pagination" => %{"next_cursor" => "cursor-page-2"}
           }}

        _ ->
          {:ok,
           %{
             "results" => [%{"uid" => "device-page-1", "hostname" => "host-page-1"}],
             "pagination" => %{"next_cursor" => "cursor-page-2"}
           }}
      end
    end
  end

  defmodule GatedEnrichmentSRQL do
    @moduledoc false

    def query("in:timeseries_metrics " <> _query, %{scope: owner}) do
      send(owner, :icmp_query_completed)

      {:ok,
       %{
         "results" => [
           %{"series" => "device-page-1", "timestamp" => "1999-06-15T00:00:00Z", "value" => 250_000}
         ]
       }}
    end

    def query("in:snmp_metrics " <> _query, %{scope: owner}), do: wait_for_release(owner, :presence)

    def query("in:devices rollup_stats:inventory_summary", %{scope: owner}), do: wait_for_release(owner, :stats)

    def query(query, opts), do: CursorSRQL.query(query, opts)

    defp wait_for_release(owner, kind) do
      send(owner, {:enrichment_query_waiting, kind, self()})

      receive do
        :release -> {:ok, %{"results" => []}}
      end
    end
  end

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, CursorSRQL)

    on_exit(fn ->
      if previous do
        Application.put_env(:serviceradar_web_ng, :srql_module, previous)
      else
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      end
    end)

    :ok
  end

  test "prev from page 2 reloads the list head instead of keeping page 2" do
    socket = load_devices(%{"q" => "in:devices", "page" => "2", "cursor" => "cursor-page-2"})
    assert socket.assigns.pagination_page == 2
    assert [%{"uid" => "device-page-2"}] = socket.assigns.devices

    path =
      IndexPath.list_path(
        query: "in:devices",
        page: "1",
        cursor: "cursor-page-1"
      )

    # handle_params reuses the LiveView socket, so pagination_page from page 2
    # is still assigned when the patched URL is applied.
    socket =
      SRQLPage.load_list(socket, path_params(path), "/devices", :devices,
        default_limit: 20,
        max_limit: 100
      )

    assert socket.assigns.pagination_page == 1
    assert [%{"uid" => "device-page-1"}] = socket.assigns.devices
  end

  test "pubsub refresh keeps the current page and keyset cursor" do
    params = %{"q" => "in:devices", "page" => "2", "cursor" => "cursor-page-2"}

    socket =
      params
      |> load_devices()
      |> IndexRefresh.remember_list_params(params, "/devices")
      |> IndexRefresh.refresh_devices(preserve_async_data?: true)

    assert socket.assigns.last_params["page"] == "2"
    assert socket.assigns.last_params["cursor"] == "cursor-page-2"
    assert socket.assigns.pagination_page == 2
    assert [%{"uid" => "device-page-2"}] = socket.assigns.devices
    assert_received {:index_pagination_srql, "cursor-page-2", 20}
  end

  test "background reload preserves a pending generation without querying the list again" do
    socket = pending_devices()
    assert_receive {:index_pagination_srql, nil, 20}

    deferred = IndexRefresh.refresh_devices(socket, preserve_async_data?: true)

    assert deferred.assigns.device_enrichment_token == :pending_generation
    assert deferred.assigns.device_enrichment_task == {:device_enrichment, :pending_generation}
    assert deferred.assigns.device_stats_task == {:device_stats, :pending_generation}
    assert deferred.assigns.device_refresh_pending
    refute_receive {:index_pagination_srql, _cursor, _limit}
  end

  test "many broadcasts queue one refresh after both enrichment and stats finish" do
    pending = Enum.reduce(1..10, pending_devices(), fn _, socket -> IndexRefresh.schedule_device_refresh(socket) end)
    assert pending.assigns.device_refresh_pending
    assert is_nil(pending.assigns[:device_refresh_timer])

    partial = IndexRefresh.clear_task_ref(pending, :device_enrichment_task, {:device_enrichment, :pending_generation})
    assert partial.assigns.device_refresh_pending
    assert is_nil(partial.assigns[:device_refresh_timer])

    completed = IndexRefresh.clear_task_ref(partial, :device_stats_task, {:device_stats, :pending_generation})
    assert is_reference(completed.assigns.device_refresh_timer)
    refute completed.assigns.device_refresh_pending
    assert completed.assigns.device_enrichment_token == :pending_generation
    assert IndexRefresh.schedule_device_refresh(completed) == completed
    IndexRefresh.cancel_device_refresh_timer(completed)
  end

  test "stats completing first also waits for enrichment and ignores stale task completions" do
    pending = IndexRefresh.schedule_device_refresh(pending_devices())

    assert IndexRefresh.clear_task_ref(pending, :device_enrichment_task, {:device_enrichment, :stale_generation}) ==
             pending

    partial = IndexRefresh.clear_task_ref(pending, :device_stats_task, {:device_stats, :pending_generation})
    assert is_nil(partial.assigns[:device_refresh_timer])

    completed = IndexRefresh.clear_task_ref(partial, :device_enrichment_task, {:device_enrichment, :pending_generation})
    assert is_reference(completed.assigns.device_refresh_timer)
    IndexRefresh.cancel_device_refresh_timer(completed)
  end

  test "successful callbacks publish the pending generation before its trailing refresh" do
    socket = IndexRefresh.schedule_device_refresh(pending_devices())
    icmp = %{icmp_sparklines: %{"sr:host-alpha" => %{points: [0.25]}}, icmp_error: nil}
    {:noreply, socket} = Index.handle_info({:device_icmp_loaded, :pending_generation, icmp}, socket)
    stats = %{total: 1}
    {:noreply, socket} = Index.handle_async({:device_stats, :pending_generation}, {:ok, stats}, socket)
    assert socket.assigns.device_stats == stats
    assert is_nil(socket.assigns.device_refresh_timer)

    enrichments = %{
      effective_availability_by_device: %{},
      snmp_presence: %{},
      sysmon_presence: %{},
      sysmon_profiles_by_device: %{},
      agent_device_uids: MapSet.new(),
      composite_verdicts_by_device: %{},
      total_device_count: 1
    }

    {:noreply, socket} = Index.handle_async({:device_enrichment, :pending_generation}, {:ok, enrichments}, socket)
    assert socket.assigns.icmp_sparklines == icmp.icmp_sparklines
    assert socket.assigns.total_device_count == 1
    assert is_reference(socket.assigns.device_refresh_timer)
    IndexRefresh.cancel_device_refresh_timer(socket)
  end

  test "ICMP progress arrives while presence and stats queries are still blocked" do
    Application.put_env(:serviceradar_web_ng, :srql_module, GatedEnrichmentSRQL)
    socket = load_devices(%{"q" => "in:devices"})
    socket = IndexRefresh.refresh_devices(%{socket | transport_pid: self()})

    on_exit(fn ->
      cancel_async(socket, socket.assigns.device_enrichment_task)
      cancel_async(socket, socket.assigns.device_stats_task)
    end)

    assert_receive :icmp_query_completed
    assert_receive {:enrichment_query_waiting, :presence, presence_pid}
    assert_receive {:enrichment_query_waiting, :stats, stats_pid}
    assert_receive {:device_icmp_loaded, token, icmp}
    refute_receive :icmp_query_completed

    {:noreply, updated} = Index.handle_info({:device_icmp_loaded, token, icmp}, socket)

    assert updated.assigns.icmp_sparklines["device-page-1"].points == [0.25]
    assert updated.assigns.icmp_error == nil
    assert updated.assigns.device_enrichment_task == socket.assigns.device_enrichment_task
    assert updated.assigns.device_stats_task == socket.assigns.device_stats_task
    assert is_nil(updated.assigns.device_refresh_timer)
    assert Process.alive?(presence_pid)
    assert Process.alive?(stats_pid)
  end

  test "stale ICMP progress cannot replace the current generation or release pending work" do
    socket = IndexRefresh.schedule_device_refresh(pending_devices())
    icmp = %{icmp_sparklines: %{}, icmp_error: "invented query failure"}

    assert {:noreply, ^socket} = Index.handle_info({:device_icmp_loaded, :stale_generation, icmp}, socket)

    {:noreply, updated} = Index.handle_info({:device_icmp_loaded, :pending_generation, icmp}, socket)
    assert updated.assigns.icmp_error == "invented query failure"
    assert updated.assigns.device_refresh_pending
    assert updated.assigns.device_enrichment_task == socket.assigns.device_enrichment_task
    assert updated.assigns.device_stats_task == socket.assigns.device_stats_task
    assert is_nil(updated.assigns.device_refresh_timer)
  end

  test "failed tasks release the queued refresh while stale cancellation leaves the new generation alone" do
    socket = IndexRefresh.schedule_device_refresh(pending_devices())

    assert {:noreply, ^socket} =
             Index.handle_async({:device_stats, :stale_generation}, {:exit, {:shutdown, :cancel}}, socket)

    {:noreply, socket} = Index.handle_async({:device_stats, :pending_generation}, {:exit, {:shutdown, :cancel}}, socket)
    refute socket.assigns.device_stats_loading
    assert is_nil(socket.assigns.device_refresh_timer)

    {:noreply, socket} =
      Index.handle_async({:device_enrichment, :pending_generation}, {:exit, {:shutdown, :cancel}}, socket)

    assert is_reference(socket.assigns.device_refresh_timer)
    refute socket.assigns.device_refresh_pending
    IndexRefresh.cancel_device_refresh_timer(socket)
  end

  test "explicit navigation cancels pending named tasks and loads the requested page immediately" do
    socket = pending_devices()
    owner = self()
    socket = %{socket | transport_pid: self()}

    socket =
      Enum.reduce([:device_enrichment, :device_stats], socket, fn kind, acc ->
        start_async(acc, {kind, :pending_generation}, fn ->
          send(owner, {:started_index_task, kind, self()})

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive {:started_index_task, :device_enrichment, enrichment_pid}
    assert_receive {:started_index_task, :device_stats, stats_pid}
    enrichment_monitor = Process.monitor(enrichment_pid)
    stats_monitor = Process.monitor(stats_pid)

    socket = %{socket | transport_pid: nil}

    refreshed =
      IndexRefresh.refresh_devices(socket,
        list_params: %{"q" => "in:devices", "page" => "2", "cursor" => "cursor-page-2"}
      )

    assert_receive {:DOWN, ^enrichment_monitor, :process, ^enrichment_pid, {:shutdown, :cancel}}
    assert_receive {:DOWN, ^stats_monitor, :process, ^stats_pid, {:shutdown, :cancel}}
    assert_receive {:index_pagination_srql, "cursor-page-2", 20}
    assert refreshed.assigns.pagination_page == 2
    refute refreshed.assigns.device_enrichment_token == :pending_generation
    refute refreshed.assigns.device_refresh_pending
    assert is_nil(refreshed.assigns.device_enrichment_task)
    assert is_nil(refreshed.assigns.device_stats_task)
  end

  defp pending_devices do
    %{"q" => "in:devices"}
    |> load_devices()
    |> Phoenix.Component.assign(
      device_enrichment_token: :pending_generation,
      device_enrichment_task: {:device_enrichment, :pending_generation},
      device_stats_task: {:device_stats, :pending_generation},
      device_refresh_pending: false,
      device_refresh_timer: nil
    )
  end

  defp load_devices(params) do
    %Socket{}
    |> Phoenix.Component.assign(:current_scope, self())
    |> Phoenix.Component.assign(:live_action, :index)
    |> Phoenix.Component.assign(:device_stats_loaded, false)
    |> SRQLPage.init("devices", default_limit: 20)
    |> SRQLPage.load_list(params, "/devices", :devices, default_limit: 20, max_limit: 100)
  end

  defp path_params(path) do
    case URI.parse(path).query do
      query when is_binary(query) and query != "" -> URI.decode_query(query)
      _ -> %{}
    end
  end
end
