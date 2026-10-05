defmodule ServiceRadarCoreElx.GrafanaDashboardsTest do
  @moduledoc """
  The chart's Grafana dashboards lay their panels out on the 24-column grid
  without overlap, and the ingestion lanes dashboard queries only metrics that
  core-elx actually exports -- a renamed or dropped metric otherwise leaves a
  panel silently empty. (Other dashboards also chart web-ng's metrics.)
  """
  use ExUnit.Case, async: true

  @dashboards_dir Path.expand("../../../../helm/serviceradar/dashboards", __DIR__)

  setup_all do
    dashboards =
      @dashboards_dir
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Map.new(fn path -> {Path.basename(path), path |> File.read!() |> Jason.decode!()} end)

    %{dashboards: dashboards, exported: exported_metric_names()}
  end

  test "the ingestion lanes dashboard ships with panels", %{dashboards: dashboards} do
    assert %{"panels" => [_ | _]} = dashboards["serviceradar-ingestion-lanes.json"]
  end

  test "every ServiceRadar metric the ingestion lanes dashboard queries is exported by core-elx", %{
    dashboards: dashboards,
    exported: exported
  } do
    file = "serviceradar-ingestion-lanes.json"
    dashboard = Map.fetch!(dashboards, file)

    for panel <- dashboard["panels"], target <- panel["targets"] || [] do
      for metric <- referenced_serviceradar_metrics(target["expr"]) do
        assert metric in exported,
               "#{file} panel #{inspect(panel["title"])} queries #{metric}, which core-elx does not export"
      end
    end
  end

  test "panels have unique ids and do not overlap on the grid", %{dashboards: dashboards} do
    for {file, dashboard} <- dashboards do
      panels = dashboard["panels"]
      ids = Enum.map(panels, & &1["id"])
      assert ids == Enum.uniq(ids), "#{file} repeats a panel id"

      cells =
        for panel <- panels, %{"x" => x, "y" => y, "w" => w, "h" => h} = panel["gridPos"] do
          assert x >= 0 and w > 0 and x + w <= 24, "#{file} panel #{panel["id"]} leaves the grid"
          for cx <- x..(x + w - 1), cy <- y..(y + h - 1), do: {cx, cy}
        end

      flat = List.flatten(cells)
      assert length(flat) == length(Enum.uniq(flat)), "#{file} has overlapping panels"
    end
  end

  test "dashboards have unique uids and use the templated Prometheus datasource", %{dashboards: dashboards} do
    uids = Enum.map(dashboards, fn {_file, d} -> d["uid"] end)
    assert uids == Enum.uniq(uids)

    for {file, dashboard} <- dashboards, panel <- dashboard["panels"] do
      assert panel["datasource"] == %{"type" => "prometheus", "uid" => "${DS_PROMETHEUS}"},
             "#{file} panel #{panel["id"]} does not use the templated datasource"
    end
  end

  defp referenced_serviceradar_metrics(expr) when is_binary(expr) do
    ~r/\bserviceradar_[a-z0-9_]+/
    |> Regex.scan(expr)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp referenced_serviceradar_metrics(_expr), do: []

  # The names TelemetryMetricsPrometheus exports: the dotted metric name joined with
  # underscores, plus the histogram series for distributions.
  defp exported_metric_names do
    ServiceRadarCoreElx.Telemetry.metrics()
    |> Enum.flat_map(fn metric ->
      base = Enum.map_join(metric.name, "_", &to_string/1)

      case metric do
        %Telemetry.Metrics.Distribution{} -> [base, base <> "_bucket", base <> "_sum", base <> "_count"]
        _other -> [base]
      end
    end)
    |> MapSet.new()
  end
end
