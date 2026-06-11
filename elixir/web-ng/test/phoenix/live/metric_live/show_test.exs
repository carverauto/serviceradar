defmodule ServiceRadarWebNGWeb.MetricLive.ShowTest do
  @moduledoc """
  Tests for the metric sample detail pivots: the Trace button targets the
  trace detail route (hidden for unusable ids) and the Logs button bounds its
  window around the metric's own timestamp instead of a relative window.
  """

  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.AccountsFixtures

  @span_id "0bd8613253e905b1"
  @trace_id "aabbccddeeff00112233445566778899"

  setup %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :operator})
    conn = log_in_user(conn, user)

    old = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.SRQLStub)

    :persistent_term.put({__MODULE__, :scenario}, :valid_trace)

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :scenario})

      if is_nil(old) do
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      else
        Application.put_env(:serviceradar_web_ng, :srql_module, old)
      end
    end)

    %{conn: conn}
  end

  test "trace button targets the trace detail route", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/metrics/#{@span_id}")

    html = render(lv)

    assert html =~ "/observability/traces/#{@trace_id}"
    assert has_element?(lv, "a", "Trace")
  end

  test "logs button derives an absolute window from the metric timestamp", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/metrics/#{@span_id}")

    html = render(lv)

    # timestamp 2026-06-10T12:00:00Z padded by ±1h, URI-encoded in the href.
    assert html =~ "2026-06-10T11%3A00%3A00Z"
    assert html =~ "2026-06-10T13%3A00%3A00Z"
    refute html =~ "time%3Alast_24h"
  end

  test "trace button is hidden when the trace id cannot be normalized", %{conn: conn} do
    :persistent_term.put({__MODULE__, :scenario}, :double_hex_trace)

    {:ok, lv, _html} = live(conn, ~p"/observability/metrics/#{@span_id}")

    html = render(lv)

    refute html =~ "/observability/traces/"
    refute has_element?(lv, "a", "Trace")
    # The Logs pivot still works off the raw trace id.
    assert has_element?(lv, "a", "Logs")
  end

  defmodule SRQLStub do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    @impl true
    def query(query) when is_binary(query) do
      if String.contains?(query, "span_id:") do
        {:ok, %{"results" => [metric()]}}
      else
        {:ok, %{"results" => []}}
      end
    end

    @impl true
    def query(query, _opts) when is_binary(query), do: query(query)

    @impl true
    def query_request(%{"query" => query}) when is_binary(query), do: query(query)
    def query_request(_payload), do: {:error, :invalid_request}

    defp metric do
      trace_id =
        case :persistent_term.get({ServiceRadarWebNGWeb.MetricLive.ShowTest, :scenario}, :valid_trace) do
          :double_hex_trace -> String.duplicate("66", 32)
          _ -> "aabbccddeeff00112233445566778899"
        end

      %{
        "timestamp" => "2026-06-10T12:00:00Z",
        "service_name" => "core-elx",
        "metric_type" => "span",
        "span_name" => "GET /api/devices",
        "span_id" => "0bd8613253e905b1",
        "trace_id" => trace_id,
        "duration_ms" => 142.0,
        "is_slow" => true
      }
    end
  end
end
