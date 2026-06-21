defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.TimeseriesCounterWidthTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Metrics

  @moduletag :unit
  @moduletag :db_free

  @counter_max_32 4_294_967_295.0
  @counter_max_64 18_446_744_073_709_551_615.0

  test "uses explicit 64-bit counter width without relying on HC in the series label" do
    [{series, rates}] =
      Metrics.counter_rates(
        [
          {"customCounter", rollover_points(), %{counter_width: 64}}
        ],
        nil
      )

    assert series == "customCounter"
    assert [{_, first_rate}, {_, rate}] = rates
    assert first_rate == 0.0
    assert_in_delta rate, (@counter_max_64 - 1_000.0 + 100.0) / 60.0, 0.001
  end

  test "does not infer 64-bit counter width from HC in the series label" do
    [{series, rates}] =
      Metrics.counter_rates(
        [
          {"ifHCInOctets", rollover_points()}
        ],
        nil
      )

    assert series == "ifHCInOctets"
    assert [{_, first_rate}, {_, rate}] = rates
    assert first_rate == 0.0
    assert_in_delta rate, (@counter_max_32 - 1_000.0 + 100.0) / 60.0, 0.001
  end

  test "accepts nested PDU width metadata from map series entries" do
    [{series, rates}] =
      Metrics.counter_rates(
        [
          %{
            series: "pduWidthCounter",
            points: rollover_points(),
            metadata: %{"pdu_width" => "64"}
          }
        ],
        nil
      )

    assert series == "pduWidthCounter"
    assert [{_, first_rate}, {_, rate}] = rates
    assert first_rate == 0.0
    assert_in_delta rate, (@counter_max_64 - 1_000.0 + 100.0) / 60.0, 0.001
  end

  test "threads SRQL row counter metadata into timeseries panel specs" do
    response = %{
      "results" => [
        %{
          "timestamp" => "2026-01-01T00:00:00Z",
          "metric_name" => "customCounter",
          "value" => 1_000.0,
          "metadata" => %{"counter_width" => 64}
        },
        %{
          "timestamp" => "2026-01-01T00:01:00Z",
          "metric_name" => "customCounter",
          "value" => 100.0,
          "metadata" => %{"counter_width" => 64}
        }
      ],
      "viz" => %{
        "suggestions" => [
          %{"kind" => "timeseries", "x" => "timestamp", "y" => "value", "series" => "metric_name"}
        ]
      }
    }

    assert {:ok, assigns} = Timeseries.build(response)
    assert assigns.spec[:series_metadata] == %{"customCounter" => %{counter_width: 64}}
  end

  test "uses spec counter metadata when LiveComponent update converts counters to rates" do
    assert {:ok, socket} =
             Timeseries.update(
               %{
                 panel_assigns: %{rate_mode: :counter},
                 spec: %{series_metadata: %{"customCounter" => %{counter_width: 64}}},
                 series_points: [{"customCounter", rollover_points()}]
               },
               %Socket{}
             )

    assert [{"customCounter", [{_, first_rate}, {_, rate}]}] = socket.assigns.series_points
    assert first_rate == 0.0
    assert_in_delta rate, (@counter_max_64 - 1_000.0 + 100.0) / 60.0, 0.001
  end

  test "uses grouped series metadata when LiveComponent update converts counters to rates" do
    [first_point, second_point] =
      Enum.map(rollover_points(), fn {time, value} -> %{time: time, value: value} end)

    assert {:ok, socket} =
             Timeseries.update(
               %{
                 panel_assigns: %{
                   rate_mode: :counter,
                   series: [
                     %{
                       name: "customCounter",
                       data: [first_point, second_point],
                       metadata: %{"counter_width" => "64"}
                     }
                   ]
                 }
               },
               %Socket{}
             )

    assert [{"customCounter", [{_, first_rate}, {_, rate}]}] = socket.assigns.series_points
    assert first_rate == 0.0
    assert_in_delta rate, (@counter_max_64 - 1_000.0 + 100.0) / 60.0, 0.001
  end

  defp rollover_points do
    t0 = ~U[2026-01-01 00:00:00Z]
    t1 = DateTime.add(t0, 60, :second)

    [
      {t0, 1_000.0},
      {t1, 100.0}
    ]
  end
end
