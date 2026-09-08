defmodule ServiceRadarWebNGWeb.MetricLive.TimestampRenderingTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.AccountsFixtures

  @moduletag :web_ng_shared_fixture_db

  setup %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :operator})

    user =
      Ash.update!(user, %{timezone: "America/Chicago"},
        action: :update_timezone_preference,
        actor: user
      )

    conn = log_in_user(conn, user)
    old = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.SRQLStub)

    on_exit(fn ->
      if is_nil(old),
        do: Application.delete_env(:serviceradar_web_ng, :srql_module),
        else: Application.put_env(:serviceradar_web_ng, :srql_module, old)
    end)

    %{conn: conn}
  end

  test "metric detail localizes its label and preserves canonical pivot bounds", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/metrics/0bd8613253e905b1")

    assert has_element?(
             lv,
             ~s(#metric-detail-time[datetime="2026-08-30T18:00:00Z"][data-user-time-zone="America/Chicago"])
           )

    [href] =
      lv
      |> element("a", "Logs")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("a")
      |> LazyHTML.attribute("href")

    params = href |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert params["q"] =~ "time:[2026-08-30T17:00:00Z,2026-08-30T19:00:00Z]"
  end

  test "metric detail leaves an offset-less binary timestamp as raw fallback text", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/metrics/0bd8613253e905b2")
    html = render(lv)

    assert html =~ "2026-08-30T12:34:56"
    refute has_element?(lv, "time#metric-detail-time")
    refute html =~ "2026-08-30T12:34:56Z"
  end

  test "metric detail preserves an explicitly offset binary instant", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/observability/metrics/0bd8613253e905b3")

    assert has_element?(
             lv,
             ~s(#metric-detail-time[datetime="2026-08-30T18:00:00Z"][data-user-time-zone="America/Chicago"])
           )
  end

  defmodule SRQLStub do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    def query(query), do: query(query, %{})

    def query(query, _opts) do
      results =
        if String.contains?(query, "span_id:") do
          timestamp =
            cond do
              String.contains?(query, "0bd8613253e905b2") -> "2026-08-30T12:34:56"
              String.contains?(query, "0bd8613253e905b3") -> "2026-08-30T13:00:00-05:00"
              true -> "2026-08-30T18:00:00Z"
            end

          [
            %{
              "timestamp" => timestamp,
              "service_name" => "core-elx",
              "metric_type" => "span",
              "span_name" => "GET /api/devices",
              "span_id" => "0bd8613253e905b1",
              "trace_id" => "aabbccddeeff00112233445566778899",
              "duration_ms" => 142.0,
              "is_slow" => true
            }
          ]
        else
          []
        end

      {:ok, %{"results" => results}}
    end

    def query_request(%{"query" => query}), do: query(query)
    def query_request(_), do: {:error, :invalid_request}
  end
end
