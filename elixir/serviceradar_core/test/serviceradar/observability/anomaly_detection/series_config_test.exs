defmodule ServiceRadar.Observability.AnomalyDetection.SeriesConfigTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.AnomalyDetection.SeriesConfig

  test "resolves metric-class defaults for RED samples" do
    tuning =
      SeriesConfig.resolve(%{
        series_key: "otel:api:http.server.duration:abc",
        metric_class: "otel.metric_point",
        subject: "otel.metrics.derived"
      })

    assert tuning.metric_group == "red"
    assert tuning.window_size == 120
    assert tuning.min_samples == 20
    assert tuning.confirm_slots == 3
  end

  test "exact series override wins over metric-class defaults" do
    tuning =
      SeriesConfig.resolve(
        %{
          series_key: "sysmon:cpu:host-1:all",
          metric_class: "sysmon.cpu",
          subject: "metrics.sysmon.cpu"
        },
        series_overrides: %{
          "sysmon:cpu:host-1:all" => %{
            "n_sigma" => "4.25",
            "confirm_slots" => "2",
            "seasonal_enabled" => "true",
            "seasonal_sensitivity" => "2.0"
          }
        }
      )

    assert tuning.metric_group == "cpu"
    assert tuning.n_sigma == 4.25
    assert tuning.confirm_slots == 2
    assert tuning.seasonal_enabled
    assert tuning.seasonal_sensitivity == 2.0
  end

  test "applies tuning to context and derives seasonal threshold from sensitivity" do
    context =
      SeriesConfig.apply_to_context(
        %{
          baseline: [1.0, 2.0, 3.0, 4.0],
          min_samples: 30,
          window_size: 300,
          n_sigma: 3.0,
          confirm_slots: 5,
          consecutive_anomalous: 0
        },
        %{
          window_size: 2,
          min_samples: 2,
          n_sigma: 4.0,
          seasonal_sensitivity: 2.0
        }
      )

    assert context.baseline == [3.0, 4.0]
    assert context.window_size == 2
    assert context.min_samples == 2
    assert context.n_sigma == 4.0
    assert context.seasonal_sensitivity == 2.0
    assert context.seasonal_n_sigma == 2.0
  end
end
