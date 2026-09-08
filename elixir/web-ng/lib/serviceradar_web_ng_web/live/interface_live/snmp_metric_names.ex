defmodule ServiceRadarWebNGWeb.InterfaceLive.SnmpMetricNames do
  @moduledoc """
  IF-MIB 32-bit / 64-bit aliases used by interface charts.

  SNMP collectors store high-capacity counters as `ifHC*` while the UI still
  selects the 32-bit names. Favorites previously queried every series; drill-down
  queried only the selected 32-bit names. Those two paths then disagreed.
  """

  @hc_aliases %{
    "ifInOctets" => "ifHCInOctets",
    "ifOutOctets" => "ifHCOutOctets",
    "ifInUcastPkts" => "ifHCInUcastPkts",
    "ifOutUcastPkts" => "ifHCOutUcastPkts",
    "ifInMulticastPkts" => "ifHCInMulticastPkts",
    "ifOutMulticastPkts" => "ifHCOutMulticastPkts",
    "ifInBroadcastPkts" => "ifHCInBroadcastPkts",
    "ifOutBroadcastPkts" => "ifHCOutBroadcastPkts"
  }

  @hc_to_legacy Map.new(@hc_aliases, fn {legacy, hc} -> {hc, legacy} end)

  def base_name(name) when is_binary(name) do
    case String.split(name, "::", parts: 2) do
      [base | _] -> String.trim(base)
      _ -> name
    end
  end

  def base_name(name) when is_atom(name) and not is_nil(name), do: base_name(Atom.to_string(name))
  def base_name(_), do: ""

  def expand(metric_names) when is_list(metric_names) do
    metric_names
    |> Enum.flat_map(&expand_one/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  def expand(_metric_names), do: []

  def prefer_hc_series(series_points) when is_list(series_points) do
    present =
      MapSet.new(series_points, fn {name, _points} -> base_name(name) end)

    Enum.reject(series_points, fn {name, _points} ->
      base = base_name(name)
      hc = Map.get(@hc_aliases, base)
      is_binary(hc) and hc != base and MapSet.member?(present, hc)
    end)
  end

  def prefer_hc_series(series_points), do: series_points

  def rewrite_result_rows(rows) when is_list(rows) do
    Enum.map(rows, &rewrite_result_row/1)
  end

  def rewrite_result_rows(_rows), do: []

  def selected?(name, selected_names) when is_list(selected_names) do
    base = base_name(name)
    wanted = selected_names |> expand() |> MapSet.new()
    base != "" and MapSet.member?(wanted, base)
  end

  def selected?(_name, _selected_names), do: false

  defp expand_one(name) do
    base = base_name(name)

    cond do
      base == "" ->
        []

      Map.has_key?(@hc_aliases, base) ->
        [base, Map.fetch!(@hc_aliases, base)]

      Map.has_key?(@hc_to_legacy, base) ->
        [Map.fetch!(@hc_to_legacy, base), base]

      true ->
        [base]
    end
  end

  defp rewrite_result_row(row) when is_map(row) do
    Enum.reduce(["metric_name", "series", :metric_name, :series], row, fn key, acc ->
      case Map.get(acc, key) do
        name when is_binary(name) ->
          Map.put(acc, key, base_name(name))

        name when is_atom(name) and not is_nil(name) ->
          Map.put(acc, key, base_name(name))

        _ ->
          acc
      end
    end)
  end

  defp rewrite_result_row(row), do: row
end
