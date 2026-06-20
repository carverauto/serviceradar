defmodule ServiceRadarWebNGWeb.LogLive.NetflowsTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.AccountsFixtures

  setup %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :operator})
    conn = log_in_user(conn, user)

    Application.put_env(
      :serviceradar_web_ng,
      :srql_module,
      ServiceRadarWebNG.TestSupport.SRQLStub
    )

    on_exit(fn ->
      Application.delete_env(:serviceradar_web_ng, :srql_module)
    end)

    %{conn: conn}
  end

  test "/flows renders netflow visualize page", %{conn: conn} do
    q = "in:flows time:last_24h"

    # /flows is an HTTP redirect entry point into /observability?tab=netflows.
    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/flows?#{%{q: q, limit: 50}}")
    assert String.starts_with?(to, "/observability?")
    assert to =~ "tab=netflows"

    {:ok, _lv, html} = live(conn, to)
    # Overview panels of the netflows tab.
    assert html =~ "Avg PPS"
    assert html =~ "Total Packets"
  end

  test "/observability netflows summary rates use the selected query window", %{conn: conn} do
    Application.put_env(
      :serviceradar_web_ng,
      :srql_module,
      ServiceRadarWebNGWeb.LogLive.NetflowsTest.RecordingSRQLStub
    )

    test_pid = self()
    :persistent_term.put({__MODULE__, :test_pid}, test_pid)

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :test_pid})
    end)

    q = "in:flows time:last_24h"

    {:ok, _lv, html} = live(conn, ~p"/observability?#{%{q: q, limit: 50, tab: "netflows"}}")

    assert html =~ "Avg Bandwidth"
    assert html =~ "1.0 Kbps"
    assert html =~ "Avg PPS"
    assert html =~ "1.0 pps"

    queries = collect_srql_queries([])

    refute Enum.any?(queries, fn query ->
             String.contains?(query, ~S|stats:"min(time) as first_time, max(time) as last_time"|)
           end)
  end

  test "/flows keeps canonical path when patching state", %{conn: conn} do
    Application.put_env(
      :serviceradar_web_ng,
      :srql_module,
      ServiceRadarWebNGWeb.LogLive.NetflowsTest.RecordingSRQLStub
    )

    q = "in:flows time:last_24h"

    assert {:error, {:redirect, %{to: _to}}} = live(conn, ~p"/flows?#{%{q: q, limit: 50}}")

    {:ok, lv, _html} =
      live(conn, ~p"/observability?#{%{q: q, limit: 50, tab: "netflows", open_flow: "1"}}")

    lv
    |> element(~s(button[phx-click="netflow_modal_filter"][phx-value-field="src_ip"]))
    |> render_click()

    path = assert_patch(lv)
    assert String.starts_with?(path, "/observability?")
  end

  test "/observability netflows open_flow=1 opens flow details and preserves explicit time window",
       %{conn: conn} do
    Application.put_env(
      :serviceradar_web_ng,
      :srql_module,
      ServiceRadarWebNGWeb.LogLive.NetflowsTest.RecordingSRQLStub
    )

    test_pid = self()
    :persistent_term.put({__MODULE__, :test_pid}, test_pid)

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :test_pid})
    end)

    q =
      ~s(in:flows time:last_24h src_endpoint_ip:192.168.1.134 dst_endpoint_ip:13.217.9.183 src_endpoint_port:57196 dst_endpoint_port:443 protocol_num:6 sort:time:desc limit:1)

    {:ok, _lv, html} =
      live(conn, ~p"/observability?#{%{q: q, limit: 50, tab: "netflows", open_flow: "1"}}")

    assert html =~ "Flow details"
    # dst port 443 resolves to the HTTPS service label.
    assert html =~ "HTTPS"
    assert html =~ "direction:"
    assert html =~ "bidirectional"
    assert html =~ "SourceNet Inc"
    assert html =~ "DestNet LLC"

    queries = collect_srql_queries([])
    assert Enum.any?(queries, &String.contains?(&1, "time:last_24h"))

    # The timeseries query must bucket within the explicit 24h window
    # (bucket size itself is an implementation detail of the window).
    assert Enum.any?(queries, fn query ->
             String.contains?(query, "bucket:") and String.contains?(query, "time:last_24h")
           end)
  end

  defp collect_srql_queries(acc) do
    receive do
      {:srql_query, query} when is_binary(query) ->
        collect_srql_queries([query | acc])
    after
      100 ->
        Enum.reverse(acc)
    end
  end

  defmodule RecordingSRQLStub do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    @impl true
    def query(query) when is_binary(query), do: query(query, %{})

    @impl true
    def query(query, _opts) when is_binary(query) do
      case :persistent_term.get({ServiceRadarWebNGWeb.LogLive.NetflowsTest, :test_pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:srql_query, query})
        _ -> :ok
      end

      cond do
        String.contains?(query, "bucket:") ->
          {:ok,
           %{
             "results" => [
               %{"timestamp" => "2026-02-27T21:00:00Z", "series" => "tcp", "value" => 1024}
             ],
             "pagination" => %{},
             "error" => nil
           }}

        String.contains?(query, ~S|stats:"sum(bytes_total) as total_bytes"|) ->
          {:ok,
           %{
             "results" => [%{"total_bytes" => 10_800_000}],
             "pagination" => %{},
             "error" => nil
           }}

        String.contains?(query, ~S|stats:"sum(packets_total) as total_packets"|) ->
          {:ok,
           %{
             "results" => [%{"total_packets" => 86_400}],
             "pagination" => %{},
             "error" => nil
           }}

        String.contains?(query, ~S|stats:"sum(packets_in) as total_packets_in"|) ->
          {:ok, %{"results" => [], "pagination" => %{}, "error" => nil}}

        String.contains?(query, ~S|stats:"sum(packets_out) as total_packets_out"|) ->
          {:ok, %{"results" => [], "pagination" => %{}, "error" => nil}}

        String.contains?(query, ~S|stats:"sum(packets) as total_packets"|) ->
          {:ok, %{"results" => [], "pagination" => %{}, "error" => nil}}

        String.contains?(query, ~S|stats:"count(*) as total by protocol_num"|) ->
          {:ok,
           %{
             "results" => [
               %{"protocol_num" => 6, "total" => 1},
               %{"protocol_num" => 17, "total" => 1}
             ],
             "pagination" => %{},
             "error" => nil
           }}

        String.contains?(query, ~S|stats:"count(*) as total"|) ->
          {:ok,
           %{
             "results" => [%{"total" => 2}],
             "pagination" => %{},
             "error" => nil
           }}

        String.contains?(query, "in:flows") ->
          {:ok,
           %{
             "results" => [
               %{
                 "time" => "2026-02-27T21:00:00Z",
                 "src_endpoint_ip" => "192.168.1.134",
                 "dst_endpoint_ip" => "13.217.9.183",
                 "src_endpoint_port" => 57_196,
                 "dst_endpoint_port" => 443,
                 "protocol_num" => 6,
                 "protocol_name" => "tcp",
                 "direction_label" => "bidirectional",
                 "dst_service_label" => "HTTPS",
                 "src_hosting_provider" => "SourceNet Inc",
                 "dst_hosting_provider" => "DestNet LLC",
                 "src_mac" => "001122334455",
                 "dst_mac" => "AABBCCDDEEFF",
                 "src_mac_vendor" => "SourceVendor Corp",
                 "dst_mac_vendor" => "DestVendor Inc",
                 "tcp_flags" => 18,
                 "tcp_flags_labels" => ["SYN", "ACK"],
                 "packets_total" => 10,
                 "bytes_total" => 2048
               }
             ],
             "pagination" => %{},
             "error" => nil
           }}

        true ->
          {:ok, %{"results" => [], "pagination" => %{}, "error" => nil}}
      end
    end

    @impl true
    def query_request(%{"query" => query}) when is_binary(query), do: query(query, %{})
    def query_request(_payload), do: {:error, :invalid_request}
  end
end
