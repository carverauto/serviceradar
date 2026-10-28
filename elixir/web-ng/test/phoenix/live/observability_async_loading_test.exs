defmodule ServiceRadarWebNGWeb.ObservabilityAsyncLoadingTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Phoenix.LiveView.Socket
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.BmpLive.Index, as: BmpIndex
  alias ServiceRadarWebNGWeb.LogLive.Index, as: LogIndex
  alias ServiceRadarWebNGWeb.ServiceLive.Index, as: ServiceIndex

  @moduletag :db_free

  defmodule SlowSRQLStub do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    @latency_ms 60

    def latency_ms, do: @latency_ms

    def query(query) when is_binary(query), do: query(query, %{})

    @impl true
    def query(query, opts) when is_binary(query) do
      if pid = :persistent_term.get({__MODULE__, :test_pid}, nil) do
        send(pid, {:srql_query, query, opts})
      end

      delay = :persistent_term.get({__MODULE__, :delay_ms}, @latency_ms)
      if delay > 0, do: Process.sleep(delay)

      {:ok, %{"results" => rows_for(query), "pagination" => %{}, "error" => nil}}
    end

    @impl true
    def query_request(%{"query" => query}) when is_binary(query), do: query(query, %{})
    def query_request(_payload), do: {:error, :invalid_request}

    defp rows_for(query) do
      cond do
        String.contains?(query, "stats:") ->
          [%{"total" => 2, "total_bytes" => 2048, "total_packets" => 16}]

        String.contains?(query, "bucket:") ->
          [%{"timestamp" => "2026-08-30T18:00:00Z", "series" => "tcp", "value" => 512}]

        String.starts_with?(query, "in:services") ->
          [
            %{
              "service_id" => "svc-1",
              "service_name" => "core-http",
              "service_type" => "plugin",
              "available" => true,
              "timestamp" => "2026-08-30T18:00:00Z"
            }
          ]

        String.starts_with?(query, "in:bmp_events") ->
          [
            %{
              "id" => "bmp-1",
              "time" => "2026-08-30T18:00:00Z",
              "event_type" => "route_update",
              "severity_id" => 1,
              "router_ip" => "192.0.2.10",
              "peer_ip" => "198.51.100.20",
              "peer_asn" => 64_512,
              "prefix" => "203.0.113.0/24",
              "message" => "Route update"
            }
          ]

        String.starts_with?(query, "in:logs") ->
          [
            %{
              "id" => "log-1",
              "timestamp" => "2026-08-30T18:00:00Z",
              "severity_text" => "INFO",
              "service_name" => "core",
              "body" => "Synthetic log entry"
            }
          ]

        true ->
          []
      end
    end
  end

  setup do
    previous_srql = Application.get_env(:serviceradar_web_ng, :srql_module)
    previous_rollup = Application.get_env(:serviceradar_web_ng, :logs_rollup_status_fun)
    previous_plugin_loader = Application.get_env(:serviceradar_web_ng, :service_plugin_states_loader)

    Application.put_env(:serviceradar_web_ng, :srql_module, SlowSRQLStub)

    Application.put_env(
      :serviceradar_web_ng,
      :logs_rollup_status_fun,
      fn -> ServiceRadarWebNGWeb.Stats.empty_logs_rollup_status() end
    )

    Application.put_env(
      :serviceradar_web_ng,
      :service_plugin_states_loader,
      fn _scope -> {:ok, []} end
    )

    :persistent_term.put({SlowSRQLStub, :test_pid}, self())
    :persistent_term.put({SlowSRQLStub, :delay_ms}, SlowSRQLStub.latency_ms())

    on_exit(fn ->
      :persistent_term.erase({SlowSRQLStub, :test_pid})
      :persistent_term.erase({SlowSRQLStub, :delay_ms})

      if is_nil(previous_srql) do
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      else
        Application.put_env(:serviceradar_web_ng, :srql_module, previous_srql)
      end

      if is_nil(previous_rollup) do
        Application.delete_env(:serviceradar_web_ng, :logs_rollup_status_fun)
      else
        Application.put_env(:serviceradar_web_ng, :logs_rollup_status_fun, previous_rollup)
      end

      if is_nil(previous_plugin_loader) do
        Application.delete_env(:serviceradar_web_ng, :service_plugin_states_loader)
      else
        Application.put_env(:serviceradar_web_ng, :service_plugin_states_loader, previous_plugin_loader)
      end
    end)

    :ok
  end

  describe "ServiceLive.Index (/services) async loading" do
    test "handle_params returns loading shell before slow SRQL finishes and transitions to loaded" do
      socket = mounted_connected_socket(ServiceIndex)

      {elapsed_us, {:noreply, loading_socket}} =
        :timer.tc(fn ->
          ServiceIndex.handle_params(%{}, "http://localhost/services", socket)
        end)

      assert elapsed_us < 1_000,
             "expected handle_params under 1,000us, took #{elapsed_us}us"

      assert loading_socket.assigns.tab_loading == true

      loading_html = render_component(&ServiceIndex.render/1, loading_socket.assigns)
      assert loading_html =~ "services-tab-loading"

      services_payload = await_async_result(:services_list)

      {:noreply, after_plugin} =
        ServiceIndex.handle_async(:plugin_view, {:ok, {:ok, :empty}}, loading_socket)

      {:noreply, loaded_socket} =
        ServiceIndex.handle_async(:services_list, {:ok, services_payload}, after_plugin)

      assert loaded_socket.assigns.tab_loading == false
      assert loaded_socket.assigns.srql.loading == false
      assert [%{"service_id" => "svc-1"}] = loaded_socket.assigns.services
      assert loaded_socket.assigns.summary.total == 1
    end

    test "handle_async transitions out of loading on error tuple and task exit" do
      :persistent_term.put({SlowSRQLStub, :delay_ms}, 0)
      socket = mounted_connected_socket(ServiceIndex)
      {:noreply, loading_socket} = ServiceIndex.handle_params(%{}, "http://localhost/services", socket)
      _ = await_async_result(:services_list)

      {:noreply, after_plugin_err} =
        ServiceIndex.handle_async(:plugin_view, {:ok, {:error, :plugin_unavailable}}, loading_socket)

      {:noreply, exit_socket} =
        ServiceIndex.handle_async(:services_list, {:exit, :timeout}, after_plugin_err)

      assert exit_socket.assigns.tab_loading == false
      assert exit_socket.assigns.services == []
      assert exit_socket.assigns.srql.error =~ "could not be loaded"
    end
  end

  describe "BmpLive.Index (/observability/bmp) async loading" do
    test "handle_params returns loading shell before slow SRQL finishes and transitions to loaded" do
      socket = mounted_connected_socket(BmpIndex)

      {elapsed_us, {:noreply, loading_socket}} =
        :timer.tc(fn ->
          BmpIndex.handle_params(%{}, "http://localhost/observability/bmp", socket)
        end)

      assert elapsed_us < 1_000,
             "expected handle_params under 1,000us, took #{elapsed_us}us"

      assert loading_socket.assigns.tab_loading == true
      assert loading_socket.assigns.srql.loading == true

      payload = await_async_result(:bmp_list)

      {:noreply, loaded_socket} =
        BmpIndex.handle_async(:bmp_list, {:ok, payload}, loading_socket)

      assert loaded_socket.assigns.tab_loading == false
      assert loaded_socket.assigns.srql.loading == false
      assert [%{"id" => "bmp-1"}] = loaded_socket.assigns.bmp_events
      assert loaded_socket.assigns.summary.total == 1
      assert loaded_socket.assigns.summary.route_update == 1
    end

    test "handle_async transitions out of loading on error tuple and task exit" do
      :persistent_term.put({SlowSRQLStub, :delay_ms}, 0)
      socket = mounted_connected_socket(BmpIndex)
      {:noreply, loading_socket} = BmpIndex.handle_params(%{}, "http://localhost/observability/bmp", socket)
      _ = await_async_result(:bmp_list)

      {:noreply, error_socket} =
        BmpIndex.handle_async(:bmp_list, {:ok, {:error, :warehouse_down}}, loading_socket)

      assert error_socket.assigns.tab_loading == false
      assert error_socket.assigns.bmp_events == []
      assert error_socket.assigns.srql.error =~ "warehouse_down"

      {:noreply, exit_socket} =
        BmpIndex.handle_async(:bmp_list, {:exit, :killed}, loading_socket)

      assert exit_socket.assigns.tab_loading == false
      assert exit_socket.assigns.bmp_events == []
      assert exit_socket.assigns.srql.error =~ "killed"
    end
  end

  describe "LogLive.Index (/observability) async tab loading and NetFlow fan-out" do
    test "handle_params returns loading shell before slow SRQL finishes across observability tabs" do
      socket = mounted_connected_socket(LogIndex)

      {elapsed_us, {:noreply, loading_socket}} =
        :timer.tc(fn ->
          LogIndex.handle_params(
            %{},
            "http://localhost/observability/logs",
            socket
          )
        end)

      assert elapsed_us < 1_000,
             "expected handle_params under 1,000us, took #{elapsed_us}us"

      assert loading_socket.assigns.tab_loading == true
      assert loading_socket.assigns.srql.loading == true

      payload = await_async_result(:tab_load)

      {:noreply, loaded_socket} =
        LogIndex.handle_async(:tab_load, {:ok, payload}, loading_socket)

      assert loaded_socket.assigns.tab_loading == false
      assert loaded_socket.assigns.srql.loading == false
      assert [%{"id" => "log-1"}] = loaded_socket.assigns.logs
    end

    test "switching tabs mid-load cancels/ignores stale tab completion" do
      :persistent_term.put({SlowSRQLStub, :delay_ms}, 0)
      socket = mounted_connected_socket(LogIndex)

      {:noreply, logs_socket} =
        LogIndex.handle_params(
          %{},
          "http://localhost/observability/logs",
          socket
        )

      stale_logs_payload = await_async_result(:tab_load)

      {:noreply, traces_socket} =
        LogIndex.handle_params(
          %{},
          "http://localhost/observability/traces",
          logs_socket
        )

      traces_payload = await_async_result(:tab_load)

      # Stale logs payload arriving after the user switched to traces is ignored.
      {:noreply, after_stale} =
        LogIndex.handle_async(:tab_load, {:ok, stale_logs_payload}, traces_socket)

      assert after_stale.assigns.active_tab == "traces"
      assert after_stale.assigns.logs == []
      assert after_stale.assigns.tab_loading == true

      {:noreply, after_traces} =
        LogIndex.handle_async(:tab_load, {:ok, traces_payload}, after_stale)

      assert after_traces.assigns.active_tab == "traces"
      assert after_traces.assigns.tab_loading == false
    end

    test "handle_async transitions out of loading on error tuple and task exit" do
      :persistent_term.put({SlowSRQLStub, :delay_ms}, 0)
      socket = mounted_connected_socket(LogIndex)

      {:noreply, loading_socket} =
        LogIndex.handle_params(
          %{},
          "http://localhost/observability/logs",
          socket
        )

      _ = await_async_result(:tab_load)

      {:noreply, error_socket} =
        LogIndex.handle_async(:tab_load, {:ok, {:error, :query_failed}}, loading_socket)

      assert error_socket.assigns.tab_loading == false
      assert error_socket.assigns.srql.error =~ "query_failed"

      {:noreply, exit_socket} =
        LogIndex.handle_async(:tab_load, {:exit, :noproc}, loading_socket)

      assert exit_socket.assigns.tab_loading == false
      assert exit_socket.assigns.srql.error =~ "noproc"
    end

    test "netflows overview tab skips inactive view panels and returns handle_params before slow fan-out" do
      socket = mounted_connected_socket(LogIndex)
      drain_queries()

      {elapsed_us, {:noreply, loading_socket}} =
        :timer.tc(fn ->
          LogIndex.handle_params(
            %{"q" => "in:flows time:last_1h"},
            "http://localhost/observability/netflows?q=in:flows+time:last_1h",
            socket
          )
        end)

      assert elapsed_us < 1_000,
             "expected handle_params under 1,000us, took #{elapsed_us}us"

      payload = await_async_result(:tab_load)

      {:noreply, loaded_socket} =
        LogIndex.handle_async(:tab_load, {:ok, payload}, loading_socket)

      assert loaded_socket.assigns.tab_loading == false
      queries = drain_queries()

      # Overview only runs the flow list, summary stats, total timeseries, and
      # stacked timeseries (4 queries total) — talkers, top-ports table, geo
      # heatmap, sankey, and protocol/app activity queries are skipped.
      assert length(queries) == 4
      refute Enum.any?(queries, &String.contains?(&1, "by src_endpoint_ip"))
      refute Enum.any?(queries, &String.contains?(&1, "by dst_country_iso2"))
      refute Enum.any?(queries, &String.contains?(&1, "by src_country_iso2"))
      refute Enum.any?(queries, &String.contains?(&1, "by app"))
    end
  end

  test "pagination replaces active loads and refresh pulses let them finish" do
    for {view, path, name, live_key, timer_message} <- [
          {BmpIndex, "/observability/bmp", :bmp_list, :bmp_live?, {:debounced_refresh}},
          {LogIndex, "/observability/logs", :tab_load, :logs_live?, {:debounced_refresh, "logs"}}
        ] do
      socket = mounted_connected_socket(view)
      {:noreply, loading} = view.handle_params(%{}, "http://localhost" <> path, socket)
      loading = Phoenix.Component.assign(loading, live_key, true)
      {:noreply, coalesced} = view.handle_info(timer_message, loading)

      timer =
        if view == BmpIndex,
          do: coalesced.assigns[:_refresh_timer],
          else: get_in(coalesced.assigns, [:_refresh_timers, "logs"])

      assert is_reference(timer)
      assert is_integer(Process.read_timer(timer))
      Process.cancel_timer(timer)
      payload = await_async_result(name)
      {:noreply, loaded} = view.handle_async(name, {:ok, payload}, coalesced)
      refute loaded.assigns.srql.loading

      {:noreply, refreshing} = view.handle_info(timer_message, loaded)
      stale_payload = await_async_result(name)

      {:noreply, paging} =
        view.handle_event("srql_paginate", %{"cursor" => "synthetic-next", "page" => "2"}, refreshing)

      assert paging.assigns.srql.loading
      refute Map.fetch!(paging.assigns, live_key)

      if view == LogIndex do
        assert {:noreply, ^paging} = view.handle_async(name, {:ok, stale_payload}, paging)
      end

      page_payload = await_async_result(name)
      {:noreply, paged} = view.handle_async(name, {:ok, page_payload}, paging)
      assert paged.assigns.pagination_page == 2
      refute paged.assigns.srql.loading
    end
  end

  test "flow completion preserves modal interaction state" do
    socket = mounted_connected_socket(LogIndex)

    {:noreply, loading} =
      LogIndex.handle_params(%{"q" => "in:flows time:last_1h"}, "http://localhost/observability/netflows", socket)

    payload = await_async_result(:tab_load)

    interaction = %{
      selected_netflow: %{"src_endpoint_ip" => "192.0.2.42"},
      netflow_context: %{source: :selected},
      netflow_arin_lookup: %{asn: 64_512, data: %{name: "Example"}},
      netflow_auto_open: false
    }

    opened = Phoenix.Component.assign(loading, interaction)
    {:noreply, completed} = LogIndex.handle_async(:tab_load, {:ok, payload}, opened)
    assert Map.take(completed.assigns, Map.keys(interaction)) == interaction

    {:noreply, closed} = LogIndex.handle_event("netflow_close", %{}, opened)
    {:noreply, completed} = LogIndex.handle_async(:tab_load, {:ok, payload}, closed)
    assert is_nil(completed.assigns.selected_netflow)
    assert is_nil(completed.assigns.netflow_context)
    assert completed.assigns.netflow_arin_lookup == %{}
    refute completed.assigns.netflow_auto_open
  end

  defp mounted_connected_socket(view) do
    unconnected = %Socket{
      endpoint: ServiceRadarWebNGWeb.Endpoint,
      view: view,
      root_pid: nil,
      transport_pid: nil,
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}},
      assigns: %{
        __changed__: %{},
        flash: %{},
        live_action: nil,
        current_scope:
          Scope.for_user(%{
            id: "00000000-0000-0000-0000-000000000001",
            email: "operator@example.com",
            role: :operator,
            timezone: "Etc/UTC"
          })
      }
    }

    {:ok, mounted} = view.mount(%{}, %{}, unconnected)
    %{mounted | root_pid: self(), transport_pid: self()}
  end

  defp await_async_result(expected_name) do
    receive do
      {:phoenix, :async_result, {:start, {_async_ref, _cid, ^expected_name, {:ok, result}}}} ->
        result
    after
      5_000 ->
        flunk("timed out waiting for async result #{inspect(expected_name)}")
    end
  end

  defp drain_queries(acc \\ []) do
    receive do
      {:srql_query, query, _opts} -> drain_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
