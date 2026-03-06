defmodule ServiceRadar.Observability.TimeseriesSeriesKey do
  @moduledoc false

  @volatile_tag_keys MapSet.new(["available", "metric", "packet_loss"])

  @spec build(map()) :: String.t()
  def build(attrs) when is_map(attrs) do
    attrs
    |> canonical_components()
    |> Enum.map_join("|", fn {name, value} -> encode_component(name, value) end)
    |> :erlang.md5()
    |> Base.encode16(case: :lower)
  end

  @spec dedupe_rows([map()]) :: [map()]
  def dedupe_rows(rows) when is_list(rows) do
    rows
    |> Enum.reduce(%{}, fn row, acc ->
      key = {Map.get(row, :timestamp), Map.get(row, :gateway_id), Map.get(row, :series_key)}
      Map.put(acc, key, row)
    end)
    |> Map.values()
  end

  defp canonical_components(attrs) do
    []
    |> maybe_component("metric_type", fetch(attrs, :metric_type))
    |> maybe_component("metric_name", fetch(attrs, :metric_name))
    |> maybe_component("partition", fetch(attrs, :partition))
    |> maybe_component("agent_id", fetch(attrs, :agent_id))
    |> maybe_component("device_id", fetch(attrs, :device_id))
    |> maybe_component("target_device_ip", fetch(attrs, :target_device_ip))
    |> maybe_component("if_index", fetch(attrs, :if_index))
    |> append_tag_components(fetch(attrs, :tags))
  end

  defp maybe_component(components, _name, nil), do: components
  defp maybe_component(components, _name, ""), do: components

  defp maybe_component(components, name, value) do
    components ++ [{name, normalize_value(value)}]
  end

  defp append_tag_components(components, tags) when is_map(tags) do
    tags
    |> Enum.reduce([], fn {key, value}, acc ->
      tag_key = to_string(key)
      tag_value = normalize_value(value)

      if MapSet.member?(@volatile_tag_keys, tag_key) or tag_value == "" do
        acc
      else
        [{"tag:" <> tag_key, tag_value} | acc]
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> then(&(components ++ &1))
  end

  defp append_tag_components(components, _tags), do: components

  defp encode_component(name, value) do
    "#{byte_size(name)}:#{name}=#{byte_size(value)}:#{value}"
  end

  defp fetch(attrs, key) when is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp normalize_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_value(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_value(value) when is_float(value), do: :erlang.float_to_binary(value, [:compact])
  defp normalize_value(value) when is_boolean(value), do: if(value, do: "true", else: "false")
  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value), do: to_string(value)
end
