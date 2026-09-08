defmodule ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.ReferenceLines do
  @moduledoc false

  import ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Common

  alias ServiceRadarWebNGWeb.DeviceLive.SysmonProfileData

  def sysmon_reference_lines(filter_tokens, scope, opts) do
    thresholds =
      opts
      |> Keyword.get(:thresholds)
      |> case do
        thresholds when is_map(thresholds) -> thresholds
        _ -> profile_thresholds_for_filter_tokens(filter_tokens, scope)
      end

    %{
      cpu: threshold_reference_lines(thresholds, "cpu", "CPU"),
      memory: threshold_reference_lines(thresholds, "memory", "Memory"),
      disk: threshold_reference_lines(thresholds, "disk", "Disk")
    }
  end

  defp profile_thresholds_for_filter_tokens(filter_tokens, scope) do
    with uid when is_binary(uid) <- device_uid_from_filter_tokens(filter_tokens),
         {%{profile: profile}, _available_profiles} <- SysmonProfileData.load_profile_info(scope, uid),
         thresholds when is_map(thresholds) <- Map.get(profile || %{}, :thresholds) do
      thresholds
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp device_uid_from_filter_tokens(filter_tokens) when is_list(filter_tokens) do
    Enum.find_value(filter_tokens, fn
      "uid:\"" <> rest ->
        quoted_filter_value(rest)

      "device_id:\"" <> rest ->
        quoted_filter_value(rest)

      _ ->
        nil
    end)
  end

  defp device_uid_from_filter_tokens(_filter_tokens), do: nil

  defp quoted_filter_value(rest) do
    rest
    |> String.trim_trailing("\"")
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp threshold_reference_lines(thresholds, prefix, label_prefix) when is_map(thresholds) do
    Enum.flat_map(
      [
        {:critical, "#{label_prefix} critical"},
        {:warning, "#{label_prefix} warning"}
      ],
      fn {severity, label} ->
        case threshold_value(thresholds, threshold_keys(prefix, severity)) do
          value when is_number(value) ->
            [%{value: value, label: label, severity: severity, series: nil}]

          _ ->
            []
        end
      end
    )
  end

  defp threshold_reference_lines(_thresholds, _prefix, _label_prefix), do: []

  defp threshold_keys(prefix, severity) do
    severity = Atom.to_string(severity)

    [
      "#{prefix}_#{severity}",
      "#{prefix}.#{severity}",
      "#{prefix}_usage_percent_#{severity}",
      "#{prefix}.usage_percent.#{severity}",
      "#{prefix}_used_percent_#{severity}",
      "#{prefix}.used_percent.#{severity}"
    ]
  end

  defp threshold_value(thresholds, keys) do
    thresholds
    |> map_find_value(keys)
    |> parse_number()
  end

  defp map_find_value(map, keys) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key) || atom_map_value(map, key)
    end)
  end

  defp atom_map_value(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end
end
