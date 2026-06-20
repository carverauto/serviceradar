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
          max_speed_bytes_per_sec: if_speed_bytes_per_sec
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
    %{if_index: if_index, name: iface_name, max_speed_bytes_per_sec: max_speed} = fav_iface

    query =
      "in:snmp_metrics device_id:\"#{escape_value(device_uid)}\" if_index:#{if_index} " <>
        "time:last_24h bucket:5m agg:rate series:metric_name limit:#{@snmp_metrics_limit}"

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => results} = response} when is_list(results) and results != [] ->
        interface_panels = build_interface_panels(response, iface_name, if_index, max_speed)
        {panels_acc ++ interface_panels, errs}

      {:ok, %{"results" => []}} ->
        {panels_acc, errs}

      {:error, reason} ->
        {panels_acc, [format_error(reason) | errs]}

      _ ->
        {panels_acc, errs}
    end
  end

  defp build_interface_panels(srql_response, iface_name, if_index, max_speed) do
    srql_response
    |> Engine.build_panels()
    |> Enum.reject(&(&1.plugin == TablePlugin))
    |> Enum.map(fn panel ->
      assigns =
        panel.assigns
        |> Map.put(:interface_label, "#{iface_name} (ifIndex: #{if_index})")
        |> Map.put(:max_speed_bytes_per_sec, max_speed)
        |> Map.put(:chart_mode, :combined)
        |> Map.put(:rate_mode, :rate)

      %{panel | assigns: assigns}
    end)
  end

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
