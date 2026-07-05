defmodule ServiceRadarWebNGWeb.DeviceLive.InterfaceData do
  @moduledoc false

  alias ServiceRadar.Inventory.InterfaceSettings
  alias ServiceRadarWebNGWeb.Dashboard.Engine
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Table, as: TablePlugin

  @interfaces_limit 200
  @snmp_metrics_limit 3_600

  def load_interfaces(srql_module, device_uid, scope) do
    query = default_interfaces_query(device_uid)

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        {Enum.filter(results, &is_map/1), nil}

      {:ok, other} ->
        {[], "unexpected SRQL response: #{inspect(other)}"}

      {:error, reason} ->
        {[], "SRQL error: #{format_error(reason)}"}
    end
  end

  def filter_interfaces_for_display(interfaces, device_row) when is_list(interfaces) and is_map(device_row) do
    if switch_device?(device_row) do
      front_panel = Enum.filter(interfaces, &front_panel_switch_interface?/1)

      # Keep the full list unless we found a meaningful front-panel subset.
      if length(front_panel) >= 8 and length(front_panel) < length(interfaces) do
        Enum.sort_by(front_panel, &Map.get(&1, "if_index"))
      else
        interfaces
      end
    else
      interfaces
    end
  end

  def filter_interfaces_for_display(interfaces, _device_row), do: interfaces

  def load_interface_settings(_scope, nil), do: empty_interface_settings()

  def load_interface_settings(scope, device_uid) do
    case InterfaceSettings.list_by_device(device_uid, scope: scope) do
      {:ok, settings} ->
        by_uid = Map.new(settings, &{&1.interface_uid, &1})

        favorited =
          settings
          |> Enum.filter(& &1.favorited)
          |> MapSet.new(& &1.interface_uid)

        metrics_enabled =
          settings
          |> Enum.filter(&metrics_enabled_setting?/1)
          |> MapSet.new(& &1.interface_uid)

        %{favorited: favorited, metrics_enabled: metrics_enabled, by_uid: by_uid}

      {:error, _reason} ->
        empty_interface_settings()
    end
  end

  def empty_interface_settings do
    %{favorited: MapSet.new(), metrics_enabled: MapSet.new(), by_uid: %{}}
  end

  def apply_interface_settings(interfaces, settings_by_uid) when is_list(interfaces) do
    Enum.map(interfaces, fn iface ->
      uid = Map.get(iface, "interface_uid")

      case Map.get(settings_by_uid, uid) do
        nil ->
          iface

        setting ->
          iface
          |> Map.put("metrics_enabled", metrics_enabled_setting?(setting))
          |> Map.put("favorited", setting.favorited)
          |> Map.put("metric_thresholds", setting.metric_thresholds || %{})
          |> Map.put("threshold_enabled", setting.threshold_enabled)
          |> Map.put("threshold_value", setting.threshold_value)
          |> Map.put("threshold_comparison", setting.threshold_comparison)
          |> Map.put("threshold_metric", setting.threshold_metric)
          |> Map.put("threshold_severity", setting.threshold_severity)
      end
    end)
  end

  def apply_interface_settings(interfaces, _settings_by_uid), do: interfaces

  def load_interface_metrics(_srql_module, _device_uid, favorited, _metrics_enabled, _interfaces, _scope)
      when map_size(favorited) == 0 do
    %{
      has_favorited: false,
      panels: [],
      error: nil,
      favorited_count: 0
    }
  end

  def load_interface_metrics(srql_module, device_uid, favorited_uids, metrics_enabled_uids, interfaces, scope) do
    total_favorited = MapSet.size(favorited_uids)
    enabled_favorited_uids = MapSet.intersection(favorited_uids, metrics_enabled_uids)

    if MapSet.size(enabled_favorited_uids) == 0 do
      %{
        has_favorited: total_favorited > 0,
        panels: [],
        error: nil,
        favorited_count: total_favorited,
        message: "Metrics collection is disabled for favorited interfaces."
      }
    else
      build_favorited_interface_metrics(
        srql_module,
        device_uid,
        enabled_favorited_uids,
        interfaces,
        scope,
        total_favorited
      )
    end
  end

  def load_interface_metric_section(srql_module, device_uid, interface_ref, interfaces, scope, opts \\ []) do
    case interface_if_index(interface_ref) do
      if_index when is_integer(if_index) ->
        iface = interface_for_ref(interfaces, interface_ref, if_index)
        query_interface_metric_panels(srql_module, device_uid, iface, scope, opts)

      _ ->
        nil
    end
  end

  def upsert_interface_setting(_scope, nil, _interface_uid, _attrs), do: {:error, :no_device}
  def upsert_interface_setting(_scope, _device_uid, nil, _attrs), do: {:error, :no_interface}

  def upsert_interface_setting(scope, device_uid, interface_uid, attrs) do
    InterfaceSettings.upsert(device_uid, interface_uid, attrs, scope: scope)
  end

  def bulk_update_favorites(scope, device_uid, selected_uids, favorited, current_favorites) do
    results =
      selected_uids
      |> MapSet.to_list()
      |> Enum.map(fn uid ->
        case upsert_interface_setting(scope, device_uid, uid, %{favorited: favorited}) do
          {:ok, _} -> {:ok, uid}
          {:error, _} -> {:error, uid}
        end
      end)

    success_count = Enum.count(results, fn {status, _} -> status == :ok end)

    successful_uids =
      results
      |> Enum.filter(fn {status, _} -> status == :ok end)
      |> MapSet.new(fn {_, uid} -> uid end)

    new_favorites =
      if favorited do
        MapSet.union(current_favorites, successful_uids)
      else
        MapSet.difference(current_favorites, successful_uids)
      end

    {success_count, new_favorites}
  end

  def bulk_update_metrics(scope, device_uid, selected_uids, metrics_enabled) do
    selected_uids
    |> MapSet.to_list()
    |> Enum.map(fn uid ->
      case upsert_interface_setting(scope, device_uid, uid, %{metrics_enabled: metrics_enabled}) do
        {:ok, _} -> :ok
        {:error, _} -> :error
      end
    end)
    |> Enum.count(&(&1 == :ok))
  end

  def bulk_update_tags(scope, device_uid, selected_uids, tags) do
    selected_uids
    |> MapSet.to_list()
    |> Enum.map(fn uid ->
      existing_tags =
        case InterfaceSettings.get_by_interface(device_uid, uid, scope: scope) do
          {:ok, settings} -> settings.tags || []
          _ -> []
        end

      merged_tags = Enum.uniq(existing_tags ++ tags)

      case upsert_interface_setting(scope, device_uid, uid, %{tags: merged_tags}) do
        {:ok, _} -> :ok
        {:error, _} -> :error
      end
    end)
    |> Enum.count(&(&1 == :ok))
  end

  def parse_tags(tags_string) when is_binary(tags_string) do
    tags_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def parse_tags(_), do: []

  defp switch_device?(device_row) when is_map(device_row) do
    type =
      device_row
      |> Map.get("type", "")
      |> to_string()
      |> String.downcase()
      |> String.trim()

    type_id = Map.get(device_row, "type_id")
    type in ["switch", "l2 switch"] or type_id == 10
  end

  defp front_panel_switch_interface?(iface) when is_map(iface) do
    if_index = Map.get(iface, "if_index")
    if_name = normalize_interface_label(Map.get(iface, "if_name"))
    if_descr = normalize_interface_label(Map.get(iface, "if_descr"))

    is_integer(if_index) and if_index > 0 and if_index <= 256 and
      (numeric_port_label?(if_name) or numeric_port_label?(if_descr))
  end

  defp front_panel_switch_interface?(_), do: false

  defp normalize_interface_label(nil), do: ""

  defp normalize_interface_label(value) do
    value
    |> to_string()
    |> String.trim()
  end

  defp numeric_port_label?(label) when is_binary(label) do
    label != "" and String.match?(label, ~r/^(?:port\s*)?\d+$/i)
  end

  defp metrics_enabled_setting?(setting) do
    setting.metrics_enabled == true and is_list(setting.metrics_selected) and
      setting.metrics_selected != []
  end

  defp build_favorited_interface_metrics(
         srql_module,
         device_uid,
         enabled_favorited_uids,
         interfaces,
         scope,
         total_favorited
       ) do
    favorited_interfaces =
      interfaces
      |> Enum.filter(fn iface ->
        uid = Map.get(iface, "interface_uid")

        is_binary(uid) and MapSet.member?(enabled_favorited_uids, uid) and
          is_integer(Map.get(iface, "if_index"))
      end)
      |> Enum.map(fn iface ->
        if_speed_bps = Map.get(iface, "speed_bps") || Map.get(iface, "if_speed")
        if_speed_bytes_per_sec = if is_number(if_speed_bps), do: if_speed_bps / 8

        %{
          if_index: Map.get(iface, "if_index"),
          name:
            Map.get(iface, "if_name") || Map.get(iface, "if_descr") ||
              "Interface #{Map.get(iface, "if_index")}",
          max_speed_bytes_per_sec: if_speed_bytes_per_sec,
          reference_lines: interface_reference_lines(iface, if_speed_bytes_per_sec)
        }
      end)

    if favorited_interfaces == [] do
      %{
        has_favorited: total_favorited > 0,
        panels: [],
        error: nil,
        favorited_count: total_favorited,
        message: "No interface metrics available. Favorited interfaces may not have SNMP indices."
      }
    else
      {all_panels, errors} =
        Enum.reduce(favorited_interfaces, {[], []}, fn fav_iface, {panels_acc, errs} ->
          query_interface_metrics(srql_module, device_uid, fav_iface, scope, panels_acc, errs)
        end)

      cond do
        all_panels != [] ->
          %{
            has_favorited: total_favorited > 0,
            panels: all_panels,
            error: nil,
            favorited_count: total_favorited
          }

        errors != [] ->
          %{
            has_favorited: total_favorited > 0,
            panels: [],
            error: "Failed to load metrics: #{Enum.join(Enum.uniq(errors), "; ")}",
            favorited_count: total_favorited
          }

        true ->
          %{
            has_favorited: total_favorited > 0,
            panels: [],
            error: nil,
            favorited_count: total_favorited,
            message: "No metrics data available yet. Ensure SNMP polling is configured for this device."
          }
      end
    end
  end

  defp query_interface_metrics(srql_module, device_uid, fav_iface, scope, panels_acc, errs) do
    case query_interface_metric_panels(srql_module, device_uid, fav_iface, scope, []) do
      {:ok, panels} -> {panels_acc ++ panels, errs}
      {:empty, _query} -> {panels_acc, errs}
      {:error, error} -> {panels_acc, [error | errs]}
    end
  end

  defp query_interface_metric_panels(srql_module, device_uid, fav_iface, scope, opts) do
    %{if_index: if_index, name: iface_name, max_speed_bytes_per_sec: max_speed, reference_lines: reference_lines} =
      normalize_metric_interface(fav_iface)

    query =
      "in:snmp_metrics device_id:\"#{escape_value(device_uid)}\" if_index:#{if_index} " <>
        "time:#{Keyword.get(opts, :time_range, "last_24h")} " <>
        "bucket:#{Keyword.get(opts, :bucket, "5m")} agg:rate series:metric_name limit:#{Keyword.get(opts, :limit, @snmp_metrics_limit)}"

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => results} = response} when is_list(results) and results != [] ->
        interface_panels = build_interface_panels(response, iface_name, if_index, max_speed, reference_lines)
        {:ok, interface_panels}

      {:ok, %{"results" => []}} ->
        {:empty, query}

      {:error, reason} ->
        {:error, format_error(reason)}

      _ ->
        {:empty, query}
    end
  end

  defp normalize_metric_interface(%{if_index: _if_index} = iface), do: iface

  defp normalize_metric_interface(iface) when is_map(iface) do
    if_speed_bps = Map.get(iface, "speed_bps") || Map.get(iface, "if_speed")
    if_speed_bytes_per_sec = if is_number(if_speed_bps), do: if_speed_bps / 8
    if_index = interface_if_index(iface)

    %{
      if_index: if_index,
      name: Map.get(iface, "if_name") || Map.get(iface, "if_descr") || "Interface #{if_index}",
      max_speed_bytes_per_sec: if_speed_bytes_per_sec,
      reference_lines: interface_reference_lines(iface, if_speed_bytes_per_sec)
    }
  end

  defp normalize_metric_interface(if_index) when is_integer(if_index) do
    %{
      if_index: if_index,
      name: "Interface #{if_index}",
      max_speed_bytes_per_sec: nil,
      reference_lines: []
    }
  end

  defp interface_for_ref(interfaces, ref, if_index) when is_list(interfaces) do
    Enum.find(interfaces, fn iface ->
      is_map(iface) and
        (Map.get(iface, "interface_uid") == Map.get(ref, "interface_uid") or interface_if_index(iface) == if_index)
    end) || normalize_metric_interface(if_index)
  end

  defp interface_for_ref(_interfaces, _ref, if_index), do: normalize_metric_interface(if_index)

  defp interface_if_index(%{} = row) do
    row
    |> Map.get("if_index", Map.get(row, :if_index))
    |> parse_integer()
  end

  defp interface_if_index(value), do: parse_integer(value)

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp parse_integer(_), do: nil

  defp build_interface_panels(srql_response, iface_name, if_index, _max_speed, reference_lines) do
    srql_response
    |> Engine.build_panels()
    |> Enum.reject(&(&1.plugin == TablePlugin))
    |> Enum.map(fn panel ->
      assigns =
        panel.assigns
        |> Map.put(:interface_label, "#{iface_name} (ifIndex: #{if_index})")
        # max_speed is intentionally dropped: without the synthetic capacity
        # reference line the "interface rate" footer and "(0.0%)" utilization
        # label are meaningless, and clamping rates to link capacity is what
        # pinned the chart. Charts now auto-scale to the observed traffic.
        |> Map.put(:max_speed_bytes_per_sec, nil)
        |> Map.put(:chart_mode, :combined)
        |> Map.put(:rate_mode, :rate)
        |> Map.put(:reference_lines, reference_lines)

      %{panel | assigns: assigns}
    end)
  end

  def interface_reference_lines(interface, max_speed_bytes_per_sec) when is_map(interface) do
    metric_lines =
      interface
      |> Map.get("metric_thresholds", %{})
      |> normalize_metric_thresholds()
      |> Enum.flat_map(fn {metric, config} ->
        reference_line_for_metric(metric, config, max_speed_bytes_per_sec)
      end)

    legacy_lines = legacy_reference_lines(interface, max_speed_bytes_per_sec)

    # NOTE: We intentionally do NOT emit a synthetic "Interface rate" capacity
    # reference line. Folding link capacity (e.g. 125 MB/s) into the chart
    # pinned the y-domain to capacity and squashed real KB/s–Mbps traffic to
    # ~0. Only user-defined thresholds render as reference lines now, so the
    # y-axis auto-scales to the actual data.
    metric_lines ++ legacy_lines
  end

  def interface_reference_lines(_interface, _max_speed_bytes_per_sec), do: []

  defp normalize_metric_thresholds(thresholds) when is_map(thresholds) do
    Map.new(thresholds, fn {metric, config} -> {to_string(metric), config || %{}} end)
  end

  defp normalize_metric_thresholds(_thresholds), do: %{}

  defp reference_line_for_metric(metric, config, max_speed_bytes_per_sec) when is_binary(metric) and is_map(config) do
    if threshold_config_enabled?(config) do
      case threshold_effective_value(metric, config, max_speed_bytes_per_sec) do
        value when is_number(value) ->
          [
            %{
              value: value,
              label: threshold_label(metric, config),
              severity: threshold_severity(config),
              series: metric
            }
          ]

        _ ->
          []
      end
    else
      []
    end
  end

  defp reference_line_for_metric(_metric, _config, _max_speed_bytes_per_sec), do: []

  defp threshold_config_enabled?(config) when is_map(config) do
    truthy?(config_value(config, :enabled, true)) and not is_nil(config_value(config, :comparison)) and
      not is_nil(config_value(config, :value))
  end

  defp threshold_effective_value(metric, config, max_speed_bytes_per_sec) do
    value = parse_number(config_value(config, :value))

    case {config_value(config, :threshold_type, "absolute"), traffic_metric?(metric), max_speed_bytes_per_sec} do
      {type, true, speed}
      when type in ["percentage", :percentage] and is_number(speed) and is_number(value) and speed > 0 ->
        speed * value / 100.0

      {_, _, _} ->
        value
    end
  end

  defp threshold_label(metric, config) do
    comparison = config_value(config, :comparison)
    value = config_value(config, :value)

    [metric, comparison_symbol(comparison), value]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" ", &to_string/1)
  end

  defp threshold_severity(config) do
    severity = config_value(config, :severity) || config_value(config_value(config, :event, %{}), :severity)

    severity
    |> to_string()
    |> String.downcase()
    |> case do
      "critical" -> :critical
      "error" -> :critical
      "high" -> :high
      "warning" -> :warning
      "warn" -> :warning
      "medium" -> :warning
      "low" -> :info
      "info" -> :info
      _ -> :warning
    end
  end

  defp legacy_reference_lines(interface, max_speed_bytes_per_sec) do
    if truthy?(Map.get(interface, "threshold_enabled")) do
      metric = legacy_metric_name_for(Map.get(interface, "threshold_metric"))

      config = %{
        "enabled" => true,
        "comparison" => Map.get(interface, "threshold_comparison"),
        "value" => Map.get(interface, "threshold_value"),
        "severity" => Map.get(interface, "threshold_severity")
      }

      reference_line_for_metric(metric, config, max_speed_bytes_per_sec)
    else
      []
    end
  end

  defp legacy_metric_name_for(:bandwidth_in), do: "ifInOctets"
  defp legacy_metric_name_for("bandwidth_in"), do: "ifInOctets"
  defp legacy_metric_name_for(:bandwidth_out), do: "ifOutOctets"
  defp legacy_metric_name_for("bandwidth_out"), do: "ifOutOctets"
  defp legacy_metric_name_for(:errors), do: "ifInErrors"
  defp legacy_metric_name_for("errors"), do: "ifInErrors"
  defp legacy_metric_name_for(:utilization), do: "ifInOctets"
  defp legacy_metric_name_for("utilization"), do: "ifInOctets"
  defp legacy_metric_name_for(nil), do: "ifInOctets"
  defp legacy_metric_name_for(other), do: to_string(other)

  defp traffic_metric?(metric) when metric in ["ifInOctets", "ifOutOctets", "ifHCInOctets", "ifHCOutOctets"], do: true
  defp traffic_metric?(_metric), do: false

  defp comparison_symbol(:gt), do: ">"
  defp comparison_symbol("gt"), do: ">"
  defp comparison_symbol(:gte), do: ">="
  defp comparison_symbol("gte"), do: ">="
  defp comparison_symbol(:lt), do: "<"
  defp comparison_symbol("lt"), do: "<"
  defp comparison_symbol(:lte), do: "<="
  defp comparison_symbol("lte"), do: "<="
  defp comparison_symbol(:eq), do: "="
  defp comparison_symbol("eq"), do: "="
  defp comparison_symbol(value), do: value

  defp config_value(config, key, default \\ nil)

  defp config_value(config, key, default) when is_map(config) do
    cond do
      Map.has_key?(config, key) -> Map.get(config, key)
      Map.has_key?(config, to_string(key)) -> Map.get(config, to_string(key))
      true -> default
    end
  end

  defp config_value(_config, _key, default), do: default

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp parse_number(value) when is_integer(value) or is_float(value), do: value * 1.0

  defp parse_number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp parse_number(_value), do: nil

  defp default_interfaces_query(device_uid) do
    "in:interfaces device_id:\"#{escape_value(device_uid)}\" latest:true time:last_3d " <>
      "sort:if_name:asc limit:#{@interfaces_limit}"
  end

  defp escape_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp escape_value(other), do: escape_value(to_string(other))

  defp format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  defp format_error(%ArgumentError{} = err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
