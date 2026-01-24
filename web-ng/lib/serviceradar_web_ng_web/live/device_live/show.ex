defmodule ServiceRadarWebNGWeb.DeviceLive.Show do
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents
  import ServiceRadarWebNGWeb.SRQLComponents, only: [srql_results_table: 1]
  require Ash.Query

  alias ServiceRadarWebNGWeb.Dashboard.Engine
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Categories, as: CategoriesPlugin
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Table, as: TablePlugin
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries, as: TimeseriesPlugin
  alias ServiceRadarWebNGWeb.SRQL.Viz
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceSNMPCredential
  alias ServiceRadar.SweepJobs.SweepHostResult
  alias ServiceRadar.AgentConfig.Compilers.SysmonCompiler
  alias ServiceRadar.SysmonProfiles.SysmonProfile
  alias ServiceRadarWebNGWeb.Helpers.InterfaceTypes
  alias ServiceRadar.Inventory.InterfaceSettings

  @default_limit 50
  @max_limit 200
  @metrics_limit 300
  @disk_panel_limit 6
  @disk_metrics_limit @metrics_limit * @disk_panel_limit
  @snmp_metrics_limit @metrics_limit * 12
  @process_limit 25
  @process_query_limit 200
  @interfaces_limit 200
  @availability_window "last_24h"
  @availability_bucket "30m"

  @impl true
  def mount(_params, _session, socket) do
    srql = %{
      enabled: true,
      entity: "devices",
      page_path: nil,
      query: nil,
      draft: nil,
      error: nil,
      viz: nil,
      loading: false,
      builder_available: false,
      builder_open: false,
      builder_supported: false,
      builder_sync: false,
      builder: %{}
    }

    {:ok,
     socket
     |> assign(:page_title, "Device")
     |> assign(:device_uid, nil)
     |> assign(:results, [])
     |> assign(:panels, [])
     |> assign(:metric_sections, [])
     |> assign(:sysmon_presence, false)
     |> assign(:sysmon_profile_info, nil)
     |> assign(:available_profiles, [])
     |> assign(:availability, nil)
     |> assign(:healthcheck_summary, nil)
     |> assign(:sweep_results, nil)
     |> assign(:process_metrics, nil)
     |> assign(:limit, @default_limit)
     |> assign(:srql, srql)
     # Edit mode
     |> assign(:editing, false)
     |> assign(:device_form, to_form(%{}, as: :device))
     |> assign(:device_snmp_credential, nil)
     |> assign(:snmp_credential_form, to_form(%{}, as: :snmp))
     # Network interfaces for dedicated tab
     |> assign(:network_interfaces, [])
     |> assign(:interfaces_error, nil)
     |> assign(:has_ifaces, false)
     # Interface selection state
     |> assign(:selected_interfaces, MapSet.new())
     |> assign(:favorited_interfaces, MapSet.new())
     |> assign(:show_interfaces_bulk_edit, false)
     |> assign(:interfaces_bulk_edit_form, to_form(%{"action" => "favorite"}, as: :bulk))
     # Interface metrics for favorited interfaces
     |> assign(:interface_metrics, nil)
     |> assign(:ip_aliases, [])
     |> assign(:ip_alias_error, nil)
     |> assign(:show_stale_aliases, false)
     # Tab state for device details
     |> assign(:active_tab, "details")}
  end

  @impl true
  def handle_params(%{"uid" => uid} = params, uri, socket) do
    limit = parse_limit(Map.get(params, "limit"), @default_limit, @max_limit)
    # Read tab from URL params, fall back to current or default
    url_tab = Map.get(params, "tab")

    requested_tab =
      if url_tab in ["details", "interfaces", "profiles", "sysmon"],
        do: url_tab,
        else: socket.assigns.active_tab

    default_query = default_device_query(uid, limit)

    query =
      params
      |> Map.get("q", default_query)
      |> to_string()
      |> String.trim()
      |> case do
        "" -> default_query
        other -> other
      end

    srql_module = srql_module()
    scope = Map.get(socket.assigns, :current_scope)

    {results, error, viz} = execute_srql_query(srql_module, query, scope)

    page_path = uri |> to_string() |> URI.parse() |> Map.get(:path)

    base_srql =
      socket.assigns.srql
      |> Map.merge(%{
        entity: "devices",
        page_path: page_path,
        query: query,
        draft: query,
        error: error,
        viz: viz,
        loading: false
      })

    srql_response = %{"results" => results, "viz" => viz}

    device_row = List.first(Enum.filter(results, &is_map/1))
    sysmon_identity = sysmon_identity(device_row, uid)
    sysmon_filters = resolve_sysmon_filter_tokens(srql_module, sysmon_identity, scope)

    metric_sections = load_metric_sections(srql_module, sysmon_filters, scope)
    sysmon_presence = sysmon_filters != []
    process_metrics = load_process_metrics(srql_module, sysmon_filters, scope)
    availability = load_availability(srql_module, uid, scope)
    healthcheck_summary = load_healthcheck_summary(srql_module, uid, scope)

    # Load sweep results for this device's IP
    device_ip = get_device_ip(results)
    sweep_results = load_sweep_results(socket.assigns.current_scope, device_ip)

    # Load sysmon profile info
    {sysmon_profile_info, available_profiles} = load_sysmon_profile_info(scope, uid)

    # Load network interfaces via SRQL
    {network_interfaces, interfaces_error} = load_interfaces(srql_module, uid, scope)

    # Load interface settings (favorites, metrics enabled)
    favorited_interfaces = load_interface_settings(scope, uid)

    # Load interface metrics for favorited interfaces
    interface_metrics =
      load_interface_metrics(srql_module, uid, favorited_interfaces, network_interfaces, scope)

    device_snmp_credential = load_device_snmp_credential(scope, uid)

    {ip_aliases, ip_alias_error} =
      load_ip_aliases(scope, uid, socket.assigns.show_stale_aliases)

    has_ifaces =
      is_binary(interfaces_error) or
        (is_list(network_interfaces) and network_interfaces != [])

    active_tab =
      if requested_tab == "interfaces" and not has_ifaces,
        do: "details",
        else: requested_tab

    srql =
      if active_tab == "interfaces" do
        srql_for_tab("interfaces", uid, limit, base_srql)
      else
        base_srql
      end

    {:noreply,
     socket
     |> assign(:device_uid, uid)
     |> assign(:limit, limit)
     |> assign(:results, results)
     |> assign(:network_interfaces, network_interfaces)
     |> assign(:interfaces_error, interfaces_error)
     |> assign(:has_ifaces, has_ifaces)
     |> assign(:favorited_interfaces, favorited_interfaces)
     |> assign(:interface_metrics, interface_metrics)
     |> assign(:ip_aliases, ip_aliases)
     |> assign(:ip_alias_error, ip_alias_error)
     |> assign(:active_tab, active_tab)
     |> assign(
       :panels,
       srql_response
       |> Engine.build_panels()
       |> drop_low_value_categories()
       |> drop_table_panels()
     )
     |> assign(:metric_sections, metric_sections)
     |> assign(:sysmon_presence, sysmon_presence)
     |> assign(:sysmon_profile_info, sysmon_profile_info)
     |> assign(:available_profiles, available_profiles)
     |> assign(:process_metrics, process_metrics)
     |> assign(:availability, availability)
     |> assign(:healthcheck_summary, healthcheck_summary)
     |> assign(:sweep_results, sweep_results)
     |> assign(:device_snmp_credential, device_snmp_credential)
     |> assign(:srql, srql)}
  end

  @impl true
  def handle_event("srql_change", %{"q" => q}, socket) do
    {:noreply, assign(socket, :srql, Map.put(socket.assigns.srql, :draft, to_string(q)))}
  end

  def handle_event("srql_submit", %{"q" => q}, socket) do
    page_path = socket.assigns.srql[:page_path] || "/devices/#{socket.assigns.device_uid}"

    query =
      q
      |> to_string()
      |> String.trim()
      |> case do
        "" -> to_string(socket.assigns.srql[:query] || "")
        other -> other
      end

    {:noreply,
     push_patch(socket,
       to: page_path <> "?" <> URI.encode_query(%{"q" => query, "limit" => socket.assigns.limit})
     )}
  end

  def handle_event("toggle_edit", _params, socket) do
    if socket.assigns.editing do
      # Cancel editing - reset form
      {:noreply,
       socket
       |> assign(:editing, false)
       |> assign(:device_form, to_form(%{}, as: :device))
       |> assign(:snmp_credential_form, to_form(%{}, as: :snmp))}
    else
      # Start editing - populate form with current device data
      device_row = List.first(Enum.filter(socket.assigns.results, &is_map/1))

      form_data =
        if device_row do
          %{
            "hostname" => Map.get(device_row, "hostname", ""),
            "ip" => Map.get(device_row, "ip", ""),
            "type" => Map.get(device_row, "type", ""),
            "vendor_name" => Map.get(device_row, "vendor_name", ""),
            "model" => Map.get(device_row, "model", ""),
            "is_managed" => Map.get(device_row, "is_managed", false),
            "is_trusted" => Map.get(device_row, "is_trusted", false),
            "tags" => format_tags_for_edit(Map.get(device_row, "tags"))
          }
        else
          %{}
        end

      {:noreply,
       socket
       |> assign(:editing, true)
       |> assign(:device_form, to_form(form_data, as: :device))
       |> assign(
         :snmp_credential_form,
         to_form(snmp_credential_form_data(socket.assigns.device_snmp_credential), as: :snmp)
       )}
    end
  end

  def handle_event("toggle_aliases", _params, socket) do
    show_stale = not socket.assigns.show_stale_aliases
    scope = socket.assigns.current_scope
    device_uid = socket.assigns.device_uid

    {ip_aliases, ip_alias_error} = load_ip_aliases(scope, device_uid, show_stale)

    {:noreply,
     socket
     |> assign(:show_stale_aliases, show_stale)
     |> assign(:ip_aliases, ip_aliases)
     |> assign(:ip_alias_error, ip_alias_error)}
  end

  def handle_event("validate_device", %{"device" => params}, socket) do
    {:noreply, assign(socket, :device_form, to_form(params, as: :device))}
  end

  def handle_event("save_device", %{"device" => params}, socket) do
    scope = socket.assigns.current_scope
    device_uid = socket.assigns.device_uid

    case update_device(scope, device_uid, params) do
      {:ok, _device} ->
        {:noreply,
         socket
         |> assign(:editing, false)
         |> put_flash(:info, "Device updated successfully.")
         |> push_patch(to: ~p"/devices/#{device_uid}")}

      {:error, %Ash.Error.Invalid{} = error} ->
        {:noreply,
         socket
         |> put_flash(:error, format_ash_error(error))}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to update device: #{inspect(reason)}")}
    end
  end

  def handle_event("snmp_form_change", %{"snmp" => params}, socket) do
    current = socket.assigns.snmp_credential_form.source || %{}
    updated = Map.merge(current, params)

    {:noreply, assign(socket, :snmp_credential_form, to_form(updated, as: :snmp))}
  end

  def handle_event("save_snmp_credentials", %{"snmp" => params}, socket) do
    scope = socket.assigns.current_scope
    device_uid = socket.assigns.device_uid
    editing = not is_nil(socket.assigns.device_snmp_credential)
    normalized = normalize_snmp_credential_params(params, editing)

    if editing or snmp_params_present?(normalized) do
      case DeviceSNMPCredential.upsert_for_device(device_uid, normalized, scope: scope) do
        {:ok, credential} ->
          {:noreply,
           socket
           |> assign(:device_snmp_credential, credential)
           |> assign(
             :snmp_credential_form,
             to_form(snmp_credential_form_data(credential), as: :snmp)
           )
           |> put_flash(:info, "SNMP credentials saved")}

        {:error, %Ash.Error.Invalid{} = error} ->
          {:noreply, put_flash(socket, :error, format_ash_error(error))}

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, "Failed to save SNMP credentials: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :info, "Provide SNMP credentials to create an override")}
    end
  end

  def handle_event("clear_snmp_credentials", _params, socket) do
    scope = socket.assigns.current_scope

    case socket.assigns.device_snmp_credential do
      nil ->
        {:noreply, socket}

      credential ->
        case Ash.destroy(credential, scope: scope) do
          :ok ->
            {:noreply,
             socket
             |> assign(:device_snmp_credential, nil)
             |> assign(:snmp_credential_form, to_form(%{}, as: :snmp))
             |> put_flash(:info, "SNMP credential override cleared")}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Failed to clear SNMP credentials: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    srql = srql_for_tab(tab, socket.assigns.device_uid, socket.assigns.limit, socket.assigns.srql)

    # Update URL with tab parameter for shareable/bookmarkable links
    path =
      if tab == "details" do
        ~p"/devices/#{socket.assigns.device_uid}"
      else
        ~p"/devices/#{socket.assigns.device_uid}?tab=#{tab}"
      end

    {:noreply,
     socket
     |> assign(:active_tab, tab)
     |> assign(:srql, srql)
     |> push_patch(to: path, replace: true)}
  end

  # ---------------------------------------------------------------------------
  # Interface Selection Events
  # ---------------------------------------------------------------------------

  def handle_event("toggle_interface_select", %{"uid" => uid}, socket) do
    selected = socket.assigns.selected_interfaces

    updated =
      if MapSet.member?(selected, uid) do
        MapSet.delete(selected, uid)
      else
        MapSet.put(selected, uid)
      end

    {:noreply, assign(socket, :selected_interfaces, updated)}
  end

  def handle_event("toggle_select_all_interfaces", _params, socket) do
    interfaces = socket.assigns.network_interfaces
    selected = socket.assigns.selected_interfaces

    all_uids =
      interfaces |> Enum.map(&Map.get(&1, "interface_uid")) |> Enum.filter(& &1) |> MapSet.new()

    updated =
      if MapSet.size(selected) == MapSet.size(all_uids) and MapSet.equal?(selected, all_uids) do
        MapSet.new()
      else
        all_uids
      end

    {:noreply, assign(socket, :selected_interfaces, updated)}
  end

  def handle_event("clear_interface_selection", _params, socket) do
    {:noreply, assign(socket, :selected_interfaces, MapSet.new())}
  end

  def handle_event("open_interfaces_bulk_edit", _params, socket) do
    {:noreply, assign(socket, :show_interfaces_bulk_edit, true)}
  end

  def handle_event("close_interfaces_bulk_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_interfaces_bulk_edit, false)
     |> assign(:interfaces_bulk_edit_form, to_form(%{"action" => "favorite"}, as: :bulk))}
  end

  def handle_event("apply_interfaces_bulk_edit", %{"bulk" => params}, socket) do
    selected = socket.assigns.selected_interfaces
    device_uid = socket.assigns.device_uid
    scope = socket.assigns.current_scope
    action = Map.get(params, "action", "favorite")

    {socket, success_count, action_label} =
      case action do
        "favorite" ->
          # Add all selected to favorites and persist
          {count, new_favorites} =
            bulk_update_favorites(
              scope,
              device_uid,
              selected,
              true,
              socket.assigns.favorited_interfaces
            )

          {assign(socket, :favorited_interfaces, new_favorites), count, "added to favorites"}

        "unfavorite" ->
          # Remove all selected from favorites and persist
          {count, new_favorites} =
            bulk_update_favorites(
              scope,
              device_uid,
              selected,
              false,
              socket.assigns.favorited_interfaces
            )

          {assign(socket, :favorited_interfaces, new_favorites), count, "removed from favorites"}

        "enable_metrics" ->
          # Enable metrics collection for all selected interfaces
          count = bulk_update_metrics(scope, device_uid, selected, true)
          {socket, count, "enabled for metrics collection"}

        "disable_metrics" ->
          # Disable metrics collection for all selected interfaces
          count = bulk_update_metrics(scope, device_uid, selected, false)
          {socket, count, "disabled for metrics collection"}

        "add_tags" ->
          # Add tags to all selected interfaces
          tags_string = Map.get(params, "tags", "")
          tags = parse_tags(tags_string)

          if tags == [] do
            {socket, 0, "tagged (no tags provided)"}
          else
            count = bulk_update_tags(scope, device_uid, selected, tags)
            {socket, count, "tagged with: #{Enum.join(tags, ", ")}"}
          end

        _ ->
          {socket, 0, "updated"}
      end

    {:noreply,
     socket
     |> assign(:show_interfaces_bulk_edit, false)
     |> assign(:selected_interfaces, MapSet.new())
     |> assign(:interfaces_bulk_edit_form, to_form(%{"action" => "favorite"}, as: :bulk))
     |> put_flash(:info, "#{success_count} interface(s) #{action_label}")}
  end

  def handle_event("toggle_interface_favorite", %{"uid" => uid}, socket) do
    favorited = socket.assigns.favorited_interfaces
    device_uid = socket.assigns.device_uid
    scope = socket.assigns.current_scope
    new_favorite_state = not MapSet.member?(favorited, uid)

    # Persist to backend
    case upsert_interface_setting(scope, device_uid, uid, %{favorited: new_favorite_state}) do
      {:ok, _setting} ->
        updated =
          if new_favorite_state do
            MapSet.put(favorited, uid)
          else
            MapSet.delete(favorited, uid)
          end

        {:noreply, assign(socket, :favorited_interfaces, updated)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update favorite status")}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp format_tags_for_edit(nil), do: ""
  defp format_tags_for_edit(tags) when is_list(tags), do: Enum.join(tags, "\n")

  defp format_tags_for_edit(tags) when is_map(tags) do
    Enum.map_join(tags, "\n", fn {k, v} -> if v, do: "#{k}=#{v}", else: k end)
  end

  defp format_tags_for_edit(_), do: ""

  defp load_device_snmp_credential(_scope, nil), do: nil

  defp load_device_snmp_credential(scope, device_uid) do
    case DeviceSNMPCredential.get_by_device(device_uid, scope: scope) do
      {:ok, credential} -> credential
      {:error, _} -> nil
    end
  end

  defp snmp_credential_form_data(nil) do
    %{
      "version" => "v2c",
      "username" => "",
      "security_level" => "no_auth_no_priv",
      "auth_protocol" => "",
      "priv_protocol" => ""
    }
  end

  defp snmp_credential_form_data(%DeviceSNMPCredential{} = credential) do
    %{
      "version" => to_string(credential.version || :v2c),
      "username" => credential.username || "",
      "security_level" => to_string(credential.security_level || :no_auth_no_priv),
      "auth_protocol" => to_string(credential.auth_protocol || ""),
      "priv_protocol" => to_string(credential.priv_protocol || "")
    }
  end

  defp normalize_snmp_credential_params(params, editing) do
    params =
      if editing do
        drop_blank(params, ["community", "auth_password", "priv_password"])
      else
        params
      end

    params =
      case Map.get(params, "version") do
        nil -> Map.put(params, "version", "v2c")
        "" -> Map.put(params, "version", "v2c")
        _ -> params
      end

    case Map.get(params, "version") do
      "v1" ->
        Map.drop(params, [
          "username",
          "security_level",
          "auth_protocol",
          "auth_password",
          "priv_protocol",
          "priv_password"
        ])

      "v2c" ->
        Map.drop(params, [
          "username",
          "security_level",
          "auth_protocol",
          "auth_password",
          "priv_protocol",
          "priv_password"
        ])

      "v3" ->
        Map.drop(params, ["community"])

      _ ->
        params
    end
  end

  defp snmp_params_present?(params) do
    Enum.any?(["community", "username", "auth_password", "priv_password"], fn key ->
      value = Map.get(params, key)
      is_binary(value) and String.trim(value) != ""
    end)
  end

  defp drop_blank(params, keys) do
    Enum.reduce(keys, params, fn key, acc ->
      case Map.get(acc, key) do
        nil -> acc
        "" -> Map.delete(acc, key)
        _ -> acc
      end
    end)
  end

  defp load_interfaces(srql_module, device_uid, scope) do
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

  defp load_interface_settings(_scope, nil), do: MapSet.new()

  defp load_interface_settings(scope, device_uid) do
    case InterfaceSettings.list_by_device(device_uid, scope: scope) do
      {:ok, settings} ->
        settings
        |> Enum.filter(& &1.favorited)
        |> Enum.map(& &1.interface_uid)
        |> MapSet.new()

      {:error, _reason} ->
        MapSet.new()
    end
  end

  defp load_interface_metrics(_srql_module, _device_uid, favorited, _interfaces, _scope)
       when map_size(favorited) == 0 do
    %{
      has_favorited: false,
      panels: [],
      error: nil,
      favorited_count: 0
    }
  end

  defp load_interface_metrics(srql_module, device_uid, favorited_uids, interfaces, scope) do
    # Get the favorited interfaces with their if_index, name, and speed
    favorited_interfaces =
      interfaces
      |> Enum.filter(fn iface ->
        uid = Map.get(iface, "interface_uid")

        is_binary(uid) and MapSet.member?(favorited_uids, uid) and
          is_integer(Map.get(iface, "if_index"))
      end)
      |> Enum.map(fn iface ->
        # Get interface speed for proper graph scaling (bps -> bytes per second)
        if_speed_bps = Map.get(iface, "speed_bps") || Map.get(iface, "if_speed")
        if_speed_bytes_per_sec = if is_number(if_speed_bps), do: if_speed_bps / 8, else: nil

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
        has_favorited: true,
        panels: [],
        error: nil,
        favorited_count: MapSet.size(favorited_uids),
        message: "No interface metrics available. Favorited interfaces may not have SNMP indices."
      }
    else
      # Query SNMP metrics for each favorited interface separately and build panels per interface
      # Use agg:max to pull the latest counter values per bucket; rate deltas are calculated in UI
      {all_panels, errors} =
        Enum.reduce(favorited_interfaces, {[], []}, fn fav_iface, {panels_acc, errs} ->
          query_interface_metrics(srql_module, device_uid, fav_iface, scope, panels_acc, errs)
        end)

      cond do
        all_panels != [] ->
          %{
            has_favorited: true,
            panels: all_panels,
            error: nil,
            favorited_count: MapSet.size(favorited_uids)
          }

        errors != [] ->
          %{
            has_favorited: true,
            panels: [],
            error: "Failed to load metrics: #{Enum.join(Enum.uniq(errors), "; ")}",
            favorited_count: MapSet.size(favorited_uids)
          }

        true ->
          %{
            has_favorited: true,
            panels: [],
            error: nil,
            favorited_count: MapSet.size(favorited_uids),
            message:
              "No metrics data available yet. Ensure SNMP polling is configured for this device."
          }
      end
    end
  end

  # Helper to query metrics for a single interface (extracted to reduce nesting depth)
  defp query_interface_metrics(srql_module, device_uid, fav_iface, scope, panels_acc, errs) do
    %{if_index: if_index, name: iface_name, max_speed_bytes_per_sec: max_speed} = fav_iface

    query =
      "in:snmp_metrics device_id:\"#{escape_value(device_uid)}\" if_index:#{if_index} " <>
        "time:last_24h bucket:5m agg:max series:metric_name limit:#{@snmp_metrics_limit}"

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

  # Build panels for interface metrics (extracted to reduce nesting depth)
  # Takes full SRQL response (including viz) to properly handle series grouping
  defp build_interface_panels(srql_response, iface_name, if_index, max_speed) do
    Engine.build_panels(srql_response)
    |> Enum.reject(&(&1.plugin == TablePlugin))
    |> Enum.map(fn panel ->
      assigns =
        panel.assigns
        |> Map.put(:interface_label, "#{iface_name} (ifIndex: #{if_index})")
        |> Map.put(:max_speed_bytes_per_sec, max_speed)
        # Enable combined chart mode for traffic metrics (inbound + outbound on same chart)
        |> Map.put(:chart_mode, :combined)
        |> Map.put(:rate_mode, :counter)

      %{panel | assigns: assigns}
    end)
  end

  defp upsert_interface_setting(_scope, nil, _interface_uid, _attrs), do: {:error, :no_device}
  defp upsert_interface_setting(_scope, _device_uid, nil, _attrs), do: {:error, :no_interface}

  defp upsert_interface_setting(scope, device_uid, interface_uid, attrs) do
    InterfaceSettings.upsert(device_uid, interface_uid, attrs, scope: scope)
  end

  defp bulk_update_favorites(scope, device_uid, selected_uids, favorited, current_favorites) do
    # Persist each selected interface's favorite status
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

    # Update the MapSet based on success
    successful_uids =
      results
      |> Enum.filter(fn {status, _} -> status == :ok end)
      |> Enum.map(fn {_, uid} -> uid end)
      |> MapSet.new()

    new_favorites =
      if favorited do
        MapSet.union(current_favorites, successful_uids)
      else
        MapSet.difference(current_favorites, successful_uids)
      end

    {success_count, new_favorites}
  end

  defp bulk_update_metrics(scope, device_uid, selected_uids, metrics_enabled) do
    # Persist each selected interface's metrics_enabled status
    results =
      selected_uids
      |> MapSet.to_list()
      |> Enum.map(fn uid ->
        case upsert_interface_setting(scope, device_uid, uid, %{metrics_enabled: metrics_enabled}) do
          {:ok, _} -> :ok
          {:error, _} -> :error
        end
      end)

    Enum.count(results, &(&1 == :ok))
  end

  defp bulk_update_tags(scope, device_uid, selected_uids, tags) do
    # Add tags to each selected interface (preserving existing tags)
    results =
      selected_uids
      |> MapSet.to_list()
      |> Enum.map(fn uid ->
        # First get existing settings to merge tags
        existing_tags =
          case InterfaceSettings.get_by_interface(device_uid, uid, actor: scope) do
            {:ok, settings} -> settings.tags || []
            _ -> []
          end

        merged_tags = Enum.uniq(existing_tags ++ tags)

        case upsert_interface_setting(scope, device_uid, uid, %{tags: merged_tags}) do
          {:ok, _} -> :ok
          {:error, _} -> :error
        end
      end)

    Enum.count(results, &(&1 == :ok))
  end

  defp parse_tags(tags_string) when is_binary(tags_string) do
    tags_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp parse_tags(_), do: []

  defp load_ip_aliases(_scope, nil, _show_stale), do: {[], nil}
  defp load_ip_aliases(nil, _device_uid, _show_stale), do: {[], "Scope unavailable"}

  defp load_ip_aliases(scope, device_uid, show_stale) do
    require Ash.Query

    query =
      DeviceAliasState
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> Ash.Query.filter(device_id == ^device_uid and alias_type == :ip)
      |> maybe_filter_alias_states(show_stale)
      |> Ash.Query.sort(alias_value: :asc)

    case Ash.read(query, scope: scope) do
      {:ok, aliases} -> {aliases, nil}
      {:error, reason} -> {[], format_error(reason)}
    end
  end

  defp maybe_filter_alias_states(query, true), do: query

  defp maybe_filter_alias_states(query, false) do
    Ash.Query.filter(query, state in [:detected, :confirmed, :updated])
  end

  @impl true
  def render(assigns) do
    device_row = List.first(Enum.filter(assigns.results, &is_map/1))

    assigns =
      assigns
      |> assign(:device_row, device_row)
      |> assign(:can_edit, can_edit_device?(assigns.current_scope))
      |> assign(:sysmon_metrics_visible, sysmon_metrics_visible?(assigns))
      |> assign(
        :metric_sections_to_render,
        if sysmon_metrics_visible?(assigns) do
          Enum.filter(assigns.metric_sections, fn section ->
            is_binary(Map.get(section, :error)) or
              Map.get(section, :panels, []) != [] or Map.get(section, :rows, []) != []
          end)
        else
          []
        end
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6">
        <%!-- Breadcrumb --%>
        <nav class="text-sm breadcrumbs mb-4">
          <ul>
            <li><.link navigate={~p"/devices"}>Devices</.link></li>
            <li :if={@active_tab == "details"}>
              <span class="text-base-content/70">{device_display_name(@device_row)}</span>
            </li>
            <li :if={@active_tab != "details"}>
              <.link navigate={~p"/devices/#{@device_uid}"}>{device_display_name(@device_row)}</.link>
            </li>
            <li :if={@active_tab == "interfaces"} class="text-base-content/70">Interfaces</li>
            <li :if={@active_tab == "profiles"} class="text-base-content/70">Profiles</li>
            <li :if={@active_tab == "sysmon"} class="text-base-content/70">System Monitor</li>
          </ul>
        </nav>

        <.header>
          Device
          <:subtitle>
            <span class="flex items-center gap-2">
              <span class="font-mono text-xs">{@device_uid}</span>
              <span
                :if={agent_device?(@device_row)}
                class="inline-flex items-center gap-1 rounded-full bg-accent/10 px-2 py-0.5 text-[11px] font-semibold text-accent"
              >
                <.icon name="hero-bolt" class="size-3" /> Agent
              </span>
            </span>
          </:subtitle>
          <:actions>
            <.ui_button
              :if={@can_edit and not @editing}
              phx-click="toggle_edit"
              variant="outline"
              size="sm"
            >
              <.icon name="hero-pencil" class="size-4" /> Edit
            </.ui_button>
            <.ui_button href={~p"/devices"} variant="ghost" size="sm">Back to devices</.ui_button>
          </:actions>
        </.header>

        <div class="grid grid-cols-1 gap-4">
          <div :if={is_nil(@device_row)} class="text-sm text-base-content/70 p-4">
            No device row returned for this query.
          </div>
          
    <!-- View Mode -->
          <div
            :if={is_map(@device_row) and not @editing}
            class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-4"
          >
            <div class="flex flex-wrap gap-x-6 gap-y-2 text-sm">
              <.kv_inline label="Hostname" value={Map.get(@device_row, "hostname")} />
              <.kv_inline label="IP" value={Map.get(@device_row, "ip")} mono />
              <.kv_inline label="Type" value={Map.get(@device_row, "type")} />
              <.kv_inline label="Vendor" value={Map.get(@device_row, "vendor_name")} />
              <.kv_inline label="Model" value={Map.get(@device_row, "model")} />
              <.kv_inline
                :if={agent_device?(@device_row)}
                label="Agent"
                value={agent_label(@device_row)}
                mono
              />
              <.kv_inline label="Gateway" value={Map.get(@device_row, "gateway_id")} mono />
              <.kv_inline label="Last Seen" value={Map.get(@device_row, "last_seen")} mono />
            </div>
          </div>
          
    <!-- Edit Mode -->
          <div
            :if={is_map(@device_row) and @editing}
            class="rounded-xl border border-primary/30 bg-base-100 shadow-sm"
          >
            <div class="px-4 py-3 border-b border-base-200 bg-primary/5 flex items-center justify-between">
              <div class="flex items-center gap-2">
                <.icon name="hero-pencil-square" class="size-4 text-primary" />
                <span class="text-sm font-semibold">Edit Device Details</span>
              </div>
              <div class="flex items-center gap-2">
                <.ui_button phx-click="toggle_edit" variant="ghost" size="xs">
                  Cancel
                </.ui_button>
                <.ui_button type="submit" form="device-edit-form" variant="primary" size="xs">
                  <.icon name="hero-check" class="size-3" /> Save
                </.ui_button>
              </div>
            </div>

            <.form
              for={@device_form}
              id="device-edit-form"
              phx-change="validate_device"
              phx-submit="save_device"
              class="p-4"
            >
              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                <div class="form-control">
                  <label class="label py-1">
                    <span class="label-text text-xs font-medium">Hostname</span>
                  </label>
                  <input
                    type="text"
                    name="device[hostname]"
                    value={@device_form[:hostname].value}
                    class="input input-bordered input-sm"
                    phx-debounce="300"
                  />
                </div>

                <div class="form-control">
                  <label class="label py-1">
                    <span class="label-text text-xs font-medium">IP Address</span>
                  </label>
                  <input
                    type="text"
                    name="device[ip]"
                    value={@device_form[:ip].value}
                    class="input input-bordered input-sm font-mono"
                    phx-debounce="300"
                  />
                </div>

                <div class="form-control">
                  <label class="label py-1">
                    <span class="label-text text-xs font-medium">Type</span>
                  </label>
                  <select name="device[type]" class="select select-bordered select-sm">
                    <option value="">Select type...</option>
                    <option value="server" selected={@device_form[:type].value == "server"}>
                      Server
                    </option>
                    <option value="workstation" selected={@device_form[:type].value == "workstation"}>
                      Workstation
                    </option>
                    <option value="router" selected={@device_form[:type].value == "router"}>
                      Router
                    </option>
                    <option value="switch" selected={@device_form[:type].value == "switch"}>
                      Switch
                    </option>
                    <option value="firewall" selected={@device_form[:type].value == "firewall"}>
                      Firewall
                    </option>
                    <option value="printer" selected={@device_form[:type].value == "printer"}>
                      Printer
                    </option>
                    <option value="other" selected={@device_form[:type].value == "other"}>
                      Other
                    </option>
                  </select>
                </div>

                <div class="form-control">
                  <label class="label py-1">
                    <span class="label-text text-xs font-medium">Vendor</span>
                  </label>
                  <input
                    type="text"
                    name="device[vendor_name]"
                    value={@device_form[:vendor_name].value}
                    class="input input-bordered input-sm"
                    phx-debounce="300"
                  />
                </div>

                <div class="form-control">
                  <label class="label py-1">
                    <span class="label-text text-xs font-medium">Model</span>
                  </label>
                  <input
                    type="text"
                    name="device[model]"
                    value={@device_form[:model].value}
                    class="input input-bordered input-sm"
                    phx-debounce="300"
                  />
                </div>

                <div class="form-control">
                  <label class="label py-1">
                    <span class="label-text text-xs font-medium">Gateway</span>
                  </label>
                  <input
                    type="text"
                    value={Map.get(@device_row, "gateway_id", "")}
                    class="input input-bordered input-sm font-mono bg-base-200"
                    disabled
                  />
                  <label class="label py-0">
                    <span class="label-text-alt text-xs text-base-content/50">Read-only</span>
                  </label>
                </div>

                <div class="form-control">
                  <label class="label py-1">
                    <span class="label-text text-xs font-medium">Managed</span>
                  </label>
                  <input
                    type="hidden"
                    name="device[is_managed]"
                    value={if agent_device?(@device_row), do: "true", else: "false"}
                  />
                  <label class="inline-flex items-center gap-2 text-xs">
                    <input
                      type="checkbox"
                      name="device[is_managed]"
                      value="true"
                      checked={truthy?(@device_form[:is_managed].value)}
                      disabled={agent_device?(@device_row)}
                      class="checkbox checkbox-xs checkbox-primary"
                    />
                    <span>Mark as managed</span>
                  </label>
                  <label :if={agent_device?(@device_row)} class="label py-0">
                    <span class="label-text-alt text-xs text-base-content/50">
                      Agent devices are always managed.
                    </span>
                  </label>
                </div>

                <div class="form-control">
                  <label class="label py-1">
                    <span class="label-text text-xs font-medium">Trusted</span>
                  </label>
                  <input type="hidden" name="device[is_trusted]" value="false" />
                  <label class="inline-flex items-center gap-2 text-xs">
                    <input
                      type="checkbox"
                      name="device[is_trusted]"
                      value="true"
                      checked={truthy?(@device_form[:is_trusted].value)}
                      class="checkbox checkbox-xs checkbox-primary"
                    />
                    <span>Mark as trusted</span>
                  </label>
                </div>
              </div>

              <div class="form-control mt-4">
                <label class="label py-1">
                  <span class="label-text text-xs font-medium">Tags</span>
                  <span class="label-text-alt text-xs text-base-content/50">
                    One per line (key or key=value)
                  </span>
                </label>
                <textarea
                  name="device[tags]"
                  class="textarea textarea-bordered textarea-sm h-20"
                  phx-debounce="300"
                >{@device_form[:tags].value}</textarea>
              </div>
            </.form>

            <div class="border-t border-base-200 px-4 py-4">
              <div class="flex items-center justify-between mb-4">
                <div class="flex items-center gap-2">
                  <.icon name="hero-lock-closed" class="size-4 text-base-content/60" />
                  <span class="text-sm font-semibold">SNMP Credentials Override</span>
                  <span
                    :if={@device_snmp_credential}
                    class="inline-flex items-center rounded-full bg-success/10 px-2 py-0.5 text-[11px] font-semibold text-success"
                  >
                    Override active
                  </span>
                </div>
                <.ui_button
                  :if={@device_snmp_credential}
                  type="button"
                  variant="ghost"
                  size="xs"
                  phx-click="clear_snmp_credentials"
                >
                  Clear Override
                </.ui_button>
              </div>

              <.form
                for={@snmp_credential_form}
                id="device-snmp-credential-form"
                phx-change="snmp_form_change"
                phx-submit="save_snmp_credentials"
                class="space-y-4"
              >
                <% snmp_version =
                  Phoenix.HTML.Form.input_value(@snmp_credential_form, :version) || "v2c" %>

                <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <div>
                    <label class="label">
                      <span class="label-text text-xs font-medium">SNMP Version</span>
                    </label>
                    <.input
                      type="select"
                      field={@snmp_credential_form[:version]}
                      class="select select-bordered select-sm w-full"
                      options={[
                        {"SNMPv1", "v1"},
                        {"SNMPv2c", "v2c"},
                        {"SNMPv3", "v3"}
                      ]}
                    />
                  </div>
                </div>

                <%= if snmp_version in ["v1", "v2c"] do %>
                  <div>
                    <label class="label">
                      <span class="label-text text-xs font-medium">Community</span>
                    </label>
                    <.input
                      type="password"
                      name="snmp[community]"
                      value=""
                      class="input input-bordered input-sm w-full"
                      placeholder={
                        if @device_snmp_credential,
                          do: "Leave blank to keep existing",
                          else: "e.g., public"
                      }
                      autocomplete="off"
                    />
                    <label class="label py-0">
                      <span class="label-text-alt text-xs text-base-content/50">
                        Credentials are encrypted at rest.
                      </span>
                    </label>
                  </div>
                <% else %>
                  <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <div>
                      <label class="label">
                        <span class="label-text text-xs font-medium">Username</span>
                      </label>
                      <.input
                        type="text"
                        field={@snmp_credential_form[:username]}
                        class="input input-bordered input-sm w-full"
                      />
                    </div>
                    <div>
                      <label class="label">
                        <span class="label-text text-xs font-medium">Security Level</span>
                      </label>
                      <.input
                        type="select"
                        field={@snmp_credential_form[:security_level]}
                        class="select select-bordered select-sm w-full"
                        options={[
                          {"No Auth, No Privacy", "no_auth_no_priv"},
                          {"Auth, No Privacy", "auth_no_priv"},
                          {"Auth + Privacy", "auth_priv"}
                        ]}
                      />
                    </div>
                  </div>

                  <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <div>
                      <label class="label">
                        <span class="label-text text-xs font-medium">Auth Protocol</span>
                      </label>
                      <.input
                        type="select"
                        field={@snmp_credential_form[:auth_protocol]}
                        class="select select-bordered select-sm w-full"
                        options={[
                          {"MD5", "md5"},
                          {"SHA", "sha"},
                          {"SHA-224", "sha224"},
                          {"SHA-256", "sha256"},
                          {"SHA-384", "sha384"},
                          {"SHA-512", "sha512"}
                        ]}
                      />
                    </div>
                    <div>
                      <label class="label">
                        <span class="label-text text-xs font-medium">Auth Password</span>
                      </label>
                      <.input
                        type="password"
                        name="snmp[auth_password]"
                        value=""
                        class="input input-bordered input-sm w-full"
                        placeholder={
                          if @device_snmp_credential,
                            do: "Leave blank to keep existing",
                            else: "Auth password"
                        }
                        autocomplete="off"
                      />
                    </div>
                  </div>

                  <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <div>
                      <label class="label">
                        <span class="label-text text-xs font-medium">Privacy Protocol</span>
                      </label>
                      <.input
                        type="select"
                        field={@snmp_credential_form[:priv_protocol]}
                        class="select select-bordered select-sm w-full"
                        options={[
                          {"DES", "des"},
                          {"AES", "aes"},
                          {"AES-192", "aes192"},
                          {"AES-256", "aes256"}
                        ]}
                      />
                    </div>
                    <div>
                      <label class="label">
                        <span class="label-text text-xs font-medium">Privacy Password</span>
                      </label>
                      <.input
                        type="password"
                        name="snmp[priv_password]"
                        value=""
                        class="input input-bordered input-sm w-full"
                        placeholder={
                          if @device_snmp_credential,
                            do: "Leave blank to keep existing",
                            else: "Privacy password"
                        }
                        autocomplete="off"
                      />
                    </div>
                  </div>
                <% end %>

                <div class="flex items-center gap-2">
                  <.ui_button type="submit" variant="outline" size="xs">
                    Save SNMP Credentials
                  </.ui_button>
                  <span class="text-xs text-base-content/50">
                    Overrides take precedence over profile credentials.
                  </span>
                </div>
              </.form>
            </div>
          </div>
          
    <!-- Tabs Navigation (show if sysmon or interfaces present) -->
          <div :if={(@sysmon_presence or @has_ifaces) and is_map(@device_row)} class="tabs tabs-box">
            <button
              type="button"
              phx-click="switch_tab"
              phx-value-tab="details"
              class={["tab", @active_tab == "details" && "tab-active"]}
            >
              <.icon name="hero-document-text" class="size-4 mr-1.5" /> Details
            </button>
            <button
              :if={@has_ifaces}
              type="button"
              phx-click="switch_tab"
              phx-value-tab="interfaces"
              class={["tab", @active_tab == "interfaces" && "tab-active"]}
            >
              <.icon name="hero-arrows-right-left" class="size-4 mr-1.5" /> Interfaces
            </button>
            <button
              :if={@sysmon_presence}
              type="button"
              phx-click="switch_tab"
              phx-value-tab="profiles"
              class={["tab", @active_tab == "profiles" && "tab-active"]}
            >
              <.icon name="hero-cog-6-tooth" class="size-4 mr-1.5" /> Profiles
            </button>
          </div>
          
    <!-- Details Tab Content -->
          <div :if={@active_tab == "details" or not (@sysmon_presence or @has_ifaces)}>
            <div class="grid grid-cols-1 gap-4">
              <.ocsf_info_section :if={is_map(@device_row)} device_row={@device_row} />

              <.agents_section :if={is_map(@device_row)} device_row={@device_row} />

              <.availability_section :if={is_map(@availability)} availability={@availability} />

              <.healthcheck_section
                :if={is_map(@healthcheck_summary)}
                summary={@healthcheck_summary}
              />

              <.sweep_status_section :if={is_map(@sweep_results)} sweep_results={@sweep_results} />

              <.ip_aliases_section
                :if={is_list(@ip_aliases)}
                aliases={@ip_aliases}
                show_stale={@show_stale_aliases}
                error={@ip_alias_error}
              />

              <%= for section <- @metric_sections_to_render do %>
                <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
                  <div class="px-4 py-3 border-b border-base-200 flex items-center justify-between gap-3">
                    <div class="flex items-center gap-3">
                      <span class="text-sm font-semibold">{section.title}</span>
                      <span class="text-xs text-base-content/50">{section.subtitle}</span>
                    </div>
                    <div class="flex items-center gap-3">
                      <div
                        :if={is_map(Map.get(section, :header_stats))}
                        class="flex items-center gap-2 text-[11px] text-base-content/60"
                      >
                        <% stats = Map.get(section, :header_stats) %>
                        <span class="font-mono">min {format_pct(Map.get(stats, :min))}%</span>
                        <span class="font-mono">avg {format_pct(Map.get(stats, :avg))}%</span>
                        <span class="font-mono">max {format_pct(Map.get(stats, :max))}%</span>
                      </div>
                      <div
                        :if={is_number(Map.get(section, :header_value))}
                        class="flex items-center gap-2"
                      >
                        <% header_value = Map.get(section, :header_value) %>
                        <div class="h-1.5 w-20 rounded-full bg-base-200 overflow-hidden">
                          <div
                            class="h-full bg-accent"
                            style={"width: #{percent_width(header_value)}%"}
                          />
                        </div>
                        <span class="text-xs font-mono">{format_pct(header_value)}%</span>
                      </div>
                    </div>
                  </div>

                  <div :if={is_binary(section.error)} class="px-4 py-3 text-sm text-base-content/70">
                    {section.error}
                  </div>

                  <div :if={is_nil(section.error)}>
                    <%= if section.key == "processes" do %>
                      <.srql_results_table
                        id={"device-#{@device_uid}-processes"}
                        rows={Map.get(section, :rows, [])}
                        columns={["process", "pid", "cpu_pct", "memory_pct"]}
                        container={false}
                        empty_message="No process metrics yet."
                      />
                    <% else %>
                      <%= for panel <- section.panels do %>
                        <.live_component
                          module={panel.plugin}
                          id={"device-#{@device_uid}-#{section.key}-#{panel.id}"}
                          title={Map.get(panel, :title) || section.title}
                          panel_assigns={Map.put(panel.assigns, :compact, true)}
                        />
                      <% end %>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <.process_metrics_section
                :if={@sysmon_metrics_visible and is_list(@process_metrics)}
                metrics={@process_metrics}
              />

              <%= for panel <- @panels do %>
                <%= if panel.plugin == TablePlugin and length(@results) == 1 and is_map(@device_row) do %>
                  <.device_properties_card row={@device_row} />
                <% else %>
                  <.live_component
                    module={panel.plugin}
                    id={"device-#{panel.id}"}
                    title={panel.title}
                    panel_assigns={panel.assigns}
                  />
                <% end %>
              <% end %>
            </div>
          </div>
          
    <!-- Interfaces Tab Content -->
          <div :if={@active_tab == "interfaces" and @has_ifaces}>
            <.interfaces_tab_content
              interfaces={@network_interfaces}
              error={@interfaces_error}
              selected_interfaces={@selected_interfaces}
              favorited_interfaces={@favorited_interfaces}
              device_uid={@device_uid}
              interface_metrics={@interface_metrics}
            />
          </div>
          
    <!-- Profiles Tab Content (only when sysmon is active) -->
          <div :if={@active_tab == "profiles" and @sysmon_presence}>
            <div class="grid grid-cols-1 gap-4">
              <.sysmon_profile_card
                :if={is_map(@sysmon_profile_info)}
                profile_info={@sysmon_profile_info}
                available_profiles={@available_profiles}
                device_uid={@device_uid}
              />
            </div>
          </div>
        </div>
      </div>

      <%!-- Interfaces Bulk Edit Modal --%>
      <.interfaces_bulk_edit_modal
        :if={@show_interfaces_bulk_edit}
        form={@interfaces_bulk_edit_form}
        selected_count={MapSet.size(@selected_interfaces)}
      />
    </Layouts.app>
    """
  end

  attr :row, :map, required: true

  defp device_properties_card(assigns) do
    row = assigns.row || %{}

    keys =
      row
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    # Exclude metadata and fields already shown in the header card
    excluded = [
      "metadata",
      "hostname",
      "ip",
      "gateway_id",
      "last_seen",
      "os_info",
      "version_info",
      "device_id"
    ]

    keys = Enum.reject(keys, &(&1 in excluded))

    # Order remaining keys nicely
    preferred = [
      "uid",
      "agent_id",
      "device_type",
      "service_type",
      "service_status",
      "is_available",
      "last_heartbeat"
    ]

    {preferred_keys, other_keys} =
      Enum.split_with(keys, fn k -> k in preferred end)

    ordered_keys =
      preferred
      |> Enum.filter(&(&1 in preferred_keys))
      |> Kernel.++(Enum.sort(other_keys))

    # Only show if there are properties to display
    assigns =
      assigns
      |> assign(:ordered_keys, ordered_keys)
      |> assign(:row, row)
      |> assign(:has_properties, ordered_keys != [])

    ~H"""
    <div :if={@has_properties} class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
      <div class="px-4 py-3 border-b border-base-200 flex items-center justify-between">
        <span class="text-sm font-semibold">Device Properties</span>
        <span class="text-xs text-base-content/50">{length(@ordered_keys)} fields</span>
      </div>

      <div class="p-4">
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-x-6 gap-y-1.5 text-sm">
          <%= for key <- @ordered_keys do %>
            <div class="flex items-baseline gap-2 min-w-0 py-0.5">
              <span class="text-base-content/50 shrink-0 text-xs">{format_label(key)}:</span>
              <span
                class="font-mono text-xs truncate"
                title={format_prop_value(Map.get(@row, key))}
              >
                {format_prop_value(Map.get(@row, key))}
              </span>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp format_label(key) when is_binary(key) do
    key
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_label(key), do: to_string(key)

  defp format_prop_value(nil), do: "—"
  defp format_prop_value(""), do: "—"
  defp format_prop_value(true), do: "Yes"
  defp format_prop_value(false), do: "No"
  defp format_prop_value(value) when is_binary(value), do: String.slice(value, 0, 100)
  defp format_prop_value(value) when is_number(value), do: to_string(value)

  defp format_prop_value(value) when is_list(value) or is_map(value) do
    "#{map_size_or_length(value)} items"
  end

  defp format_prop_value(value), do: inspect(value) |> String.slice(0, 50)

  defp map_size_or_length(value) when is_map(value), do: map_size(value)
  defp map_size_or_length(value) when is_list(value), do: length(value)
  defp map_size_or_length(_), do: 0

  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :mono, :boolean, default: false

  def kv_inline(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <span class="text-base-content/60">{@label}:</span>
      <span class={["text-base-content", @mono && "font-mono text-xs"]}>
        {format_value(@value)}
      </span>
    </div>
    """
  end

  defp format_value(nil), do: "—"
  defp format_value(""), do: "—"
  defp format_value(v) when is_binary(v), do: v
  defp format_value(v), do: to_string(v)

  # ---------------------------------------------------------------------------
  # OCSF Information Section (OS, Hardware, Network, Compliance)
  # ---------------------------------------------------------------------------

  attr :device_row, :map, required: true

  def ocsf_info_section(assigns) do
    assigns = assign_ocsf_info(assigns)

    ~H"""
    <div :if={@has_any} class="grid grid-cols-1 lg:grid-cols-2 gap-4">
      <.os_info_card :if={@has_os} os={@os} />
      <.hw_info_card :if={@has_hw} hw_info={@hw_info} />
      <.compliance_card
        :if={@has_compliance}
        risk_level={@risk_level}
        risk_score={@risk_score}
        is_managed={@is_managed}
        is_compliant={@is_compliant}
        is_trusted={@is_trusted}
      />
    </div>
    """
  end

  defp assign_ocsf_info(assigns) do
    os = Map.get(assigns.device_row, "os")
    hw_info = Map.get(assigns.device_row, "hw_info")
    risk_level = Map.get(assigns.device_row, "risk_level")
    risk_score = Map.get(assigns.device_row, "risk_score")
    is_managed = Map.get(assigns.device_row, "is_managed")
    is_compliant = Map.get(assigns.device_row, "is_compliant")
    is_trusted = Map.get(assigns.device_row, "is_trusted")

    has_os = map_present?(os)
    has_hw = map_present?(hw_info)
    has_compliance = compliance_present?(risk_level, is_managed, is_compliant)
    has_any = has_os or has_hw or has_compliance

    assigns
    |> assign(:os, os)
    |> assign(:hw_info, hw_info)
    |> assign(:risk_level, risk_level)
    |> assign(:risk_score, risk_score)
    |> assign(:is_managed, is_managed)
    |> assign(:is_compliant, is_compliant)
    |> assign(:is_trusted, is_trusted)
    |> assign(:has_os, has_os)
    |> assign(:has_hw, has_hw)
    |> assign(:has_compliance, has_compliance)
    |> assign(:has_any, has_any)
  end

  defp map_present?(value), do: is_map(value) and map_size(value) > 0

  defp compliance_present?(risk_level, is_managed, is_compliant) do
    not is_nil(risk_level) or not is_nil(is_managed) or not is_nil(is_compliant)
  end

  attr :os, :map, required: true

  defp os_info_card(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
      <div class="px-4 py-3 border-b border-base-200">
        <div class="flex items-center gap-2">
          <.icon name="hero-cpu-chip" class="size-4 text-info" />
          <span class="text-sm font-semibold">Operating System</span>
        </div>
      </div>
      <div class="p-4">
        <div class="grid grid-cols-2 gap-x-4 gap-y-2 text-sm">
          <.kv_block :if={Map.get(@os, "name")} label="Name" value={Map.get(@os, "name")} />
          <.kv_block :if={Map.get(@os, "type")} label="Type" value={Map.get(@os, "type")} />
          <.kv_block :if={Map.get(@os, "version")} label="Version" value={Map.get(@os, "version")} />
          <.kv_block :if={Map.get(@os, "build")} label="Build" value={Map.get(@os, "build")} />
          <.kv_block :if={Map.get(@os, "edition")} label="Edition" value={Map.get(@os, "edition")} />
          <.kv_block
            :if={Map.get(@os, "kernel_release")}
            label="Kernel"
            value={Map.get(@os, "kernel_release")}
          />
          <.kv_block
            :if={Map.get(@os, "cpu_bits")}
            label="Arch"
            value={"#{Map.get(@os, "cpu_bits")}-bit"}
          />
          <.kv_block :if={Map.get(@os, "lang")} label="Language" value={Map.get(@os, "lang")} />
        </div>
      </div>
    </div>
    """
  end

  attr :hw_info, :map, required: true

  defp hw_info_card(assigns) do
    ram_size = Map.get(assigns.hw_info, "ram_size")
    ram_display = if is_number(ram_size), do: format_bytes(ram_size), else: nil

    assigns = assign(assigns, :ram_display, ram_display)

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
      <div class="px-4 py-3 border-b border-base-200">
        <div class="flex items-center gap-2">
          <.icon name="hero-server" class="size-4 text-success" />
          <span class="text-sm font-semibold">Hardware Info</span>
        </div>
      </div>
      <div class="p-4">
        <div class="grid grid-cols-2 gap-x-4 gap-y-2 text-sm">
          <.kv_block
            :if={Map.get(@hw_info, "cpu_type")}
            label="CPU Type"
            value={Map.get(@hw_info, "cpu_type")}
          />
          <.kv_block
            :if={Map.get(@hw_info, "cpu_architecture")}
            label="Architecture"
            value={Map.get(@hw_info, "cpu_architecture")}
          />
          <.kv_block
            :if={Map.get(@hw_info, "cpu_cores")}
            label="CPU Cores"
            value={Map.get(@hw_info, "cpu_cores")}
          />
          <.kv_block
            :if={Map.get(@hw_info, "cpu_count")}
            label="CPU Count"
            value={Map.get(@hw_info, "cpu_count")}
          />
          <.kv_block
            :if={Map.get(@hw_info, "cpu_speed_mhz")}
            label="CPU Speed"
            value={"#{Map.get(@hw_info, "cpu_speed_mhz")} MHz"}
          />
          <.kv_block :if={@ram_display} label="RAM" value={@ram_display} />
          <.kv_block
            :if={Map.get(@hw_info, "serial_number")}
            label="Serial"
            value={Map.get(@hw_info, "serial_number")}
          />
          <.kv_block
            :if={Map.get(@hw_info, "chassis")}
            label="Chassis"
            value={Map.get(@hw_info, "chassis")}
          />
          <.kv_block
            :if={Map.get(@hw_info, "bios_manufacturer")}
            label="BIOS Vendor"
            value={Map.get(@hw_info, "bios_manufacturer")}
          />
          <.kv_block
            :if={Map.get(@hw_info, "bios_ver")}
            label="BIOS Version"
            value={Map.get(@hw_info, "bios_ver")}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :risk_level, :string, default: nil
  attr :risk_score, :integer, default: nil
  attr :is_managed, :boolean, default: nil
  attr :is_compliant, :boolean, default: nil
  attr :is_trusted, :boolean, default: nil

  defp compliance_card(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
      <div class="px-4 py-3 border-b border-base-200">
        <div class="flex items-center gap-2">
          <.icon name="hero-shield-check" class="size-4 text-warning" />
          <span class="text-sm font-semibold">Risk & Compliance</span>
        </div>
      </div>
      <div class="p-4">
        <div class="flex flex-wrap gap-4">
          <div :if={@risk_level} class="flex items-center gap-2">
            <span class="text-xs text-base-content/60">Risk Level:</span>
            <.risk_badge level={@risk_level} />
          </div>
          <div :if={@risk_score} class="flex items-center gap-2">
            <span class="text-xs text-base-content/60">Risk Score:</span>
            <span class="font-semibold tabular-nums">{@risk_score}</span>
          </div>
          <div :if={not is_nil(@is_managed)} class="flex items-center gap-2">
            <span class="text-xs text-base-content/60">Managed:</span>
            <.bool_badge value={@is_managed} />
          </div>
          <div :if={not is_nil(@is_compliant)} class="flex items-center gap-2">
            <span class="text-xs text-base-content/60">Compliant:</span>
            <.bool_badge value={@is_compliant} />
          </div>
          <div :if={not is_nil(@is_trusted)} class="flex items-center gap-2">
            <span class="text-xs text-base-content/60">Trusted:</span>
            <.bool_badge value={@is_trusted} />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :level, :string, required: true

  defp risk_badge(assigns) do
    {color, _} =
      case assigns.level do
        "Critical" -> {"error", "Critical"}
        "High" -> {"warning", "High"}
        "Medium" -> {"info", "Medium"}
        "Low" -> {"success", "Low"}
        _ -> {"ghost", assigns.level}
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span class={["badge badge-sm", "badge-#{@color}"]}>{@level}</span>
    """
  end

  attr :value, :boolean, required: true

  defp bool_badge(assigns) do
    {label, color} = if assigns.value, do: {"Yes", "success"}, else: {"No", "error"}
    assigns = assigns |> assign(:label, label) |> assign(:color, color)

    ~H"""
    <span class={["badge badge-sm", "badge-#{@color}"]}>{@label}</span>
    """
  end

  # ---------------------------------------------------------------------------
  # Interfaces Tab Content (full interfaces list)
  # ---------------------------------------------------------------------------

  attr :interfaces, :list, required: true
  attr :error, :string, default: nil
  attr :selected_interfaces, :any, required: true
  attr :favorited_interfaces, :any, required: true
  attr :device_uid, :string, required: true
  attr :interface_metrics, :map, default: nil

  defp interfaces_tab_content(assigns) do
    selected_count = MapSet.size(assigns.selected_interfaces)

    all_uids =
      assigns.interfaces
      |> Enum.map(&Map.get(&1, "interface_uid"))
      |> Enum.filter(& &1)
      |> MapSet.new()

    all_selected =
      MapSet.size(all_uids) > 0 and MapSet.equal?(all_uids, assigns.selected_interfaces)

    assigns =
      assigns
      |> assign(:selected_count, selected_count)
      |> assign(:all_selected, all_selected)

    ~H"""
    <%!-- Interface Metrics Visualization for Favorited Interfaces --%>
    <.interface_metrics_section
      :if={@interface_metrics}
      metrics={@interface_metrics}
      device_uid={@device_uid}
    />

    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
      <div class="px-4 py-3 border-b border-base-200">
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-2">
            <.icon name="hero-signal" class="size-4 text-primary" />
            <span class="text-sm font-semibold">Network Interfaces</span>
            <span class="text-xs text-base-content/50">({length(@interfaces)} interfaces)</span>
          </div>
          <%!-- Bulk action toolbar --%>
          <div :if={@selected_count > 0} class="flex items-center gap-2">
            <span class="text-xs text-base-content/70">
              {@selected_count} selected
            </span>
            <button
              type="button"
              phx-click="clear_interface_selection"
              class="btn btn-xs btn-ghost"
            >
              Clear
            </button>
            <button
              type="button"
              phx-click="open_interfaces_bulk_edit"
              class="btn btn-xs btn-primary"
            >
              <.icon name="hero-pencil-square" class="size-3" /> Bulk Edit
            </button>
          </div>
        </div>
      </div>
      <div class="p-4">
        <div :if={is_binary(@error)} class="mb-3 text-xs text-error">
          {@error}
        </div>
        <div class="overflow-x-auto max-h-[600px] overflow-y-auto">
          <table class="table table-xs w-full">
            <thead class="sticky top-0 bg-base-100">
              <tr>
                <th class="w-8">
                  <input
                    type="checkbox"
                    class="checkbox checkbox-xs checkbox-primary"
                    checked={@all_selected}
                    phx-click="toggle_select_all_interfaces"
                  />
                </th>
                <th class="w-8 text-center" title="Favorite">
                  <.icon name="hero-star" class="size-3 text-base-content/50" />
                </th>
                <th class="w-8 text-center" title="Metrics Collection">
                  <.icon name="hero-chart-bar" class="size-3 text-base-content/50" />
                </th>
                <th class="text-xs">Interface</th>
                <th class="text-xs">ID</th>
                <th class="text-xs">IP Addresses</th>
                <th class="text-xs">MAC</th>
                <th class="text-xs">Type</th>
                <th class="text-xs">Speed</th>
                <th class="text-xs">Status</th>
              </tr>
            </thead>
            <tbody>
              <%= for iface <- @interfaces do %>
                <% iface_uid = Map.get(iface, "interface_uid") %>
                <% is_selected =
                  is_binary(iface_uid) and MapSet.member?(@selected_interfaces, iface_uid) %>
                <% is_favorited =
                  is_binary(iface_uid) and MapSet.member?(@favorited_interfaces, iface_uid) %>
                <tr class={["hover:bg-base-200/50", is_selected && "bg-primary/5"]}>
                  <td class="w-8">
                    <input
                      :if={iface_uid}
                      type="checkbox"
                      class="checkbox checkbox-xs checkbox-primary"
                      checked={is_selected}
                      phx-click="toggle_interface_select"
                      phx-value-uid={iface_uid}
                    />
                  </td>
                  <td class="w-8 text-center">
                    <button
                      :if={iface_uid}
                      type="button"
                      phx-click="toggle_interface_favorite"
                      phx-value-uid={iface_uid}
                      class="btn btn-ghost btn-xs p-0"
                      title={if is_favorited, do: "Remove from favorites", else: "Add to favorites"}
                    >
                      <.icon
                        name={if is_favorited, do: "hero-star-solid", else: "hero-star"}
                        class={[
                          "size-4",
                          if(is_favorited,
                            do: "text-warning",
                            else: "text-base-content/30 hover:text-warning/70"
                          )
                        ]}
                      />
                    </button>
                  </td>
                  <td class="w-8 text-center">
                    <% metrics_enabled = Map.get(iface, "metrics_enabled", false) %>
                    <.link
                      :if={metrics_enabled && iface_uid}
                      navigate={~p"/devices/#{@device_uid}/interfaces/#{iface_uid}"}
                      title="Metrics collection enabled - Click to view details"
                    >
                      <.icon
                        name="hero-chart-bar-solid"
                        class="size-4 text-success cursor-pointer hover:text-success/80"
                      />
                    </.link>
                    <.icon
                      :if={metrics_enabled && !iface_uid}
                      name="hero-chart-bar-solid"
                      class="size-4 text-success"
                      title="Metrics collection enabled"
                    />
                    <.icon
                      :if={!metrics_enabled}
                      name="hero-chart-bar"
                      class="size-4 text-base-content/20"
                      title="Metrics collection disabled"
                    />
                  </td>
                  <td class="text-xs">
                    <.link
                      :if={iface_uid}
                      navigate={~p"/devices/#{@device_uid}/interfaces/#{iface_uid}"}
                      class="font-mono link link-hover link-primary"
                      title={iface_uid}
                    >
                      {interface_label(iface)}
                    </.link>
                    <div :if={!iface_uid} class="font-mono" title="">
                      {interface_label(iface)}
                    </div>
                    <div :if={interface_secondary(iface)} class="text-[11px] text-base-content/60">
                      {interface_secondary(iface)}
                    </div>
                  </td>
                  <td class="text-xs font-mono text-base-content/60">
                    {format_interface_id(iface)}
                  </td>
                  <td class="text-xs font-mono">{format_ip_addresses(iface)}</td>
                  <td class="text-xs font-mono">{Map.get(iface, "if_phys_address") || "—"}</td>
                  <td class="text-xs">{format_interface_type(iface)}</td>
                  <td class="text-xs font-mono">{format_bps(interface_speed(iface))}</td>
                  <td class="text-xs">
                    <.interface_status_badges iface={iface} />
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Process Metrics Section
  # ---------------------------------------------------------------------------

  attr :metrics, :list, required: true

  defp process_metrics_section(assigns) do
    ~H"""
    <% rows = @metrics || [] %>
    <% row_count = length(rows) %>
    <% last_sampled =
      rows
      |> Enum.max_by(&timestamp_sort_key/1, fn -> nil end)
      |> case do
        nil -> nil
        row -> Map.get(row, "timestamp")
      end %>
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
      <div class="px-4 py-3 border-b border-base-200 flex items-center justify-between gap-3">
        <div class="flex items-center gap-2">
          <.icon name="hero-command-line" class="size-4 text-accent" />
          <span class="text-sm font-semibold">Processes</span>
          <span class="text-xs text-base-content/50">
            last 15m{if row_count > 0, do: " · top #{row_count} by CPU", else: ""}
          </span>
        </div>
        <div class="text-xs text-base-content/50">
          <span :if={row_count > 0} class="font-mono">{format_timestamp(last_sampled)}</span>
        </div>
      </div>

      <div :if={row_count == 0} class="p-6 text-center">
        <.icon name="hero-command-line" class="size-10 text-base-content/20 mx-auto" />
        <p class="text-sm text-base-content/70 mt-2">No process metrics collected.</p>
        <p class="text-xs text-base-content/50 mt-1">
          Enable process collection in the sysmon profile and wait for samples.
        </p>
      </div>

      <div :if={row_count > 0} class="p-4 overflow-x-auto">
        <table class="table table-xs">
          <thead>
            <tr>
              <th>Process</th>
              <th class="text-right">PID</th>
              <th class="text-right">CPU %</th>
              <th class="text-right">Memory</th>
              <th>Status</th>
              <th>Sampled</th>
            </tr>
          </thead>
          <tbody>
            <%= for row <- rows do %>
              <tr class="hover">
                <td class="text-xs font-medium">{format_value(Map.get(row, "name"))}</td>
                <td class="text-xs font-mono text-right">{format_value(Map.get(row, "pid"))}</td>
                <td class="text-xs font-mono text-right">
                  {format_pct(parse_number(Map.get(row, "cpu_usage")))}%
                </td>
                <td class="text-xs font-mono text-right">
                  {format_bytes(Map.get(row, "memory_usage"))}
                </td>
                <td class="text-xs">{format_value(Map.get(row, "status"))}</td>
                <td class="text-xs font-mono">{format_timestamp(Map.get(row, "timestamp"))}</td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Interface Metrics Section
  # ---------------------------------------------------------------------------

  attr :metrics, :map, required: true
  attr :device_uid, :string, required: true

  defp interface_metrics_section(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm mb-4">
      <div class="px-4 py-3 border-b border-base-200 flex items-center justify-between">
        <div class="flex items-center gap-2">
          <.icon name="hero-chart-bar" class="size-4 text-primary" />
          <span class="text-sm font-semibold">Favorited Interface Metrics</span>
          <span :if={@metrics.favorited_count > 0} class="text-xs text-base-content/50">
            ({@metrics.favorited_count} favorited)
          </span>
        </div>
      </div>

      <%!-- No favorited interfaces --%>
      <div :if={!@metrics.has_favorited} class="p-6 text-center">
        <.icon name="hero-star" class="size-10 text-base-content/20 mx-auto" />
        <p class="text-sm text-base-content/70 mt-2">
          No favorited interfaces yet.
        </p>
        <p class="text-xs text-base-content/50 mt-1">
          Star interfaces in the table below to see their metrics here.
        </p>
      </div>

      <%!-- Error state --%>
      <div :if={@metrics.error} class="p-4">
        <div class="alert alert-error alert-sm">
          <.icon name="hero-exclamation-triangle" class="size-4" />
          <span class="text-sm">{@metrics.error}</span>
        </div>
      </div>

      <%!-- Message state (no data available) --%>
      <div
        :if={@metrics.has_favorited && @metrics.panels == [] && !@metrics.error}
        class="p-6 text-center"
      >
        <.icon name="hero-chart-bar" class="size-10 text-base-content/20 mx-auto" />
        <p class="text-sm text-base-content/70 mt-2">
          {Map.get(@metrics, :message, "No metrics data available for favorited interfaces.")}
        </p>
        <p class="text-xs text-base-content/50 mt-1">
          Metrics will appear once SNMP polling collects data for these interfaces.
        </p>
      </div>

      <%!-- Metrics panels --%>
      <% panel_count = length(@metrics.panels) %>
      <div
        :if={@metrics.panels != []}
        class={
          [
            "p-4 gap-4",
            # 1-2 panels: full width stacked
            panel_count <= 2 && "space-y-4",
            # 3+ panels: responsive grid
            panel_count > 2 && "grid grid-cols-1 sm:grid-cols-2"
          ]
        }
      >
        <%= for {panel, idx} <- Enum.with_index(@metrics.panels) do %>
          <.live_component
            module={panel.plugin}
            id={"interface-metrics-#{@device_uid}-#{panel.id}-#{idx}"}
            title={Map.get(panel.assigns, :interface_label, "Interface Metrics")}
            panel_assigns={Map.put(panel.assigns, :compact, panel_count > 2)}
          />
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Interfaces Bulk Edit Modal
  # ---------------------------------------------------------------------------

  attr :form, :any, required: true
  attr :selected_count, :integer, required: true

  defp interfaces_bulk_edit_modal(assigns) do
    ~H"""
    <dialog id="interfaces_bulk_edit_modal" class="modal modal-open">
      <div class="modal-box max-w-md">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_interfaces_bulk_edit"
          >
            x
          </button>
        </form>

        <h3 class="text-lg font-bold">Bulk Edit Interfaces</h3>
        <p class="py-2 text-sm text-base-content/70">
          Apply action to {@selected_count} selected interface(s).
        </p>

        <.form
          for={@form}
          id="interfaces-bulk-form"
          phx-submit="apply_interfaces_bulk_edit"
          class="space-y-4"
        >
          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Action</span>
            </label>
            <div class="space-y-2">
              <label class="flex items-center gap-3 cursor-pointer p-3 rounded-lg border border-base-200 hover:bg-base-200/50">
                <input
                  type="radio"
                  name="bulk[action]"
                  value="favorite"
                  class="radio radio-primary radio-sm"
                  checked
                />
                <div>
                  <div class="flex items-center gap-2">
                    <.icon name="hero-star-solid" class="size-4 text-warning" />
                    <span class="font-medium">Add to Favorites</span>
                  </div>
                  <p class="text-xs text-base-content/60 mt-1">
                    Mark selected interfaces as favorites for quick access
                  </p>
                </div>
              </label>

              <label class="flex items-center gap-3 cursor-pointer p-3 rounded-lg border border-base-200 hover:bg-base-200/50">
                <input
                  type="radio"
                  name="bulk[action]"
                  value="unfavorite"
                  class="radio radio-primary radio-sm"
                />
                <div>
                  <div class="flex items-center gap-2">
                    <.icon name="hero-star" class="size-4 text-base-content/50" />
                    <span class="font-medium">Remove from Favorites</span>
                  </div>
                  <p class="text-xs text-base-content/60 mt-1">
                    Remove selected interfaces from favorites
                  </p>
                </div>
              </label>

              <label class="flex items-center gap-3 cursor-pointer p-3 rounded-lg border border-base-200 hover:bg-base-200/50">
                <input
                  type="radio"
                  name="bulk[action]"
                  value="enable_metrics"
                  class="radio radio-primary radio-sm"
                />
                <div>
                  <div class="flex items-center gap-2">
                    <.icon name="hero-chart-bar-solid" class="size-4 text-success" />
                    <span class="font-medium">Enable Metrics Collection</span>
                  </div>
                  <p class="text-xs text-base-content/60 mt-1">
                    Start collecting metrics for selected interfaces
                  </p>
                </div>
              </label>

              <label class="flex items-center gap-3 cursor-pointer p-3 rounded-lg border border-base-200 hover:bg-base-200/50">
                <input
                  type="radio"
                  name="bulk[action]"
                  value="disable_metrics"
                  class="radio radio-primary radio-sm"
                />
                <div>
                  <div class="flex items-center gap-2">
                    <.icon name="hero-chart-bar" class="size-4 text-base-content/50" />
                    <span class="font-medium">Disable Metrics Collection</span>
                  </div>
                  <p class="text-xs text-base-content/60 mt-1">
                    Stop collecting metrics for selected interfaces
                  </p>
                </div>
              </label>

              <label class="flex items-center gap-3 cursor-pointer p-3 rounded-lg border border-base-200 hover:bg-base-200/50">
                <input
                  type="radio"
                  name="bulk[action]"
                  value="add_tags"
                  class="radio radio-primary radio-sm"
                />
                <div class="flex-1">
                  <div class="flex items-center gap-2">
                    <.icon name="hero-tag-solid" class="size-4 text-info" />
                    <span class="font-medium">Add Tags</span>
                  </div>
                  <p class="text-xs text-base-content/60 mt-1">
                    Add tags to selected interfaces (comma-separated)
                  </p>
                </div>
              </label>
            </div>
          </div>

          <div id="tags-input-container" class="form-control hidden" phx-hook="BulkEditTagsToggle">
            <label class="label">
              <span class="label-text font-medium">Tags</span>
            </label>
            <input
              type="text"
              name="bulk[tags]"
              class="input input-bordered"
              placeholder="Enter tags separated by commas (e.g., wan, critical, primary)"
            />
            <label class="label">
              <span class="label-text-alt text-base-content/60">
                Tags will be added to existing tags
              </span>
            </label>
          </div>

          <div class="flex justify-end gap-2 pt-4">
            <button type="button" phx-click="close_interfaces_bulk_edit" class="btn btn-ghost">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary">
              Apply
            </button>
          </div>
        </.form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_interfaces_bulk_edit">close</button>
      </form>
    </dialog>
    """
  end

  defp interface_label(iface) do
    iface
    |> interface_candidates()
    |> Enum.find(&present?/1)
    |> default_display()
  end

  defp interface_secondary(iface) do
    label = interface_label(iface)

    iface
    |> interface_secondary_candidates()
    |> Enum.find(fn value -> present?(value) and value != label end)
  end

  defp interface_candidates(iface) do
    [
      Map.get(iface, "if_name"),
      Map.get(iface, "if_descr"),
      Map.get(iface, "if_alias")
    ]
  end

  defp interface_secondary_candidates(iface) do
    [
      Map.get(iface, "if_descr"),
      Map.get(iface, "if_alias")
    ]
  end

  defp format_ip_addresses(iface) do
    iface
    |> Map.get("ip_addresses", [])
    |> case do
      list when is_list(list) and list != [] -> Enum.join(list, ", ")
      _ -> "—"
    end
  end

  defp format_interface_type(iface) do
    type = Map.get(iface, "if_type_name") || Map.get(iface, "interface_kind")
    InterfaceTypes.humanize(type)
  end

  defp interface_speed(iface) do
    Map.get(iface, "speed_bps") || Map.get(iface, "if_speed")
  end

  defp format_interface_id(iface) do
    # Try if_index first (SNMP interface index), then interface_uid
    case Map.get(iface, "if_index") do
      nil -> truncate_interface_id(Map.get(iface, "interface_uid"))
      idx when is_integer(idx) -> Integer.to_string(idx)
      idx when is_binary(idx) -> idx
      _ -> "—"
    end
  end

  defp truncate_interface_id(nil), do: "—"
  defp truncate_interface_id(uid) when byte_size(uid) > 8, do: String.slice(uid, 0, 8) <> "…"
  defp truncate_interface_id(uid), do: uid

  # ---------------------------------------------------------------------------
  # Interface Status Badges Component
  # ---------------------------------------------------------------------------

  attr :iface, :map, required: true

  defp interface_status_badges(assigns) do
    oper_status = Map.get(assigns.iface, "if_oper_status")
    admin_status = Map.get(assigns.iface, "if_admin_status")

    assigns =
      assigns
      |> assign(:oper_status, oper_status)
      |> assign(:admin_status, admin_status)

    ~H"""
    <div class="flex flex-wrap gap-1">
      <.oper_status_badge status={@oper_status} />
      <.admin_status_badge status={@admin_status} />
    </div>
    """
  end

  attr :status, :any, required: true

  defp oper_status_badge(assigns) do
    ~H"""
    <span
      :if={@status != nil}
      class={[
        "badge badge-xs gap-1 min-w-[4.5rem] justify-center",
        oper_status_class(@status)
      ]}
      title="Operational Status"
    >
      <.icon name={oper_status_icon(@status)} class="size-3" />
      {oper_status_text(@status)}
    </span>
    <span
      :if={@status == nil}
      class="badge badge-xs badge-ghost gap-1 min-w-[4.5rem] justify-center"
      title="Operational Status"
    >
      <.icon name="hero-question-mark-circle" class="size-3" /> Unknown
    </span>
    """
  end

  attr :status, :any, required: true

  defp admin_status_badge(assigns) do
    ~H"""
    <span
      :if={@status != nil}
      class={[
        "badge badge-xs badge-outline gap-1 min-w-[5rem] justify-center",
        admin_status_class(@status)
      ]}
      title="Admin Status"
    >
      <.icon name={admin_status_icon(@status)} class="size-3" />
      {admin_status_text(@status)}
    </span>
    """
  end

  # Operational status styling (1=up, 2=down, 3=testing)
  defp oper_status_class(1), do: "badge-success"
  defp oper_status_class(2), do: "badge-error"
  defp oper_status_class(3), do: "badge-warning"
  defp oper_status_class(_), do: "badge-ghost"

  # Use distinct icons for color-blind accessibility
  defp oper_status_icon(1), do: "hero-arrow-up-circle"
  defp oper_status_icon(2), do: "hero-arrow-down-circle"
  defp oper_status_icon(3), do: "hero-beaker"
  defp oper_status_icon(_), do: "hero-question-mark-circle"

  defp oper_status_text(1), do: "Up"
  defp oper_status_text(2), do: "Down"
  defp oper_status_text(3), do: "Testing"
  defp oper_status_text(_), do: "Unknown"

  # Admin status styling
  defp admin_status_class(1), do: "border-success text-success"
  defp admin_status_class(2), do: "border-warning text-warning"
  defp admin_status_class(3), do: "border-info text-info"
  defp admin_status_class(_), do: "border-base-content/30 text-base-content/50"

  defp admin_status_icon(1), do: "hero-check-circle"
  defp admin_status_icon(2), do: "hero-pause-circle"
  defp admin_status_icon(3), do: "hero-beaker"
  defp admin_status_icon(_), do: "hero-question-mark-circle"

  defp admin_status_text(1), do: "Enabled"
  defp admin_status_text(2), do: "Disabled"
  defp admin_status_text(3), do: "Testing"
  defp admin_status_text(_), do: "Unknown"

  defp format_bps(nil), do: "—"

  defp format_bps(bps) when is_number(bps) do
    cond do
      bps >= 1_000_000_000_000 -> "#{Float.round(bps / 1_000_000_000_000 * 1.0, 1)} Tbps"
      bps >= 1_000_000_000 -> "#{Float.round(bps / 1_000_000_000 * 1.0, 1)} Gbps"
      bps >= 1_000_000 -> "#{Float.round(bps / 1_000_000 * 1.0, 1)} Mbps"
      bps >= 1_000 -> "#{Float.round(bps / 1_000 * 1.0, 1)} Kbps"
      true -> "#{bps} bps"
    end
  end

  defp default_display(nil), do: "—"
  defp default_display(""), do: "—"
  defp default_display(value), do: value

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  # ---------------------------------------------------------------------------
  # Agents Section (linked to OCSF Agents)
  # ---------------------------------------------------------------------------

  attr :device_row, :map, required: true

  def agents_section(assigns) do
    agent_list = Map.get(assigns.device_row, "agent_list") || []
    has_agents = is_list(agent_list) and agent_list != []

    assigns =
      assigns
      |> assign(:agent_list, agent_list)
      |> assign(:has_agents, has_agents)

    ~H"""
    <div :if={@has_agents} class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
      <div class="px-4 py-3 border-b border-base-200">
        <div class="flex items-center gap-2">
          <.icon name="hero-cpu-chip" class="size-4 text-accent" />
          <span class="text-sm font-semibold">Agents</span>
          <span class="text-xs text-base-content/50">({length(@agent_list)} agents)</span>
        </div>
      </div>
      <div class="p-4">
        <div class="overflow-x-auto">
          <table class="table table-xs w-full">
            <thead>
              <tr>
                <th class="text-xs">UID</th>
                <th class="text-xs">Name</th>
                <th class="text-xs">Type</th>
                <th class="text-xs">Version</th>
                <th class="text-xs">Vendor</th>
              </tr>
            </thead>
            <tbody>
              <%= for agent <- Enum.take(@agent_list, 10) do %>
                <tr class="hover:bg-base-200/40">
                  <td class="font-mono text-xs">
                    <.link
                      navigate={~p"/agents/#{agent_uid(agent)}"}
                      class="link link-primary hover:underline"
                    >
                      {truncate_uid(agent_uid(agent))}
                    </.link>
                  </td>
                  <td class="text-xs">{Map.get(agent, "name") || "—"}</td>
                  <td class="text-xs">
                    <.agent_type_badge
                      type_id={Map.get(agent, "type_id")}
                      type={Map.get(agent, "type")}
                    />
                  </td>
                  <td class="font-mono text-xs">{Map.get(agent, "version") || "—"}</td>
                  <td class="text-xs">{Map.get(agent, "vendor_name") || "—"}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
        <div :if={length(@agent_list) > 10} class="text-xs text-base-content/50 mt-2">
          Showing 10 of {length(@agent_list)} agents
        </div>
      </div>
    </div>
    """
  end

  defp agent_uid(agent) when is_map(agent), do: Map.get(agent, "uid") || ""
  defp agent_uid(_), do: ""

  defp truncate_uid(uid) when is_binary(uid) and byte_size(uid) > 24 do
    String.slice(uid, 0, 24) <> "..."
  end

  defp truncate_uid(uid), do: uid

  attr :type_id, :any, default: nil
  attr :type, :any, default: nil

  defp agent_type_badge(assigns) do
    type_name = assigns.type || get_agent_type_name(assigns.type_id)
    variant = agent_type_variant(assigns.type_id)
    assigns = assign(assigns, :type_name, type_name) |> assign(:variant, variant)

    ~H"""
    <span class={["badge badge-xs", "badge-#{@variant}"]}>{@type_name}</span>
    """
  end

  defp get_agent_type_name(nil), do: "Unknown"
  defp get_agent_type_name(0), do: "Unknown"
  defp get_agent_type_name(1), do: "EDR"
  defp get_agent_type_name(4), do: "Performance"
  defp get_agent_type_name(6), do: "Log"
  defp get_agent_type_name(99), do: "Other"
  defp get_agent_type_name(_), do: "Unknown"

  defp agent_type_variant(1), do: "error"
  defp agent_type_variant(4), do: "info"
  defp agent_type_variant(6), do: "warning"
  defp agent_type_variant(99), do: "ghost"
  defp agent_type_variant(_), do: "ghost"

  attr :label, :string, required: true
  attr :value, :any, default: nil

  defp kv_block(assigns) do
    ~H"""
    <div>
      <div class="text-xs text-base-content/50">{@label}</div>
      <div class="font-medium">{format_value(@value)}</div>
    </div>
    """
  end

  defp parse_limit(nil, default, _max), do: default

  defp parse_limit(limit, default, max) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, ""} -> parse_limit(value, default, max)
      _ -> default
    end
  end

  defp parse_limit(limit, _default, max) when is_integer(limit) and limit > 0 do
    min(limit, max)
  end

  defp parse_limit(_limit, default, _max), do: default

  defp escape_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp escape_value(other), do: escape_value(to_string(other))

  defp load_process_metrics(_srql_module, [], _scope), do: []

  defp load_process_metrics(srql_module, filter_tokens, scope) do
    query = process_metrics_query(filter_tokens)

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        normalize_process_rows(results)

      {:ok, _} ->
        []

      {:error, _} ->
        []
    end
  end

  defp process_metrics_query(filter_tokens) do
    [
      "in:process_metrics",
      "time:last_15m"
    ]
    |> Kernel.++(filter_tokens)
    |> Kernel.++(["sort:timestamp:desc", "limit:#{@process_query_limit}"])
    |> Enum.join(" ")
  end

  defp normalize_process_rows(rows) when is_list(rows) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.sort_by(&timestamp_sort_key/1, :desc)
    |> Enum.reduce(%{}, fn row, acc ->
      Map.put_new(acc, process_identity(row), row)
    end)
    |> Map.values()
    |> Enum.sort_by(&process_cpu_sort_key/1, :desc)
    |> Enum.take(@process_limit)
  end

  defp normalize_process_rows(_), do: []

  defp process_identity(row) when is_map(row) do
    {Map.get(row, "pid"), Map.get(row, "name")}
  end

  defp process_identity(_), do: {nil, nil}

  defp process_cpu_sort_key(row) when is_map(row) do
    case parse_number(Map.get(row, "cpu_usage")) do
      value when is_number(value) -> value
      _ -> -1
    end
  end

  defp process_cpu_sort_key(_), do: -1

  defp load_metric_sections(_srql_module, [], _scope), do: []

  defp load_metric_sections(srql_module, filter_tokens, scope) do
    # Note: process_section is intentionally excluded here since processes are
    # rendered separately via the process_metrics_section component (which includes
    # the proper icon). See GitHub issue #2470.
    [
      build_cpu_section(srql_module, filter_tokens, scope),
      build_memory_section(srql_module, filter_tokens, scope),
      build_disk_section(srql_module, filter_tokens, scope)
    ]
    |> Enum.filter(& &1)
  end

  defp build_cpu_section(srql_module, filter_tokens, scope) do
    query = metric_query("cpu_metrics", filter_tokens, nil, "usage_percent", @metrics_limit)

    base = %{
      key: "cpu",
      title: "CPU",
      subtitle: "last 24h · 5m buckets · avg across cores",
      query: query,
      panels: [],
      error: nil,
      header_value: nil,
      header_stats: nil
    }

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) and results != [] ->
        normalized = normalize_metric_results(results, "usage_percent")
        viz = timeseries_viz("usage_percent", nil)
        panels = build_metric_panels(%{"results" => normalized, "viz" => viz}, normalized, nil)
        header_value = latest_metric_value(normalized, "usage_percent")
        header_stats = metric_stats(normalized, "usage_percent")
        %{base | panels: panels, header_value: header_value, header_stats: header_stats}

      {:ok, %{"results" => results}} when is_list(results) ->
        base

      {:ok, other} ->
        %{base | error: "unexpected SRQL response: #{inspect(other)}"}

      {:error, reason} ->
        %{base | error: "SRQL error: #{format_error(reason)}"}
    end
  end

  defp build_memory_section(srql_module, filter_tokens, scope) do
    series_limit = @metrics_limit
    used_query = metric_query("memory_metrics", filter_tokens, nil, "used_bytes", series_limit)

    available_query =
      metric_query("memory_metrics", filter_tokens, nil, "available_bytes", series_limit)

    base = %{
      key: "memory",
      title: "Memory",
      subtitle: "last 24h · 5m buckets · avg",
      query: used_query,
      panels: [],
      error: nil
    }

    with {:ok, %{"results" => used_rows}} when is_list(used_rows) <-
           srql_module.query(used_query, %{scope: scope}),
         {:ok, %{"results" => available_rows}} when is_list(available_rows) <-
           srql_module.query(available_query, %{scope: scope}) do
      combined =
        build_series_rows(used_rows, "Used", "bytes")
        |> Kernel.++(build_series_rows(available_rows, "Available", "bytes"))
        |> sort_rows_by_timestamp()

      if combined == [] do
        base
      else
        viz = timeseries_viz("bytes", "series")
        panels = build_metric_panels(%{"results" => combined, "viz" => viz}, combined, "series")

        panels =
          apply_panel_assigns(panels, %{
            combine_all_series: true,
            combined_title: "Memory (Used vs Available)"
          })

        %{base | panels: panels}
      end
    else
      {:ok, other} ->
        %{base | error: "unexpected SRQL response: #{inspect(other)}"}

      {:error, reason} ->
        %{base | error: "SRQL error: #{format_error(reason)}"}
    end
  end

  defp build_disk_section(srql_module, filter_tokens, scope) do
    series_field = resolve_disk_series_field(srql_module, filter_tokens, scope)

    used_query =
      metric_query("disk_metrics", filter_tokens, series_field, "used_bytes", @disk_metrics_limit)

    total_query =
      metric_query(
        "disk_metrics",
        filter_tokens,
        series_field,
        "total_bytes",
        @disk_metrics_limit
      )

    base = %{
      key: "disk",
      title: "Disk",
      subtitle: "last 24h · 5m buckets · avg",
      query: used_query,
      panels: [],
      error: nil
    }

    with {:ok, %{"results" => used_rows}} when is_list(used_rows) <-
           srql_module.query(used_query, %{scope: scope}),
         {:ok, %{"results" => total_rows}} when is_list(total_rows) <-
           srql_module.query(total_query, %{scope: scope}) do
      panels = build_disk_panels(used_rows, total_rows)
      %{base | panels: panels}
    else
      {:ok, other} ->
        %{base | error: "unexpected SRQL response: #{inspect(other)}"}

      {:error, reason} ->
        %{base | error: "SRQL error: #{format_error(reason)}"}
    end
  end

  defp resolve_disk_series_field(srql_module, filter_tokens, scope) do
    probe_query = metric_probe_query("disk_metrics", filter_tokens)

    case srql_module.query(probe_query, %{scope: scope}) do
      {:ok, %{"results" => [row | _]}} when is_map(row) ->
        cond do
          present?(Map.get(row, "device_name")) -> "device_name"
          present?(Map.get(row, "partition")) -> "partition"
          present?(Map.get(row, "mount_point")) -> "mount_point"
          true -> "mount_point"
        end

      _ ->
        "mount_point"
    end
  end

  defp build_disk_panels(used_rows, total_rows) do
    used_by_series = group_rows_by_series(used_rows)
    total_by_series = group_rows_by_series(total_rows)

    used_by_series
    |> disk_series_keys(total_by_series)
    |> Enum.take(@disk_panel_limit)
    |> Enum.map(&build_disk_series_panels(&1, used_by_series, total_by_series))
    |> Enum.flat_map(& &1)
  end

  defp disk_series_keys(used_by_series, total_by_series) do
    (Map.keys(used_by_series) ++ Map.keys(total_by_series))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp build_disk_series_panels(series, used_by_series, total_by_series) do
    combined =
      build_series_rows(Map.get(used_by_series, series, []), "Used", "bytes")
      |> Kernel.++(build_series_rows(Map.get(total_by_series, series, []), "Total", "bytes"))
      |> sort_rows_by_timestamp()

    if combined == [] do
      []
    else
      viz = timeseries_viz("bytes", "series")

      build_metric_panels(%{"results" => combined, "viz" => viz}, combined, "series")
      |> Enum.map(fn panel ->
        Map.put(panel, :title, "Disk · #{series_label(series)}")
      end)
    end
  end

  defp group_rows_by_series(rows) when is_list(rows) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.group_by(fn row ->
      series_label(Map.get(row, "series"))
    end)
  end

  defp group_rows_by_series(_), do: %{}

  defp series_label(nil), do: "unknown"

  defp series_label(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "unknown"
      other -> other
    end
  end

  defp series_label(value), do: series_label(to_string(value))

  defp build_series_rows(rows, series_label, output_field) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.reduce([], fn row, acc ->
      value = Map.get(row, "value")

      if is_nil(value) do
        acc
      else
        [
          %{
            "timestamp" => Map.get(row, "timestamp"),
            output_field => value,
            "series" => series_label
          }
          | acc
        ]
      end
    end)
    |> Enum.reverse()
  end

  defp sort_rows_by_timestamp(rows) when is_list(rows) do
    Enum.sort_by(rows, &timestamp_sort_key/1)
  end

  defp sort_rows_by_timestamp(rows), do: rows

  defp timestamp_sort_key(row) when is_map(row) do
    case parse_datetime(Map.get(row, "timestamp")) do
      {:ok, dt} -> DateTime.to_unix(dt, :millisecond)
      _ -> 0
    end
  end

  defp timestamp_sort_key(_), do: 0

  defp parse_datetime(%DateTime{} = dt), do: {:ok, dt}

  defp parse_datetime(%NaiveDateTime{} = ndt) do
    {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
  end

  defp parse_datetime(value) when is_binary(value) do
    value = String.trim(value)

    with {:error, _} <- DateTime.from_iso8601(value),
         {:ok, ndt} <- NaiveDateTime.from_iso8601(value) do
      {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
    else
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> {:error, :invalid_datetime}
    end
  end

  defp parse_datetime(_), do: {:error, :invalid_datetime}

  defp format_timestamp(nil), do: "—"

  defp format_timestamp(value) do
    case parse_datetime(value) do
      {:ok, %DateTime{} = dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      {:ok, %NaiveDateTime{} = ndt} -> Calendar.strftime(ndt, "%Y-%m-%d %H:%M:%S")
      _ -> "—"
    end
  end

  defp parse_number(value) when is_integer(value), do: value * 1.0
  defp parse_number(value) when is_float(value), do: value

  defp parse_number(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      match?({_, ""}, Float.parse(value)) ->
        {v, ""} = Float.parse(value)
        v

      match?({_, ""}, Integer.parse(value)) ->
        {v, ""} = Integer.parse(value)
        v * 1.0

      true ->
        nil
    end
  end

  defp parse_number(_), do: nil

  defp latest_metric_value(rows, field) when is_list(rows) do
    rows
    |> latest_metric_tuple(field)
    |> extract_metric_value()
  end

  defp latest_metric_value(_rows, _field), do: nil

  defp latest_metric_tuple(rows, field) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(nil, &update_latest_metric(&1, field, &2))
  end

  defp extract_metric_value({_dt, value}), do: value
  defp extract_metric_value(_), do: nil

  defp update_latest_metric(row, field, acc) do
    with {:ok, dt} <- parse_datetime(Map.get(row, "timestamp")),
         value when is_number(value) <- parse_number(Map.get(row, field)) do
      pick_latest_metric({dt, value}, acc)
    else
      _ -> acc
    end
  end

  defp pick_latest_metric(current, nil), do: current

  defp pick_latest_metric({dt, _} = current, {prev_dt, _} = previous) do
    if DateTime.compare(dt, prev_dt) == :gt, do: current, else: previous
  end

  defp metric_stats(rows, field) when is_list(rows) do
    {min, max, sum, count} =
      rows
      |> Enum.filter(&is_map/1)
      |> Enum.reduce({nil, nil, 0.0, 0}, &accumulate_metric_stat(&1, field, &2))

    if count > 0 do
      %{min: min, max: max, avg: sum / count}
    else
      nil
    end
  end

  defp metric_stats(_rows, _field), do: nil

  defp accumulate_metric_stat(row, field, {min_v, max_v, sum_v, count_v}) do
    case parse_number(Map.get(row, field)) do
      value when is_number(value) ->
        {min_value(min_v, value), max_value(max_v, value), sum_v + value, count_v + 1}

      _ ->
        {min_v, max_v, sum_v, count_v}
    end
  end

  defp min_value(nil, value), do: value
  defp min_value(min_v, value) when value < min_v, do: value
  defp min_value(min_v, _value), do: min_v

  defp max_value(nil, value), do: value
  defp max_value(max_v, value) when value > max_v, do: value
  defp max_value(max_v, _value), do: max_v

  defp normalize_metric_results(results, target_field) when is_list(results) do
    Enum.map(results, fn
      row when is_map(row) ->
        value = Map.get(row, "value")

        if is_nil(value) do
          row
        else
          Map.put(row, target_field, value)
        end

      other ->
        other
    end)
  end

  defp normalize_metric_results(results, _target_field), do: results

  defp timeseries_viz(y_field, series_field) do
    suggestion =
      %{"kind" => "timeseries", "x" => "timestamp", "y" => y_field}
      |> maybe_put_series(series_field)

    %{"suggestions" => [suggestion]}
  end

  defp maybe_put_series(viz, nil), do: viz
  defp maybe_put_series(viz, ""), do: viz

  defp maybe_put_series(viz, series_field) do
    Map.put(viz, "series", series_field)
  end

  defp metric_probe_query(entity, filter_tokens) do
    [
      "in:#{entity}",
      "time:last_24h",
      "sort:timestamp:desc",
      "limit:1"
    ]
    |> Kernel.++(filter_tokens)
    |> Enum.join(" ")
  end

  defp build_metric_panels(resp, results, series_field) do
    srql_response = %{"results" => results, "viz" => extract_viz(resp)}

    panels =
      srql_response
      |> Engine.build_panels()
      |> prefer_visual_panels(results)
      |> drop_category_panels_when_timeseries()

    panels
    |> maybe_force_timeseries(results, series_field)
    |> drop_category_panels_when_timeseries()
  end

  defp apply_panel_assigns(panels, assigns) when is_list(panels) and is_map(assigns) do
    Enum.map(panels, fn panel ->
      Map.update(panel, :assigns, assigns, &Map.merge(&1, assigns))
    end)
  end

  defp apply_panel_assigns(panels, _assigns), do: panels

  defp extract_viz(resp) do
    case Map.get(resp, "viz") do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp prefer_visual_panels(panels, results) when is_list(panels) do
    has_non_table? = Enum.any?(panels, &(&1.plugin != TablePlugin))

    if results != [] and has_non_table? do
      Enum.reject(panels, &(&1.plugin == TablePlugin))
    else
      panels
    end
  end

  defp prefer_visual_panels(panels, _results), do: panels

  defp drop_category_panels_when_timeseries(panels) when is_list(panels) do
    has_timeseries = Enum.any?(panels, &(&1.plugin == TimeseriesPlugin))

    if has_timeseries do
      Enum.reject(panels, &(&1.plugin == CategoriesPlugin))
    else
      panels
    end
  end

  defp drop_category_panels_when_timeseries(panels), do: panels

  defp maybe_force_timeseries(panels, results, series_field) do
    has_visual = Enum.any?(panels, &(&1.plugin != TablePlugin))

    if has_visual do
      panels
    else
      case inferred_timeseries_viz(results, series_field) do
        nil ->
          panels

        viz ->
          %{"results" => results, "viz" => %{"suggestions" => [viz]}}
          |> Engine.build_panels()
          |> prefer_visual_panels(results)
      end
    end
  end

  defp inferred_timeseries_viz(results, series_field) do
    case Viz.infer(results) do
      {:timeseries, %{x: x, y: y}} ->
        base = %{"kind" => "timeseries", "x" => x, "y" => y}

        if is_binary(series_field) and String.trim(series_field) != "" do
          Map.put(base, "series", series_field)
        else
          base
        end

      _ ->
        nil
    end
  end

  defp sysmon_metrics_visible?(assigns) do
    sysmon_presence = Map.get(assigns, :sysmon_presence, false)

    sysmon_presence
  end

  defp sysmon_identity(device_row, device_uid) do
    device_uid =
      case Map.get(device_row || %{}, "uid") || device_uid do
        value when is_binary(value) -> String.trim(value)
        _ -> ""
      end

    agent_id =
      device_row
      |> Map.get("agent_id")
      |> case do
        value when is_binary(value) -> String.trim(value)
        _ -> ""
      end

    %{}
    |> maybe_put_identity(:device_uid, device_uid)
    |> maybe_put_identity(:agent_id, agent_id)
  end

  defp maybe_put_identity(identity, _key, ""), do: identity
  defp maybe_put_identity(identity, _key, nil), do: identity

  defp maybe_put_identity(identity, key, value) do
    if is_binary(value) and String.trim(value) != "" do
      Map.put(identity, key, value)
    else
      identity
    end
  end

  defp resolve_sysmon_filter_tokens(_srql_module, identity, _scope)
       when identity == %{} or identity == nil,
       do: []

  defp resolve_sysmon_filter_tokens(srql_module, identity, scope) do
    device_tokens = sysmon_filter_tokens(identity, :device_uid, "device_id")
    agent_tokens = sysmon_filter_tokens(identity, :agent_id, "agent_id")

    cond do
      device_tokens != [] and sysmon_filter_has_data?(srql_module, device_tokens, scope) ->
        device_tokens

      agent_tokens != [] and sysmon_filter_has_data?(srql_module, agent_tokens, scope) ->
        agent_tokens

      true ->
        []
    end
  end

  defp sysmon_filter_has_data?(srql_module, filter_tokens, scope) do
    ["cpu_metrics", "memory_metrics", "disk_metrics", "process_metrics"]
    |> Enum.any?(&sysmon_entity_has_data?(srql_module, &1, filter_tokens, scope))
  end

  defp sysmon_entity_has_data?(srql_module, entity, filter_tokens, scope) do
    query =
      [
        "in:#{entity}",
        Enum.join(filter_tokens, " "),
        "time:last_24h",
        "sort:timestamp:desc",
        "limit:1"
      ]
      |> Enum.join(" ")

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => rows}} when is_list(rows) -> rows != []
      _ -> false
    end
  end

  defp sysmon_filter_tokens(identity, key, field) do
    value = Map.get(identity, key)

    if is_binary(value) and String.trim(value) != "" do
      ["#{field}:\"#{escape_value(value)}\""]
    else
      []
    end
  end

  defp drop_low_value_categories(panels) when is_list(panels) do
    Enum.reject(panels, &low_value_categories_panel?/1)
  end

  defp drop_low_value_categories(_), do: []

  defp drop_table_panels(panels) when is_list(panels) do
    Enum.reject(panels, &(&1.plugin == TablePlugin))
  end

  defp drop_table_panels(panels), do: panels

  defp low_value_categories_panel?(%{plugin: CategoriesPlugin, assigns: assigns}) do
    case Map.get(assigns, :viz) do
      {:categories, %{label: label, value: value}} ->
        normalize_viz_key(label) == "modified" and normalize_viz_key(value) == "type_id"

      _ ->
        false
    end
  end

  defp low_value_categories_panel?(_), do: false

  defp normalize_viz_key(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp metric_query(entity, filter_tokens, series_field, value_field, limit) do
    series_field =
      case series_field do
        nil -> nil
        "" -> nil
        other -> to_string(other) |> String.trim()
      end

    value_field =
      case value_field do
        nil -> nil
        "" -> nil
        other -> to_string(other) |> String.trim()
      end

    tokens =
      [
        "in:#{entity}",
        "time:last_24h",
        "bucket:5m",
        "agg:avg"
      ]

    tokens =
      tokens
      |> maybe_add_token("series", series_field)
      |> maybe_add_token("value_field", value_field)
      |> Kernel.++(filter_tokens)
      |> Kernel.++(["sort:timestamp:desc", "limit:#{limit}"])

    Enum.join(tokens, " ")
  end

  defp maybe_add_token(tokens, _key, nil), do: tokens
  defp maybe_add_token(tokens, _key, ""), do: tokens

  defp maybe_add_token(tokens, key, value) do
    tokens ++ ["#{key}:#{value}"]
  end

  defp format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  defp format_error(%ArgumentError{} = err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp execute_srql_query(srql_module, query, scope) do
    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => results} = resp} when is_list(results) ->
        viz = if is_map(resp["viz"]), do: resp["viz"], else: nil
        {results, nil, viz}

      {:ok, other} ->
        {[], "unexpected SRQL response: #{inspect(other)}", nil}

      {:error, reason} ->
        {[], "SRQL error: #{format_error(reason)}", nil}
    end
  end

  # ---------------------------------------------------------------------------
  # Availability Section
  # ---------------------------------------------------------------------------

  attr :availability, :map, required: true

  def availability_section(assigns) do
    uptime_pct = Map.get(assigns.availability, :uptime_pct, 0.0)
    total_checks = Map.get(assigns.availability, :total_checks, 0)
    online_checks = Map.get(assigns.availability, :online_checks, 0)
    offline_checks = Map.get(assigns.availability, :offline_checks, 0)
    segments = Map.get(assigns.availability, :segments, [])

    assigns =
      assigns
      |> assign(:uptime_pct, uptime_pct)
      |> assign(:total_checks, total_checks)
      |> assign(:online_checks, online_checks)
      |> assign(:offline_checks, offline_checks)
      |> assign(:segments, segments)

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
      <div class="px-4 py-3 border-b border-base-200">
        <div class="flex items-center justify-between gap-3">
          <div>
            <div class="text-sm font-semibold">Availability Timeline</div>
            <div class="text-xs text-base-content/60">
              Last 24h · each block = 30m bucket · green = online, red = offline
            </div>
          </div>
          <div class="text-right">
            <div class="text-sm font-semibold tabular-nums">{format_pct(@uptime_pct)}%</div>
            <div class="text-xs text-base-content/60">uptime (bucketed)</div>
          </div>
        </div>
      </div>

      <div class="p-4">
        <div :if={@segments != []} class="space-y-2">
          <div class="flex items-center justify-between text-xs text-base-content/60">
            <span>24h ago</span>
            <span>now</span>
          </div>

          <div class="h-6 rounded-lg bg-base-200/50 p-0.5">
            <div class="h-full grid grid-flow-col auto-cols-fr gap-px rounded-md overflow-hidden bg-base-300/60">
              <%= for {seg, idx} <- Enum.with_index(@segments) do %>
                <div
                  class={[
                    "h-full transition-opacity",
                    (seg.available && "bg-success") || "bg-error",
                    idx == 0 && "rounded-l-sm",
                    idx == length(@segments) - 1 && "rounded-r-sm"
                  ]}
                  title={seg.title}
                />
              <% end %>
            </div>
          </div>

          <div class="flex flex-wrap items-center justify-between gap-2 text-sm">
            <div class="flex items-center gap-4">
              <div class="flex items-center gap-2">
                <span class="w-3 h-3 rounded-sm bg-success"></span>
                <span class="tabular-nums font-semibold">{@online_checks}</span>
                <span class="text-base-content/60">online buckets</span>
              </div>
              <div class="flex items-center gap-2">
                <span class="w-3 h-3 rounded-sm bg-error"></span>
                <span class="tabular-nums font-semibold">{@offline_checks}</span>
                <span class="text-base-content/60">offline buckets</span>
              </div>
            </div>
            <div class="text-xs text-base-content/50 tabular-nums">
              {@total_checks} total buckets
            </div>
          </div>
        </div>

        <div :if={@segments == []} class="text-sm text-base-content/60">
          No availability data found.
        </div>
      </div>
    </div>
    """
  end

  defp format_pct(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  defp format_pct(value) when is_integer(value), do: Integer.to_string(value)
  defp format_pct(_), do: "—"

  defp percent_width(value) when is_number(value) do
    value = value * 1.0

    cond do
      value < 0.0 -> 0.0
      value > 100.0 -> 100.0
      true -> value
    end
  end

  defp percent_width(_), do: 0

  # ---------------------------------------------------------------------------
  # Data Loading Functions
  # ---------------------------------------------------------------------------

  defp load_availability(srql_module, device_uid, scope) do
    escaped_id = escape_value(device_uid)

    query =
      "in:timeseries_metrics metric_type:icmp uid:\"#{escaped_id}\" " <>
        "time:#{@availability_window} bucket:#{@availability_bucket} agg:count sort:timestamp:asc limit:100"

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => rows}} when is_list(rows) and rows != [] ->
        build_availability(rows)

      _ ->
        # Fallback: try healthcheck_results
        fallback_query =
          "in:healthcheck_results uid:\"#{escaped_id}\" time:#{@availability_window} limit:200"

        case srql_module.query(fallback_query, %{scope: scope}) do
          {:ok, %{"results" => rows}} when is_list(rows) ->
            build_availability_from_healthchecks(rows)

          _ ->
            nil
        end
    end
  end

  defp build_availability(rows) do
    # Each row represents a bucket. If we got ICMP data, the device was online.
    # This is a simplified availability based on metric presence.
    total = length(rows)

    online =
      Enum.count(rows, fn r ->
        is_map(r) and is_number(Map.get(r, "value")) and Map.get(r, "value") > 0
      end)

    offline = total - online

    uptime_pct = if total > 0, do: Float.round(online / total * 100.0, 1), else: 0.0

    segments =
      rows
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn r ->
        value = Map.get(r, "value")
        ts = Map.get(r, "timestamp", "")
        available = is_number(value) and value > 0

        %{
          available: available,
          width: 100.0 / max(length(rows), 1),
          title: "#{ts} - #{if available, do: "Online", else: "Offline"}"
        }
      end)

    %{
      uptime_pct: uptime_pct,
      total_checks: total,
      online_checks: online,
      offline_checks: offline,
      segments: segments
    }
  end

  defp build_availability_from_healthchecks(rows) do
    total = length(rows)

    online =
      Enum.count(rows, fn r ->
        is_map(r) and (Map.get(r, "is_available") == true or Map.get(r, "available") == true)
      end)

    offline = total - online

    uptime_pct = if total > 0, do: Float.round(online / total * 100.0, 1), else: 0.0

    # Build segments (group by time buckets if we have timestamps)
    segments =
      rows
      |> Enum.filter(&is_map/1)
      # Limit segments for display
      |> Enum.take(48)
      |> Enum.map(fn r ->
        available = Map.get(r, "is_available") == true or Map.get(r, "available") == true
        ts = Map.get(r, "timestamp") || Map.get(r, "checked_at", "")

        %{
          available: available,
          width: 100.0 / max(min(length(rows), 48), 1),
          title: "#{ts} - #{if available, do: "Online", else: "Offline"}"
        }
      end)

    %{
      uptime_pct: uptime_pct,
      total_checks: total,
      online_checks: online,
      offline_checks: offline,
      segments: segments
    }
  end

  defp format_bytes(bytes) when is_number(bytes) do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776 * 1.0, 1)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824 * 1.0, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576 * 1.0, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024 * 1.0, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "—"

  # ---------------------------------------------------------------------------
  # Healthcheck Section (GRPC/Service Health)
  # ---------------------------------------------------------------------------

  attr :summary, :map, required: true

  def healthcheck_section(assigns) do
    services = Map.get(assigns.summary, :services, [])
    total = Map.get(assigns.summary, :total, 0)
    available = Map.get(assigns.summary, :available, 0)
    unavailable = Map.get(assigns.summary, :unavailable, 0)
    uptime_pct = if total > 0, do: Float.round(available / total * 100.0, 1), else: 0.0

    assigns =
      assigns
      |> assign(:services, services)
      |> assign(:total, total)
      |> assign(:available, available)
      |> assign(:unavailable, unavailable)
      |> assign(:uptime_pct, uptime_pct)

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
      <div class="px-4 py-3 border-b border-base-200 flex items-center justify-between">
        <span class="text-sm font-semibold">Service Health (GRPC)</span>
        <div class="flex items-center gap-4 text-sm">
          <div class="flex items-center gap-2">
            <span class="w-2 h-2 rounded-full bg-success"></span>
            <span class="tabular-nums">{@available}</span>
            <span class="text-base-content/60 text-xs">healthy</span>
          </div>
          <div class="flex items-center gap-2">
            <span class="w-2 h-2 rounded-full bg-error"></span>
            <span class="tabular-nums">{@unavailable}</span>
            <span class="text-base-content/60 text-xs">unhealthy</span>
          </div>
        </div>
      </div>

      <div class="p-4">
        <div :if={@services == []} class="text-sm text-base-content/60">
          No service health data available.
        </div>

        <div :if={@services != []} class="space-y-2">
          <%= for svc <- Enum.take(@services, 10) do %>
            <.healthcheck_row service={svc} />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :service, :map, required: true

  defp healthcheck_row(assigns) do
    svc = assigns.service
    available = Map.get(svc, :available, false)
    service_name = Map.get(svc, :service_name, "Unknown")
    service_type = Map.get(svc, :service_type, "")
    message = Map.get(svc, :message, "")
    timestamp = Map.get(svc, :timestamp, "")

    assigns =
      assigns
      |> assign(:available, available)
      |> assign(:service_name, service_name)
      |> assign(:service_type, service_type)
      |> assign(:message, message)
      |> assign(:timestamp, timestamp)

    ~H"""
    <div class="flex items-center gap-3 p-2 rounded-lg bg-base-200/30">
      <div class={["w-2.5 h-2.5 rounded-full shrink-0", (@available && "bg-success") || "bg-error"]} />
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2">
          <span class="text-sm font-medium truncate">{@service_name}</span>
          <span
            :if={@service_type != ""}
            class="text-xs text-base-content/50 px-1.5 py-0.5 rounded bg-base-200"
          >
            {@service_type}
          </span>
        </div>
        <div :if={@message != ""} class="text-xs text-base-content/60 truncate">{@message}</div>
      </div>
      <div class="text-xs text-base-content/50 shrink-0 font-mono">
        {format_healthcheck_time(@timestamp)}
      </div>
    </div>
    """
  end

  defp format_healthcheck_time(nil), do: ""
  defp format_healthcheck_time(""), do: ""

  defp format_healthcheck_time(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> ts
    end
  end

  defp format_healthcheck_time(_), do: ""

  defp load_healthcheck_summary(srql_module, device_uid, scope) do
    case service_query_for_device(device_uid) do
      {:ok, query} -> query_service_summary(srql_module, query, scope)
      :error -> nil
    end
  end

  defp service_query_for_device(device_uid) do
    case parse_service_device_uid(device_uid) do
      {:service, "checker", checker_id} ->
        service_query_for_checker(checker_id)

      {:service, "agent", agent_id} ->
        {:ok, service_query(%{"agent_id" => agent_id})}

      {:service, "gateway", gateway_id} ->
        {:ok, service_query(%{"gateway_id" => gateway_id})}

      {:service, _service_type, service_id} ->
        {:ok, service_query(%{"service_name" => service_id})}

      _ ->
        :error
    end
  end

  defp service_query_for_checker(checker_id) do
    case parse_checker_identity(checker_id) do
      {:ok, service_name, agent_id} ->
        {:ok, service_query(%{"service_name" => service_name, "agent_id" => agent_id})}

      :error ->
        :error
    end
  end

  defp service_query(filters) do
    filter_expr =
      filters
      |> Enum.map_join(" ", fn {field, value} -> "#{field}:\"#{escape_value(value)}\"" end)

    "in:services " <> filter_expr <> " time:last_24h sort:timestamp:desc limit:200"
  end

  defp query_service_summary(srql_module, query, scope) do
    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => rows}} when is_list(rows) and rows != [] ->
        build_healthcheck_summary(rows)

      _ ->
        nil
    end
  end

  defp parse_service_device_uid(device_uid) when is_binary(device_uid) do
    case String.split(device_uid, ":", parts: 3) do
      ["serviceradar", service_type, service_id] when service_type != "" and service_id != "" ->
        {:service, service_type, service_id}

      _ ->
        :non_service
    end
  end

  defp parse_service_device_uid(_), do: :non_service

  defp parse_checker_identity(checker_id) when is_binary(checker_id) do
    case String.split(checker_id, "@", parts: 2) do
      [service_name, agent_id] when service_name != "" and agent_id != "" ->
        {:ok, service_name, agent_id}

      _ ->
        :error
    end
  end

  defp parse_checker_identity(_), do: :error

  defp build_healthcheck_summary(rows) do
    # Group by service_name and take most recent status for each
    services_by_name =
      rows
      |> Enum.filter(&is_map/1)
      |> Enum.reduce(%{}, fn row, acc ->
        service_name = Map.get(row, "service_name") || "Unknown"
        # Keep first (most recent) per service
        Map.put_new(acc, service_name, row)
      end)

    services =
      services_by_name
      |> Map.values()
      |> Enum.map(fn row ->
        %{
          service_name: Map.get(row, "service_name") || "Unknown",
          service_type: Map.get(row, "service_type") || "",
          available: Map.get(row, "available") == true,
          message: Map.get(row, "message") || "",
          timestamp: Map.get(row, "timestamp") || ""
        }
      end)
      |> Enum.sort_by(fn s -> {s.available, s.service_name} end)

    available_count = Enum.count(services, & &1.available)
    unavailable_count = length(services) - available_count

    %{
      services: services,
      total: length(services),
      available: available_count,
      unavailable: unavailable_count
    }
  end

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  defp default_device_query(device_uid, limit) do
    "in:devices uid:\"#{escape_value(device_uid)}\" limit:#{limit}"
  end

  defp default_interfaces_query(device_uid) do
    "in:interfaces device_id:\"#{escape_value(device_uid)}\" latest:true time:last_3d " <>
      "sort:if_name:asc limit:#{@interfaces_limit}"
  end

  defp srql_for_tab("interfaces", device_uid, _limit, srql)
       when is_binary(device_uid) and device_uid != "" do
    query = default_interfaces_query(device_uid)

    srql
    |> Map.put(:entity, "interfaces")
    |> Map.put(:query, query)
    |> Map.put(:draft, query)
    |> Map.put(:error, nil)
    |> Map.put(:loading, false)
  end

  defp srql_for_tab(_tab, device_uid, limit, srql)
       when is_binary(device_uid) and device_uid != "" do
    query = default_device_query(device_uid, limit)

    srql
    |> Map.put(:entity, "devices")
    |> Map.put(:query, query)
    |> Map.put(:draft, query)
    |> Map.put(:error, nil)
    |> Map.put(:loading, false)
  end

  defp srql_for_tab(_tab, _device_uid, _limit, srql), do: srql

  # ---------------------------------------------------------------------------
  # Sweep Status Section
  # ---------------------------------------------------------------------------

  attr :sweep_results, :map, required: true

  def sweep_status_section(assigns) do
    results = Map.get(assigns.sweep_results, :results, [])
    latest = List.first(results)

    assigns =
      assigns
      |> assign(:results, results)
      |> assign(:latest, latest)
      |> assign(:total, length(results))

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
      <div class="px-4 py-3 border-b border-base-200">
        <div class="flex items-center justify-between gap-3">
          <div class="flex items-center gap-2">
            <.icon name="hero-signal" class="size-4 text-info" />
            <span class="text-sm font-semibold">Network Sweep Status</span>
          </div>
          <.link navigate={~p"/settings/networks"} class="text-xs text-primary hover:underline">
            Manage Sweeps
          </.link>
        </div>
      </div>

      <div class="p-4">
        <%= if @latest do %>
          <div class="grid grid-cols-1 sm:grid-cols-3 gap-4 mb-4">
            <div class="p-3 bg-base-200/50 rounded-lg">
              <div class="text-xs text-base-content/60 uppercase">Status</div>
              <div class="mt-1 flex items-center gap-2">
                <span class={[
                  "size-2 rounded-full",
                  @latest.status == :available && "bg-success",
                  @latest.status == :unavailable && "bg-error",
                  @latest.status not in [:available, :unavailable] && "bg-warning"
                ]}>
                </span>
                <span class="font-medium">{status_label(@latest.status)}</span>
              </div>
            </div>
            <div class="p-3 bg-base-200/50 rounded-lg">
              <div class="text-xs text-base-content/60 uppercase">Response Time</div>
              <div class="mt-1 font-mono">
                {format_response_time(@latest.response_time_ms)}
              </div>
            </div>
            <div class="p-3 bg-base-200/50 rounded-lg">
              <div class="text-xs text-base-content/60 uppercase">Last Sweep</div>
              <div class="mt-1 text-sm">
                {format_sweep_time(@latest.inserted_at)}
              </div>
            </div>
          </div>

          <%= if @latest.open_ports != [] do %>
            <div class="mt-4">
              <div class="text-xs text-base-content/60 uppercase mb-2">Open Ports</div>
              <div class="flex flex-wrap gap-2">
                <%= for port <- @latest.open_ports do %>
                  <.ui_badge variant="ghost" size="sm" class="font-mono">{port}</.ui_badge>
                <% end %>
              </div>
            </div>
          <% end %>

          <%= if @total > 1 do %>
            <div class="mt-4 pt-4 border-t border-base-200">
              <div class="text-xs text-base-content/60 mb-2">
                Recent Sweep History ({@total} results)
              </div>
              <div class="overflow-x-auto">
                <table class="table table-xs">
                  <thead>
                    <tr class="text-xs text-base-content/60">
                      <th>Time</th>
                      <th>Status</th>
                      <th>Response</th>
                      <th>Ports</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for result <- Enum.take(@results, 5) do %>
                      <tr class="hover:bg-base-200/40">
                        <td class="font-mono text-xs">{format_sweep_time(result.inserted_at)}</td>
                        <td>
                          <span class={[
                            "inline-flex items-center gap-1",
                            result.status == :available && "text-success",
                            result.status == :unavailable && "text-error",
                            result.status not in [:available, :unavailable] && "text-warning"
                          ]}>
                            <span class="size-1.5 rounded-full bg-current"></span>
                            {status_label(result.status)}
                          </span>
                        </td>
                        <td class="font-mono text-xs">
                          {format_response_time(result.response_time_ms)}
                        </td>
                        <td class="font-mono text-xs">{format_ports_compact(result.open_ports)}</td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </div>
          <% end %>
        <% else %>
          <div class="text-center py-4 text-base-content/60">
            <.icon name="hero-signal-slash" class="size-8 mx-auto mb-2 opacity-50" />
            <p class="text-sm">No sweep results for this device yet.</p>
            <p class="text-xs mt-1">Add this device to a sweep group to start monitoring.</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # IP Alias Section
  # ---------------------------------------------------------------------------

  attr :aliases, :list, required: true
  attr :show_stale, :boolean, default: false
  attr :error, :string, default: nil

  def ip_aliases_section(assigns) do
    assigns =
      assigns
      |> assign(:alias_count, length(assigns.aliases))
      |> assign(:toggle_label, if(assigns.show_stale, do: "Hide stale", else: "Show stale"))

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
      <div class="px-4 py-3 border-b border-base-200 flex items-center justify-between gap-3">
        <div class="flex items-center gap-2">
          <.icon name="hero-arrow-path-rounded-square" class="size-4 text-primary" />
          <span class="text-sm font-semibold">IP Aliases</span>
          <span class="text-xs text-base-content/50">({@alias_count})</span>
        </div>
        <button
          type="button"
          phx-click="toggle_aliases"
          class="btn btn-ghost btn-xs"
          aria-pressed={@show_stale}
        >
          {@toggle_label}
        </button>
      </div>

      <div class="p-4">
        <div :if={is_binary(@error)} class="text-sm text-error">
          {@error}
        </div>

        <div :if={!is_binary(@error) and @aliases == []} class="text-sm text-base-content/60">
          No IP aliases recorded yet.
        </div>

        <div :if={!is_binary(@error) and @aliases != []} class="overflow-x-auto">
          <table class="table table-xs">
            <thead>
              <tr class="text-xs text-base-content/60">
                <th>IP Address</th>
                <th>State</th>
                <th>Sightings</th>
                <th>Last Seen</th>
              </tr>
            </thead>
            <tbody>
              <%= for alias_state <- @aliases do %>
                <tr class="hover:bg-base-200/40">
                  <td class="font-mono text-xs">{alias_state.alias_value}</td>
                  <td>
                    <span class={[
                      "badge badge-sm",
                      alias_state_class(alias_state.state)
                    ]}>
                      {alias_state_label(alias_state.state)}
                    </span>
                  </td>
                  <td class="text-xs tabular-nums">{alias_state.sighting_count || 0}</td>
                  <td class="font-mono text-xs">{format_alias_time(alias_state.last_seen_at)}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp status_label(:available), do: "Available"
  defp status_label(:unavailable), do: "Unavailable"
  defp status_label(:timeout), do: "Timeout"
  defp status_label(:error), do: "Error"
  defp status_label(other), do: to_string(other)

  defp format_response_time(nil), do: "—"
  defp format_response_time(ms) when is_number(ms), do: "#{ms}ms"
  defp format_response_time(_), do: "—"

  defp format_sweep_time(nil), do: "—"

  defp format_sweep_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp format_sweep_time(_), do: "—"

  defp format_ports_compact([]), do: "—"
  defp format_ports_compact(ports) when length(ports) <= 3, do: Enum.join(ports, ", ")
  defp format_ports_compact(ports), do: "#{length(ports)} ports"

  defp alias_state_label(nil), do: "Unknown"

  defp alias_state_label(state) do
    state
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  @alias_state_classes %{
    "confirmed" => "badge-success",
    "detected" => "badge-info",
    "updated" => "badge-warning",
    "stale" => "badge-neutral",
    "replaced" => "badge-ghost",
    "archived" => "badge-ghost"
  }

  defp alias_state_class(state) do
    state
    |> normalize_alias_state()
    |> then(&Map.get(@alias_state_classes, &1, "badge-outline"))
  end

  defp normalize_alias_state(nil), do: ""
  defp normalize_alias_state(state) when is_atom(state), do: Atom.to_string(state)
  defp normalize_alias_state(state) when is_binary(state), do: state
  defp normalize_alias_state(_), do: ""

  defp format_alias_time(nil), do: "—"

  defp format_alias_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_alias_time(%NaiveDateTime{} = dt) do
    dt
    |> DateTime.from_naive!("Etc/UTC")
    |> format_alias_time()
  end

  defp format_alias_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> format_alias_time(dt)
      _ -> value
    end
  end

  defp format_alias_time(_), do: "—"

  defp get_device_ip(results) do
    case List.first(Enum.filter(results, &is_map/1)) do
      nil -> nil
      row -> Map.get(row, "ip")
    end
  end

  defp load_sweep_results(_scope, nil), do: nil

  defp load_sweep_results(scope, ip) when is_binary(ip) do
    actor = build_sweep_actor(scope)
    require Ash.Query

    query =
      SweepHostResult
      |> Ash.Query.for_read(:by_ip, %{ip: ip}, actor: actor)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(10)

    case Ash.read(query, authorize?: true) do
      {:ok, results} when results != [] ->
        %{results: results, total: length(results)}

      _ ->
        nil
    end
  end

  defp load_sweep_results(_scope, _), do: nil

  defp build_sweep_actor(scope) do
    case scope do
      %{user: user} when not is_nil(user) ->
        %{
          id: user.id,
          email: user.email,
          role: user.role
        }

      _ ->
        %{
          id: "system",
          email: "system@serviceradar",
          role: :admin
        }
    end
  end

  # ---------------------------------------------------------------------------
  # Sysmon Profile Card (shown in Profiles tab)
  # ---------------------------------------------------------------------------

  attr :profile_info, :map, required: true
  attr :available_profiles, :list, required: true
  attr :device_uid, :string, required: true

  defp sysmon_profile_card(assigns) do
    profile = Map.get(assigns.profile_info, :profile)
    source = Map.get(assigns.profile_info, :source, "unassigned")

    assigns =
      assigns
      |> assign(:profile, profile)
      |> assign(:source, source)

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
      <div class="px-4 py-3 border-b border-base-200 flex items-center justify-between">
        <div class="flex items-center gap-2">
          <.icon name="hero-cog-6-tooth" class="size-4 text-primary" />
          <span class="text-sm font-semibold">Sysmon Profile</span>
        </div>
        <.source_badge source={@source} />
      </div>

      <div class="p-4">
        <div :if={@profile} class="space-y-4">
          <div class="flex items-center justify-between">
            <div>
              <div class="font-medium">{@profile.name}</div>
              <div class="text-xs text-base-content/60 mt-0.5">
                Sample interval: <span class="font-mono">{@profile.sample_interval}</span>
              </div>
            </div>
          </div>

          <div :if={@profile.target_query && @source == "srql"} class="text-xs">
            <span class="text-base-content/60">Matched by SRQL:</span>
            <code class="font-mono bg-base-200/50 px-1.5 py-0.5 rounded ml-1">
              {@profile.target_query}
            </code>
          </div>

          <div class="pt-2 border-t border-base-200">
            <div class="text-xs text-base-content/60 mb-2">Collection enabled:</div>
            <div class="flex flex-wrap gap-2">
              <.collection_badge enabled={@profile.collect_cpu} label="CPU" />
              <.collection_badge enabled={@profile.collect_memory} label="Memory" />
              <.collection_badge enabled={@profile.collect_disk} label="Disk" />
              <.collection_badge enabled={@profile.collect_network} label="Network" />
              <.collection_badge enabled={@profile.collect_processes} label="Processes" />
            </div>
          </div>
        </div>

        <div :if={is_nil(@profile)} class="text-sm text-base-content/60">
          No matching sysmon profile
        </div>

        <div class="text-xs text-base-content/50 pt-3 border-t border-base-200 mt-4">
          <.link navigate="/settings/sysmon" class="link link-primary">
            Manage sysmon profiles
          </.link>
        </div>
      </div>
    </div>
    """
  end

  attr :enabled, :boolean, required: true
  attr :label, :string, required: true

  defp collection_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 px-2 py-1 rounded text-xs",
      @enabled && "bg-success/10 text-success",
      not @enabled && "bg-base-200 text-base-content/40"
    ]}>
      <.icon :if={@enabled} name="hero-check" class="size-3" />
      <.icon :if={not @enabled} name="hero-x-mark" class="size-3" />
      {@label}
    </span>
    """
  end

  attr :source, :string, required: true

  defp source_badge(assigns) do
    {label, variant} =
      case assigns.source do
        "srql" -> {"SRQL Targeting", "primary"}
        "unassigned" -> {"Unassigned", "ghost"}
        "local" -> {"Local Override", "warning"}
        _ -> {"Unassigned", "ghost"}
      end

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="sm">{@label}</.ui_badge>
    """
  end

  # ---------------------------------------------------------------------------
  # Sysmon Profile Loading
  # ---------------------------------------------------------------------------

  # Extract the user from scope to use as actor for Ash operations
  defp get_profile_actor(%{user: user}) when not is_nil(user), do: user
  defp get_profile_actor(_), do: nil

  defp load_sysmon_profile_info(scope, device_uid) do
    actor = get_profile_actor(scope)

    # Load available profiles (for reference)
    available_profiles = load_available_profiles(actor)

    # Resolve the effective profile via SRQL targeting
    profile = SysmonCompiler.resolve_profile(device_uid, actor)

    # Determine source based on profile type
    source =
      cond do
        is_nil(profile) -> "unassigned"
        not is_nil(profile.target_query) -> "srql"
        true -> "unassigned"
      end

    profile_info = %{
      profile: profile,
      source: source
    }

    {profile_info, available_profiles}
  rescue
    e ->
      require Logger
      Logger.warning("Failed to load sysmon profile info: #{inspect(e)}")
      {nil, []}
  end

  defp load_available_profiles(actor) do
    case Ash.read(SysmonProfile, action: :list_available, actor: actor) do
      {:ok, profiles} -> profiles
      {:error, _} -> []
    end
  end

  # RBAC helper - check if user can edit devices
  defp can_edit_device?(%{user: %{role: role}}) do
    admin_role?(role)
  end

  defp can_edit_device?(_), do: false

  defp admin_role?(role), do: role in [:admin]

  # Update device via Ash
  defp update_device(scope, device_uid, params) do
    actor = build_device_actor(scope)

    # Parse tags from newline-separated string to map
    attrs =
      %{
        hostname: params["hostname"],
        ip: params["ip"],
        vendor_name: params["vendor_name"],
        model: params["model"],
        is_managed: parse_bool_param(params["is_managed"]),
        is_trusted: parse_bool_param(params["is_trusted"]),
        tags: parse_tags_input(params["tags"])
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new()

    # First get the device, then update it
    case Device.get_by_uid(device_uid, actor: actor) do
      {:ok, device} ->
        device
        |> Ash.Changeset.for_update(:update, attrs)
        |> Ash.update(actor: actor)

      {:error, _} = error ->
        error
    end
  end

  defp build_device_actor(scope) do
    case scope do
      %{user: user} when not is_nil(user) ->
        %{
          id: user.id,
          email: user.email,
          role: user.role
        }

      _ ->
        %{
          id: "system",
          email: "system@serviceradar",
          role: :admin
        }
    end
  end

  defp parse_tags_input(nil), do: %{}
  defp parse_tags_input(""), do: %{}

  defp parse_tags_input(tags_string) when is_binary(tags_string) do
    tags_string
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
        [key] -> Map.put(acc, String.trim(key), nil)
      end
    end)
  end

  defp parse_bool_param(value) when value in [true, false], do: value
  defp parse_bool_param("true"), do: true
  defp parse_bool_param("false"), do: false
  defp parse_bool_param("on"), do: true
  defp parse_bool_param("1"), do: true
  defp parse_bool_param("0"), do: false
  defp parse_bool_param(_), do: nil

  defp truthy?(value), do: value in [true, "true", "on", "1", 1]

  defp agent_device?(row) when is_map(row) do
    agent_id = Map.get(row, "agent_id")
    sources = Map.get(row, "discovery_sources") || []
    agent_list = Map.get(row, "agent_list") || []

    (is_binary(agent_id) and agent_id != "") or
      (is_list(agent_list) and agent_list != []) or
      Enum.any?(sources, &(&1 == "agent"))
  end

  defp agent_device?(_), do: false

  defp agent_label(row) do
    case Map.get(row, "agent_id") do
      value when is_binary(value) and value != "" -> value
      _ -> "Agent"
    end
  end

  defp device_display_name(nil), do: "Device"

  defp device_display_name(row) when is_map(row) do
    hostname = Map.get(row, "hostname")
    ip = Map.get(row, "ip")

    cond do
      is_binary(hostname) and hostname != "" -> hostname
      is_binary(ip) and ip != "" -> ip
      true -> "Device"
    end
  end

  defp device_display_name(_), do: "Device"

  defp format_ash_error(%Ash.Error.Invalid{errors: errors}) do
    Enum.map_join(errors, ", ", &format_single_ash_error/1)
  end

  defp format_ash_error(error), do: inspect(error)

  defp format_single_ash_error(%Ash.Error.Changes.InvalidAttribute{field: field, message: msg}),
    do: "#{field}: #{msg}"

  defp format_single_ash_error(%Ash.Error.Changes.Required{field: field}),
    do: "#{field} is required"

  defp format_single_ash_error(%{message: msg}) when is_binary(msg),
    do: msg

  defp format_single_ash_error(err),
    do: inspect(err)
end
