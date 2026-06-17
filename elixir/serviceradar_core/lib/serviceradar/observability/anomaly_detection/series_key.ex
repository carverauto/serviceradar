defmodule ServiceRadar.Observability.AnomalyDetection.SeriesKey do
  @moduledoc """
  Reconstructs canonical anomaly series keys from edge verdict identity fields.

  The edge anomaly add-on emits a provisional producer hint plus an attested
  `source_identity` map. Core uses this module only to route the verdict onto the
  canonical causal-prediction subject; anomaly scoring remains in
  `serviceradar-anomaly-core` / `serviceradar-anomaly-addon`.
  """

  @series_dimension_excluded_keys MapSet.new([
                                    "host_id",
                                    "agent_id",
                                    "device_id",
                                    "host_ip",
                                    "host",
                                    "target",
                                    "interface_uid",
                                    "source",
                                    "payload_kind",
                                    "producer_id",
                                    "producer_kind",
                                    "available",
                                    "metric",
                                    "packet_loss"
                                  ])

  @doc """
  Computes a canonical anomaly `series_key` from an edge add-on `source_identity`.
  """
  @spec from_source_identity(map()) :: String.t() | nil
  def from_source_identity(source_identity) when is_map(source_identity) do
    case string(source_identity, "metric_class") do
      nil ->
        nil

      metric_class ->
        base = %{
          metric_name: string(source_identity, "metric_name"),
          target_device_ip: string(source_identity, "target_device_ip"),
          host_id: string(source_identity, "host_id"),
          agent_id: string(source_identity, "agent_id"),
          device_id: string(source_identity, "device_id"),
          host_ip: string(source_identity, "host_ip")
        }

        identity = resource_identity(base)
        tags = tags(source_identity)
        if_index = int(source_identity, "if_index")

        metric_class
        |> readable_identity(base, identity, tags, if_index)
        |> prefix_series_key(metric_class)
    end
  end

  def from_source_identity(_source_identity), do: nil

  defp resource_identity(%{host_id: host_id}) when is_binary(host_id), do: host_id
  defp resource_identity(%{agent_id: agent_id}) when is_binary(agent_id), do: agent_id
  defp resource_identity(%{device_id: device_id}) when is_binary(device_id), do: device_id
  defp resource_identity(%{host_ip: host_ip}) when is_binary(host_ip), do: host_ip
  defp resource_identity(_base), do: nil

  defp readable_identity(metric_class, base, identity, tags, if_index) do
    {class_component, family} = class_and_family(metric_class, base.metric_name)

    [class_component, family, identity_component(identity, base)]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(series_dimensions(tags, if_index))
    |> Enum.join(":")
  end

  defp class_and_family(metric_class, metric_name) do
    case String.split(metric_class, ".", parts: 2) do
      ["sysmon", family] when family != "" ->
        {"sysmon", family}

      ["sysmon"] ->
        {"sysmon", metric_name_family(metric_name)}

      _ ->
        {metric_class, nil}
    end
  end

  defp metric_name_family(metric_name) when is_binary(metric_name) do
    case String.split(metric_name, ".", parts: 2) do
      [family, _rest] when family != "" -> family
      _ -> nil
    end
  end

  defp metric_name_family(_metric_name), do: nil

  defp identity_component(nil, base), do: base.target_device_ip || "unknown"
  defp identity_component(identity, _base), do: identity

  defp series_dimensions(tags, if_index) do
    leading =
      ["core_id", "mount_point"]
      |> Enum.map(&string(tags, &1))
      |> Enum.reject(&is_nil/1)

    if_index =
      case if_index do
        value when is_integer(value) and value > 0 -> [Integer.to_string(value)]
        _ -> []
      end

    extra =
      tags
      |> Enum.reject(fn {key, value} ->
        key = to_string(key)

        key in ["core_id", "mount_point"] or
          MapSet.member?(@series_dimension_excluded_keys, key) or
          string_value(value) == nil
      end)
      |> Enum.sort_by(&to_string(elem(&1, 0)))
      |> Enum.map(fn {_key, value} -> string_value(value) end)

    leading ++ if_index ++ extra
  end

  defp prefix_series_key(readable_identity, metric_class) do
    if String.starts_with?(readable_identity, "#{metric_class}:") do
      readable_identity
    else
      "#{metric_class}:#{readable_identity}"
    end
  end

  defp tags(source_identity) do
    case Map.get(source_identity, "tags") do
      %{} = tags -> tags
      _ -> %{}
    end
  end

  defp string(map, key) when is_map(map), do: string_value(Map.get(map, key))
  defp string(_map, _key), do: nil

  defp string_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_value(value) when is_integer(value), do: Integer.to_string(value)
  defp string_value(value) when is_float(value), do: Float.to_string(value)
  defp string_value(_value), do: nil

  defp int(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      value when is_binary(value) -> parse_int(value)
      _ -> nil
    end
  end

  defp parse_int(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end
end
