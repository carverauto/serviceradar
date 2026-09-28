defmodule ServiceRadarWebNGWeb.DeviceLive.SparklineTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ServiceRadarWebNGWeb.DeviceLive.IndexData.Telemetry
  alias ServiceRadarWebNGWeb.DeviceLive.IndexView.Sparkline

  @moduletag :db_free
  @uid "sr:host-lumen"

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__)

    on_exit(fn ->
      if previous do
        Application.put_env(:serviceradar_web_ng, :srql_module, previous)
      else
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      end
    end)
  end

  for {name, values, chart?} <- [
        {"one bucket", [12_500_000], false},
        {"only one positive bucket", [0, 12_500_000], false},
        {"two changing buckets", [10_000_000, 12_500_000], true},
        {"two equal buckets", [12_500_000, 12_500_000], true}
      ] do
    test "#{name} preserves latency and renders only a usable trend" do
      rows =
        unquote(values)
        |> Enum.with_index()
        |> Enum.map(fn {value, index} ->
          %{
            "series" => @uid,
            "value" => value,
            "timestamp" => ~U[2001-02-03 04:00:00Z] |> DateTime.add(index * 300) |> DateTime.to_iso8601()
          }
        end)

      Process.put(:sweep_rows, rows)
      {sparklines, nil} = Telemetry.icmp_sparklines(%{}, [%{"uid" => @uid}])
      document = render_spark(Map.fetch!(sparklines, @uid))

      assert LazyHTML.text(document) =~ "12.5ms"
      assert Enum.count(LazyHTML.query(document, "svg")) == if(unquote(chart?), do: 1, else: 0)

      if unquote(chart?) do
        refute Enum.any?(
                 LazyHTML.attribute(LazyHTML.query(document, "[title]"), "title"),
                 &String.contains?(&1, "Insufficient history")
               )
      else
        assert [title] = LazyHTML.attribute(LazyHTML.query(document, "[title]"), "title")
        assert title =~ "12.5ms"
        assert title =~ "Insufficient history"
      end
    end
  end

  test "a caller without a sparse flag cannot render an empty or single-point chart" do
    for points <- [[], [12.5]] do
      document = render_spark(%{points: points, latest_ms: 12.5})
      assert Enum.empty?(LazyHTML.query(document, "svg"))
      assert LazyHTML.text(document) =~ "12.5ms"
    end
  end

  def query(query, _opts) do
    rows =
      if String.contains?(query, "metric_type:sweep metric_name:sweep.host.icmp_response_time_ns") do
        Process.get(:sweep_rows, [])
      else
        []
      end

    {:ok, %{"results" => rows}}
  end

  defp render_spark(spark) do
    (&Sparkline.icmp_sparkline/1)
    |> render_component(spark: spark)
    |> LazyHTML.from_fragment()
  end
end
