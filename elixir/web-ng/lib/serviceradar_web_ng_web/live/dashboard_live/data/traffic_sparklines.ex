defmodule ServiceRadarWebNGWeb.DashboardLive.Data.TrafficSparklines do
  @moduledoc false

  alias ServiceRadar.Analytics.StarRocks.FlowConsumers
  alias ServiceRadar.Analytics.StarRocks.Readers

  @sparkline_points 48 * 2

  @doc """
  The throughput sparkline's buckets from the warehouse.

  Flows are warehouse-only: cut over, the sparkline reads the warehouse; not cut
  over, `Readers` returns `{:error, :starrocks_required}` and the sparkline
  renders empty rather than reading CNPG rows. It lives outside the `__using__`
  block so that block stays a list of loaders.
  """
  @spec warehouse_traffic_rows(DateTime.t(), pos_integer()) :: {:ok, [list()]} | {:error, term()}
  def warehouse_traffic_rows(cutoff, bucket_seconds) do
    Readers.fetch(:flows, %{
      cnpg: fn -> {:error, :starrocks_required} end,
      starrocks: fn -> FlowConsumers.traffic_rows(cutoff, bucket_seconds, @sparkline_points) end
    })
  end

  defmacro __using__(_opts) do
    quote do
      defp dashboard_sparklines(time_window, security_trend) do
        %{
          assets: device_activity_sparkline(time_window),
          threats: security_trend |> Enum.map(&(&1.high + &1.critical)) |> sparkline_tail(),
          network_health: service_availability_sparkline(time_window),
          camera: camera_activity_sparkline(time_window),
          survey: survey_sample_sparkline(time_window),
          throughput: flow_traffic_sparkline(time_window, :bps),
          service_health: service_availability_sparkline(time_window),
          latency: mtr_timeseries_sparkline(time_window, :latency_ms),
          packet_loss: mtr_timeseries_sparkline(time_window, :loss_pct)
        }
      rescue
        _ -> empty_sparklines()
      end

      defp empty_sparklines do
        %{
          assets: [],
          threats: [],
          network_health: [],
          camera: [],
          survey: [],
          throughput: [],
          service_health: [],
          latency: [],
          packet_loss: []
        }
      end

      defp flow_traffic_sparkline(time_window, metric) do
        seconds = bucket_seconds_for(time_window)

        case unquote(__MODULE__).warehouse_traffic_rows(
               cutoff_for_time_window(time_window),
               seconds
             ) do
          {:ok, rows} -> sparkline_values(rows, metric, seconds)
          {:error, _reason} -> []
        end
      rescue
        _ -> []
      end

      defp sparkline_values(rows, metric, seconds) do
        rows
        |> Enum.map(fn [_bucket, bytes, packets, flows] ->
          case metric do
            :bps -> to_float(bytes) * 8 / max(seconds, 1)
            :pps -> to_float(packets) / max(seconds, 1)
            :flows -> to_float(flows)
            _ -> to_float(bytes)
          end
        end)
        |> sparkline_tail()
      end
    end
  end
end
