defmodule ServiceRadarWebNGWeb.LogLive.NetflowsTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  use ServiceRadarWebNG.AshTestHelpers

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
    {:ok, _lv, html} = live(conn, ~p"/flows?#{%{q: q, limit: 50}}")
    assert html =~ "Network Flows"
  end

  test "/flows keeps canonical path when patching state", %{conn: conn} do
    q = "in:flows time:last_24h"
    {:ok, lv, _html} = live(conn, ~p"/flows?#{%{q: q, limit: 50}}")

    lv
    |> element("button[phx-click=\"nf_reset\"]")
    |> render_click()

    assert_patch(lv, path)
    assert String.starts_with?(path, "/flows?")
  end

  test "/flows open=first opens flow details and preserves explicit time window", %{conn: conn} do
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

    {:ok, _lv, html} = live(conn, ~p"/flows?#{%{q: q, open: "first", limit: 50}}")
    assert html =~ "Flow details"

    queries = collect_srql_queries([])
    assert Enum.any?(queries, &String.contains?(&1, "time:last_24h"))

    assert Enum.any?(queries, fn query ->
             String.contains?(query, "bucket:5m") and String.contains?(query, "time:last_24h")
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
