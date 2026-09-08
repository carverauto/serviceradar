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
                                    "packet_loss",
                                    "pid",
                                    "process_id",
                                    "start_time",
                                    "start_time_unix_nano"
                                  ])

  @doc """
  Computes a canonical anomaly `series_key` from an edge add-on `source_identity`.
  """
  @spec from_source_identity(map(), keyword()) :: String.t() | nil
  def from_source_identity(source_identity, opts \\ [])

  def from_source_identity(source_identity, opts) when is_map(source_identity) do
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
          host_ip: string(source_identity, "host_ip"),
          interface_uid: string(source_identity, "interface_uid")
        }

        identity = resource_identity(metric_class, base)
        tags = tags(source_identity)
        if_index = int(source_identity, "if_index")
        partition = partition(source_identity, opts)

        canonical_identity(base, partition, identity, tags, if_index)
    end
  end

  def from_source_identity(_source_identity, _opts), do: nil

  defp resource_identity(metric_class, base) do
    Enum.find(
      [
        base.device_id,
        snmp_target_identity(metric_class, base),
        base.host_id,
        base.agent_id,
        base.host_ip
      ],
      &is_binary/1
    )
  end

  defp snmp_target_identity(metric_class, %{target_device_ip: target_device_ip})
       when is_binary(metric_class) and is_binary(target_device_ip) do
    if metric_class == "snmp" or String.starts_with?(metric_class, "snmp.") do
      target_device_ip
    end
  end

  defp snmp_target_identity(_metric_class, _base), do: nil

  defp canonical_identity(base, partition, identity, tags, if_index) do
    [
      "v2",
      component("partition", partition),
      component("identity", identity_component(identity, base)),
      component("metric", base.metric_name),
      component("interface_uid", base.interface_uid)
    ]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(series_dimensions(tags, if_index))
    |> Enum.join("|")
  end

  defp identity_component(nil, base), do: base.target_device_ip || "unknown"
  defp identity_component(identity, _base), do: identity

  defp partition(source_identity, opts) do
    opts
    |> Keyword.get(:partition_id)
    |> string_value()
    |> Kernel.||(string(source_identity, "partition_id"))
    |> Kernel.||(string(source_identity, "partition"))
    |> Kernel.||("default")
  end

  defp series_dimensions(tags, if_index) do
    if_index =
      case if_index do
        value when is_integer(value) and value > 0 ->
          [component("if_index", Integer.to_string(value))]

        _ ->
          []
      end

    leading =
      Enum.flat_map(["core_id", "mount_point"], fn key ->
        case string(tags, key) do
          nil -> []
          value -> [tag_component(key, value)]
        end
      end)

    extra =
      tags
      |> Enum.reject(fn {key, value} ->
        key = to_string(key)

        key in ["core_id", "mount_point"] or
          MapSet.member?(@series_dimension_excluded_keys, key) or
          string_value(value) == nil
      end)
      |> Enum.sort_by(&to_string(elem(&1, 0)))
      |> Enum.map(fn {key, value} -> tag_component(to_string(key), string_value(value)) end)

    if_index ++ leading ++ extra
  end

  defp component(_name, nil), do: nil
  defp component(name, value), do: "#{name}=#{encode_component(value)}"

  defp tag_component(key, value), do: "tag_#{encode_component(key)}=#{encode_component(value)}"

  defp encode_component(value) do
    value
    |> to_string()
    |> Base.encode16(case: :lower)
  end

  defp tags(source_identity) do
    case Map.get(source_identity, "tags") do
      %{} = tags -> tags
      _ -> %{}
    end
  end

  defp string(map, key) when is_map(map), do: string_value(Map.get(map, key))

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
