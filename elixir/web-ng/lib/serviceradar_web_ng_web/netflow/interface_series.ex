defmodule ServiceRadarWebNGWeb.NetFlow.InterfaceSeries do
  @moduledoc false

  @type direction_row :: %{
          required(:sampler) => String.t(),
          required(:interface_name) => String.t(),
          required(:direction) => :ingress | :egress,
          required(:t) => term(),
          required(:v) => number()
        }

  @spec busier_direction_p95_bps([direction_row()], pos_integer()) :: %{
          {String.t(), String.t()} => number()
        }
  def busier_direction_p95_bps(rows, bucket_secs) when is_list(rows) do
    rows
    |> bucket_interface_direction_values()
    |> Map.new(fn {{sampler, interface_name}, buckets} ->
      p95 =
        buckets
        |> Map.values()
        |> Enum.map(fn values -> max(Map.get(values, :ingress, 0), Map.get(values, :egress, 0)) end)
        |> percentile_95()
        |> Kernel.*(8)
        |> Kernel./(max(bucket_secs, 1))

      {{sampler, interface_name}, p95}
    end)
  end

  def busier_direction_p95_bps(_rows, _bucket_secs), do: %{}

  defp bucket_interface_direction_values(rows) do
    Enum.reduce(rows, %{}, fn row, acc ->
      key = {row.sampler, row.interface_name}

      Map.update(acc, key, %{row.t => %{row.direction => row.v}}, fn buckets ->
        Map.update(buckets, row.t, %{row.direction => row.v}, &Map.put(&1, row.direction, row.v))
      end)
    end)
  end

  defp percentile_95([]), do: 0

  defp percentile_95(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    idx = min(n - 1, ceil(0.95 * n) - 1)
    Enum.at(sorted, idx) || 0
  end
end
