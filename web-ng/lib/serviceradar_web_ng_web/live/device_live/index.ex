defmodule ServiceRadarWebNGWeb.DeviceLive.Index do
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents
  import Ash.Expr

  require Ash.Query
  require Logger

  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage
  alias ServiceRadarWebNGWeb.SRQL.Builder, as: SRQLBuilder
  alias ServiceRadar.Inventory.Device

  @default_limit 20
  @max_limit 100
  @sparkline_device_cap 200
  @sparkline_points_per_device 20
  @sparkline_bucket "5m"
  @sparkline_window "last_1h"
  @sparkline_threshold_ms 100.0
  @presence_window "last_24h"
  @presence_bucket "24h"
  @presence_device_cap 200

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Devices")
     |> assign(:devices, [])
     |> assign(:icmp_sparklines, %{})
     |> assign(:icmp_error, nil)
     |> assign(:snmp_presence, %{})
     |> assign(:sysmon_presence, %{})
     |> assign(:sysmon_profiles_by_device, %{})
     |> assign(:limit, @default_limit)
     |> assign(:total_device_count, nil)
     |> assign(:current_page, 1)
     # Device stats for cards
     |> assign(:device_stats, %{
       total: 0,
       available: 0,
       unavailable: 0,
       by_type: [],
       by_vendor: [],
       by_risk_level: []
     })
     |> assign(:device_stats_loading, true)
     # Bulk selection
     |> assign(:selected_devices, MapSet.new())
     |> assign(:select_all_matching, false)
     |> assign(:total_matching_count, nil)
     |> assign(:show_bulk_edit_modal, false)
     |> assign(:show_bulk_delete_modal, false)
     |> assign(:bulk_edit_form, to_form(%{"tags" => ""}, as: :bulk))
     # Device management modals
     |> assign(:show_add_device_modal, false)
     |> assign(:show_import_modal, false)
     |> assign(:add_device_form, to_form(%{}, as: :device))
     # CSV import
     |> assign(:csv_preview, nil)
     |> assign(:csv_errors, [])
     |> assign(:import_status, nil)
     |> allow_upload(:csv_file,
       accept: ~w(.csv),
       max_entries: 1,
       max_file_size: 5_000_000
     )
     |> SRQLPage.init("devices", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket =
      socket
      |> SRQLPage.load_list(params, uri, :devices,
        default_limit: @default_limit,
        max_limit: @max_limit
      )

    scope = Map.get(socket.assigns, :current_scope)
    query = Map.get(socket.assigns.srql || %{}, :query, "")

    {icmp_sparklines, icmp_error} =
      load_icmp_sparklines(srql_module(), socket.assigns.devices, scope)

    {snmp_presence, sysmon_presence} =
      load_metric_presence(srql_module(), socket.assigns.devices, scope)

    sysmon_profiles_by_device = load_sysmon_profiles_for_devices(scope, socket.assigns.devices)

    # Load total count for pagination display
    total_device_count = get_total_matching_count(scope, query)

    # Track current page from URL params (default to 1 if not present or no cursor)
    current_page = parse_page_param(params)

    # Load device stats for cards (async to not block page load)
    device_stats = load_device_stats(srql_module(), scope)

    {:noreply,
     assign(socket,
       icmp_sparklines: icmp_sparklines,
       icmp_error: icmp_error,
       snmp_presence: snmp_presence,
       sysmon_presence: sysmon_presence,
       sysmon_profiles_by_device: sysmon_profiles_by_device,
       total_device_count: total_device_count,
       current_page: current_page,
       device_stats: device_stats,
       device_stats_loading: false
     )}
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, fallback_path: "/devices")}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "devices")}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_run", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_run", %{}, fallback_path: "/devices")}
  end

  def handle_event("toggle_include_deleted", _params, socket) do
    query = Map.get(socket.assigns.srql || %{}, :query, "") || ""
    updated_query = toggle_include_deleted_query(query)
    path = device_list_path(updated_query, socket.assigns.limit)
    {:noreply, push_patch(socket, to: path)}
  end

  # Device management modal handlers
  def handle_event("open_add_device_modal", _params, socket) do
    if RBAC.can?(socket.assigns.current_scope, "devices.create") do
      {:noreply, assign(socket, :show_add_device_modal, true)}
    else
      {:noreply, put_flash(socket, :error, "You are not authorized to add devices")}
    end
  end

  def handle_event("close_add_device_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_device_modal, false)
     |> assign(:add_device_form, to_form(%{}, as: :device))}
  end

  def handle_event("open_import_modal", _params, socket) do
    if RBAC.can?(socket.assigns.current_scope, "devices.import") do
      {:noreply,
       socket
       |> assign(:show_import_modal, true)
       |> assign(:csv_preview, nil)
       |> assign(:csv_errors, [])
       |> assign(:import_status, nil)}
    else
      {:noreply, put_flash(socket, :error, "You are not authorized to import devices")}
    end
  end

  def handle_event("close_import_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_import_modal, false)
     |> assign(:csv_preview, nil)
     |> assign(:csv_errors, [])
     |> assign(:import_status, nil)}
  end

  def handle_event("validate_csv", _params, socket) do
    # LiveView upload validation happens automatically
    {:noreply, socket}
  end

  def handle_event("preview_csv", _params, socket) do
    if not RBAC.can?(socket.assigns.current_scope, "devices.import") do
      {:noreply, put_flash(socket, :error, "You are not authorized to import devices")}
    else
      # Parse uploaded CSV and show preview
      case uploaded_entries(socket, :csv_file) do
        [] ->
          {:noreply, assign(socket, :csv_errors, ["No file selected"])}

        [entry | _] ->
          result =
            consume_uploaded_entry(socket, entry, fn %{path: path} ->
              parse_csv_file(path)
            end)

          case result do
            {:ok, devices} ->
              {:noreply,
               socket
               |> assign(:csv_preview, devices)
               |> assign(:csv_errors, [])}

            {:error, errors} ->
              {:noreply,
               socket
               |> assign(:csv_preview, nil)
               |> assign(:csv_errors, errors)}
          end
      end
    end
  end

  def handle_event("import_csv", _params, socket) do
    if not RBAC.can?(socket.assigns.current_scope, "devices.import") do
      {:noreply, put_flash(socket, :error, "You are not authorized to import devices")}
    else
      case socket.assigns.csv_preview do
        nil ->
          {:noreply, assign(socket, :csv_errors, ["No CSV data to import. Preview first."])}

        devices when is_list(devices) and devices != [] ->
          scope = socket.assigns.current_scope

          case import_devices(scope, devices) do
            {:ok, {created, skipped}} ->
              {:noreply,
               socket
               |> assign(:show_import_modal, false)
               |> assign(:csv_preview, nil)
               |> assign(:csv_errors, [])
               |> put_flash(:info, import_success_message(created, skipped))
               |> push_patch(to: ~p"/devices")}

            {:error, errors} when is_list(errors) ->
              {:noreply, assign(socket, :csv_errors, errors)}

            {:error, reason} ->
              {:noreply, assign(socket, :csv_errors, ["Import failed: #{inspect(reason)}"])}
          end

        _ ->
          {:noreply, assign(socket, :csv_errors, ["No valid devices in CSV"])}
      end
    end
  end

  def handle_event("validate_device", %{"device" => params}, socket) do
    {:noreply, assign(socket, :add_device_form, to_form(params, as: :device))}
  end

  def handle_event("save_device", %{"device" => params}, socket) do
    if not RBAC.can?(socket.assigns.current_scope, "devices.create") do
      {:noreply, put_flash(socket, :error, "You are not authorized to add devices")}
    else
      scope = socket.assigns.current_scope

      case create_device(scope, params) do
        {:ok, device} ->
          {:noreply,
           socket
           |> assign(:show_add_device_modal, false)
           |> assign(:add_device_form, to_form(%{}, as: :device))
           |> put_flash(:info, "Device '#{device.hostname || device.ip}' created successfully.")
           |> push_patch(to: ~p"/devices")}

        {:error, %Ash.Error.Invalid{} = error} ->
          Logger.warning("Device create failed with validation error: #{inspect(error)}")

          {:noreply,
           socket
           |> put_flash(:error, format_device_error(error))}

        {:error, %Ash.Error.Forbidden{}} ->
          {:noreply, put_flash(socket, :error, "You are not authorized to add devices")}

        {:error, :already_exists} ->
          {:noreply,
           socket
           |> put_flash(:error, "A device with this IP address already exists.")}

        {:error, :invalid_uid} ->
          Logger.error("Device create failed: generated UID was invalid for #{inspect(params)}")
          {:noreply, put_flash(socket, :error, "Failed to create device: invalid device UID")}

        {:error, :missing_scope} ->
          Logger.error("Device create failed: missing scope for #{inspect(params)}")
          {:noreply, put_flash(socket, :error, "Failed to create device: missing user scope")}

        {:error, reason} ->
          Logger.error("Device create failed: #{inspect(reason)}")
          {:noreply, put_flash(socket, :error, "Failed to create device")}
      end
    end
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    socket =
      SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "devices")
      |> assign(:selected_devices, MapSet.new())
      |> assign(:select_all_matching, false)
      |> assign(:total_matching_count, nil)

    {:noreply, socket}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    socket =
      SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "devices")
      |> assign(:selected_devices, MapSet.new())
      |> assign(:select_all_matching, false)
      |> assign(:total_matching_count, nil)

    {:noreply, socket}
  end

  # Bulk selection handlers
  def handle_event("toggle_device_select", %{"uid" => uid}, socket) do
    selected = socket.assigns.selected_devices

    updated =
      if MapSet.member?(selected, uid) do
        MapSet.delete(selected, uid)
      else
        MapSet.put(selected, uid)
      end

    {:noreply,
     socket
     |> assign(:selected_devices, updated)
     |> assign(:select_all_matching, false)
     |> assign(:total_matching_count, nil)}
  end

  def handle_event("toggle_select_all", _params, socket) do
    devices = socket.assigns.devices
    selected = socket.assigns.selected_devices

    device_uids =
      devices
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn row -> Map.get(row, "uid") || Map.get(row, "id") end)
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    updated =
      if MapSet.subset?(device_uids, selected) do
        # All current page devices selected, deselect them
        MapSet.difference(selected, device_uids)
      else
        # Select all current page devices
        MapSet.union(selected, device_uids)
      end

    {:noreply,
     socket
     |> assign(:selected_devices, updated)
     |> assign(:select_all_matching, false)
     |> assign(:total_matching_count, nil)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected_devices, MapSet.new())}
  end

  def handle_event("open_bulk_edit_modal", _params, socket) do
    if RBAC.can?(socket.assigns.current_scope, "devices.bulk_edit") do
      {:noreply, assign(socket, :show_bulk_edit_modal, true)}
    else
      {:noreply, put_flash(socket, :error, "You are not authorized to bulk edit devices")}
    end
  end

  def handle_event("open_bulk_delete_modal", _params, socket) do
    if RBAC.can?(socket.assigns.current_scope, "devices.bulk_delete") do
      {:noreply, assign(socket, :show_bulk_delete_modal, true)}
    else
      {:noreply, put_flash(socket, :error, "You are not authorized to bulk delete devices")}
    end
  end

  def handle_event("close_bulk_edit_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_bulk_edit_modal, false)
     |> assign(:bulk_edit_form, to_form(%{"tags" => ""}, as: :bulk))}
  end

  def handle_event("close_bulk_delete_modal", _params, socket) do
    {:noreply, assign(socket, :show_bulk_delete_modal, false)}
  end

  def handle_event("toggle_select_all_matching", _params, socket) do
    current = socket.assigns.select_all_matching

    socket =
      if current do
        # Turning off - clear selection
        socket
        |> assign(:select_all_matching, false)
        |> assign(:selected_devices, MapSet.new())
        |> assign(:total_matching_count, nil)
      else
        # Turning on - get total count
        scope = socket.assigns.current_scope
        query = Map.get(socket.assigns.srql || %{}, :query, "")
        total = get_total_matching_count(scope, query)

        socket
        |> assign(:select_all_matching, true)
        |> assign(:total_matching_count, total)
      end

    {:noreply, socket}
  end

  def handle_event("apply_bulk_tags", %{"bulk" => params}, socket) do
    if RBAC.can?(socket.assigns.current_scope, "devices.bulk_edit") do
      apply_bulk_tags(params, socket)
    else
      {:noreply, put_flash(socket, :error, "You are not authorized to bulk edit devices")}
    end
  end

  def handle_event("bulk_delete_devices", _params, socket) do
    handle_confirm_bulk_delete(socket)
  end

  def handle_event("confirm_bulk_delete", _params, socket) do
    handle_confirm_bulk_delete(socket)
  end

  defp apply_bulk_tags(params, socket) do
    scope = socket.assigns.current_scope
    tags_input = Map.get(params, "tags", "")
    tags = parse_bulk_tags(tags_input)

    if tags == %{} do
      {:noreply,
       socket
       |> assign(:bulk_edit_form, to_form(params, as: :bulk))
       |> put_flash(:error, "Enter at least one tag to apply")}
    else
      case apply_tags_to_devices(scope, socket, tags) do
        {:ok, count} ->
          {:noreply,
           socket
           |> assign(:show_bulk_edit_modal, false)
           |> assign(:bulk_edit_form, to_form(%{"tags" => ""}, as: :bulk))
           |> assign(:selected_devices, MapSet.new())
           |> assign(:select_all_matching, false)
           |> assign(:total_matching_count, nil)
           |> put_flash(:info, "Applied tags to #{count} device(s)")}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:bulk_edit_form, to_form(params, as: :bulk))
           |> put_flash(:error, "Failed to apply tags: #{reason}")}
      end
    end
  end

  defp handle_confirm_bulk_delete(socket) do
    scope = socket.assigns.current_scope

    if not RBAC.can?(scope, "devices.bulk_delete") do
      {:noreply, put_flash(socket, :error, "You are not authorized to bulk delete devices")}
    else
      do_bulk_delete(socket, scope)
    end
  end

  defp do_bulk_delete(socket, scope) do
    case bulk_delete_uids(socket) do
      {:ok, uids} ->
        case Device.bulk_soft_delete(uids, "bulk_delete", scope: scope) do
          :ok ->
            path =
              device_list_path(
                Map.get(socket.assigns.srql || %{}, :query, ""),
                socket.assigns.limit
              )

            count = length(uids)

            {:noreply,
             socket
             |> assign(:show_bulk_delete_modal, false)
             |> assign(:selected_devices, MapSet.new())
             |> assign(:select_all_matching, false)
             |> assign(:total_matching_count, nil)
             |> put_flash(:info, "Deleted #{count} device(s)")
             |> push_patch(to: path)}

          {:ok, %{deleted_count: count}} ->
            path =
              device_list_path(
                Map.get(socket.assigns.srql || %{}, :query, ""),
                socket.assigns.limit
              )

            {:noreply,
             socket
             |> assign(:show_bulk_delete_modal, false)
             |> assign(:selected_devices, MapSet.new())
             |> assign(:select_all_matching, false)
             |> assign(:total_matching_count, nil)
             |> put_flash(:info, "Deleted #{count} device(s)")
             |> push_patch(to: path)}

          {:error, reason} ->
            Logger.error("Bulk device delete failed for #{inspect(uids)}: #{inspect(reason)}")

            {:noreply,
             socket
             |> assign(:show_bulk_delete_modal, false)
             |> put_flash(:error, "Bulk delete failed: #{format_device_error(reason)}")}
        end

      {:error, reason} ->
        Logger.error("Bulk device delete failed: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:show_bulk_delete_modal, false)
         |> put_flash(:error, reason)}
    end
  end

  # Get device UIDs from selected devices or all matching devices
  defp get_selected_uids(socket) do
    if socket.assigns.select_all_matching do
      scope = socket.assigns.current_scope
      query = Map.get(socket.assigns.srql || %{}, :query, "")
      get_all_matching_uids(scope, query)
    else
      socket.assigns.selected_devices
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
    end
  end

  defp apply_tags_to_devices(scope, socket, tags) do
    cond do
      socket.assigns.select_all_matching and
          not is_integer(socket.assigns.total_matching_count) ->
        {:error, "Unable to determine selection size. Please try again."}

      socket.assigns.select_all_matching and
          socket.assigns.total_matching_count > 10_000 ->
        {:error, "Too many devices selected. Narrow your filters and try again."}

      true ->
        case get_selected_uids(socket) do
          [] ->
            {:error, "No devices selected"}

          uids ->
            update_tags_for_uids(scope, uids, tags)
        end
    end
  end

  defp bulk_delete_uids(socket) do
    cond do
      socket.assigns.select_all_matching and
          not is_integer(socket.assigns.total_matching_count) ->
        {:error, "Unable to determine selection size. Please try again."}

      socket.assigns.select_all_matching and socket.assigns.total_matching_count > 10_000 ->
        {:error, "Too many devices selected. Narrow your filters and try again."}

      true ->
        case get_selected_uids(socket) do
          [] -> {:error, "No devices selected"}
          uids -> {:ok, uids}
        end
    end
  end

  defp update_tags_for_uids(_scope, uids, new_tags) do
    query =
      Device
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(uid in ^uids)

    case Ash.count(query) do
      {:ok, existing_count} ->
        requested_count = length(uids)
        result = bulk_update_tags(query, new_tags)
        handle_bulk_update_result(result, existing_count, requested_count)

      {:error, error} ->
        {:error, format_changeset_errors(error)}
    end
  end

  defp bulk_update_tags(query, new_tags) do
    Ash.bulk_update(query, :update, %{},
      return_records?: false,
      return_errors?: true,
      atomic_update: %{
        tags: expr(fragment("coalesce(?, '{}'::jsonb) || (?::jsonb)", ^ref(:tags), ^new_tags))
      }
    )
  end

  defp handle_bulk_update_result(result, existing_count, requested_count) do
    case result do
      %Ash.BulkResult{status: :success} ->
        if existing_count < requested_count do
          {:error, "One or more devices were not found"}
        else
          {:ok, existing_count}
        end

      %Ash.BulkResult{status: :partial_success, errors: errors} ->
        {:error, format_changeset_errors(List.first(errors || []))}

      %Ash.BulkResult{status: :error, errors: errors} ->
        {:error, format_changeset_errors(List.first(errors || []))}
    end
  end

  defp parse_bulk_tags(input) when is_binary(input) do
    input
    |> String.split(~r/[\n,]/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(%{}, fn entry, acc ->
      case parse_tag_entry(entry) do
        {:ok, key, value} -> Map.put(acc, key, value)
        :skip -> acc
      end
    end)
  end

  defp parse_bulk_tags(_), do: %{}

  defp parse_tag_entry(entry) do
    case String.split(entry, "=", parts: 2) do
      [key, value] -> normalize_tag_entry(key, value)
      [key] -> normalize_tag_entry(key, "")
    end
  end

  defp normalize_tag_entry(key, value) do
    key = String.trim(key)

    if key == "" do
      :skip
    else
      {:ok, key, String.trim(value)}
    end
  end

  @impl true
  def render(assigns) do
    pagination = get_in(assigns, [:srql, :pagination]) || %{}
    selected_count = MapSet.size(assigns.selected_devices)

    # Check if all visible devices are selected
    visible_uids =
      assigns.devices
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn row -> Map.get(row, "uid") || Map.get(row, "id") end)
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    all_selected =
      MapSet.size(visible_uids) > 0 and MapSet.subset?(visible_uids, assigns.selected_devices)

    # Compute effective count (either selected or all matching)
    effective_count =
      if assigns.select_all_matching do
        assigns.total_matching_count || 0
      else
        selected_count
      end

    assigns =
      assigns
      |> assign(:pagination, pagination)
      |> assign(:selected_count, selected_count)
      |> assign(:effective_count, effective_count)
      |> assign(:all_selected, all_selected)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6">
        <!-- Header with Action Buttons -->
        <div class="mb-6 flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-base-content">Devices</h1>
            <p class="text-sm text-base-content/60">
              Manage and monitor your network devices
            </p>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <.ui_button
              :if={RBAC.can?(@current_scope, "devices.create")}
              phx-click="open_add_device_modal"
              variant="primary"
              size="sm"
            >
              <.icon name="hero-plus" class="size-4" /> Add Device
            </.ui_button>
            <.ui_button
              :if={RBAC.can?(@current_scope, "devices.import")}
              phx-click="open_import_modal"
              variant="outline"
              size="sm"
            >
              <.icon name="hero-arrow-up-tray" class="size-4" /> Import CSV
            </.ui_button>
            <.link :if={RBAC.can?(@current_scope, "settings.networks.manage")} navigate={~p"/settings/networks"}>
              <.ui_button variant="ghost" size="sm">
                <.icon name="hero-signal" class="size-4" /> Network Discovery
              </.ui_button>
            </.link>
          </div>
        </div>
        
    <!-- Device Stats Cards -->
        <.device_stats_cards
          stats={@device_stats}
          loading={@device_stats_loading}
        />
        
    <!-- Quick Filters -->
        <div class="mb-4 flex flex-wrap items-center gap-2">
          <span class="text-xs font-medium text-base-content/60 mr-1">Quick filters:</span>
          <.link
            navigate={~p"/devices?q=in:devices is_available:true"}
            class={"btn btn-xs #{if has_filter?(@srql, "is_available", "true"), do: "btn-primary", else: "btn-ghost"}"}
          >
            <.icon name="hero-check-circle" class="size-3" /> Available
          </.link>
          <.link
            navigate={~p"/devices?q=in:devices is_available:false"}
            class={"btn btn-xs #{if has_filter?(@srql, "is_available", "false"), do: "btn-error", else: "btn-ghost"}"}
          >
            <.icon name="hero-x-circle" class="size-3" /> Unavailable
          </.link>
          <.link
            navigate={~p"/devices?q=in:devices discovery_sources:(sweep)"}
            class={"btn btn-xs #{if has_filter?(@srql, "discovery_sources", "sweep"), do: "btn-info", else: "btn-ghost"}"}
          >
            <.icon name="hero-signal" class="size-3" /> Swept
          </.link>
          <button
            phx-click="toggle_include_deleted"
            class={"btn btn-xs #{if has_filter?(@srql, "include_deleted", "true"), do: "btn-secondary", else: "btn-ghost"}"}
          >
            <.icon name="hero-archive-box" class="size-3" /> Include deleted
          </button>
          <.link
            :if={has_any_filter?(@srql)}
            navigate={~p"/devices"}
            class="btn btn-xs btn-ghost"
          >
            <.icon name="hero-x-mark" class="size-3" /> Clear
          </.link>
        </div>
        
    <!-- Bulk Actions Bar -->
        <div
          :if={@selected_count > 0 or @select_all_matching}
          class="mb-4 p-3 bg-primary/10 border border-primary/20 rounded-lg flex flex-wrap items-center justify-between gap-3"
        >
          <div class="flex flex-wrap items-center gap-3">
            <span class="text-sm font-medium text-primary">
              <%= if @select_all_matching do %>
                <.icon name="hero-check-badge" class="size-4 inline" />
                All {@total_matching_count} matching device(s) selected
              <% else %>
                {String.pad_leading(Integer.to_string(@selected_count), 2, "0")} device(s) selected
              <% end %>
            </span>
            
    <!-- Select All Matching Toggle -->
            <button
              :if={!@select_all_matching and has_any_filter?(@srql)}
              phx-click="toggle_select_all_matching"
              class="text-xs text-primary hover:text-primary-focus underline"
            >
              Select all matching filter
            </button>

            <button
              phx-click="clear_selection"
              class="text-xs text-base-content/60 hover:text-base-content"
            >
              Clear selection
            </button>
          </div>
          <div class="flex items-center gap-2">
            <.ui_button
              :if={RBAC.can?(@current_scope, "devices.bulk_edit")}
              variant="primary"
              size="sm"
              phx-click="open_bulk_edit_modal"
            >
              <.icon name="hero-tag" class="size-4" /> Bulk Edit
            </.ui_button>
            <.ui_button
              :if={RBAC.can?(@current_scope, "devices.bulk_delete")}
              variant="outline"
              class="btn-error"
              size="sm"
              phx-click="open_bulk_delete_modal"
            >
              <.icon name="hero-trash" class="size-4" /> Bulk Delete
            </.ui_button>
          </div>
        </div>

        <.ui_panel>
          <:header>
            <div :if={is_binary(@icmp_error)} class="badge badge-warning badge-sm">
              ICMP: {@icmp_error}
            </div>
          </:header>

          <div class="overflow-x-auto">
            <table class="table table-sm table-zebra w-full">
              <thead>
                <tr>
                  <th class="w-10 text-center bg-base-200/60">
                    <input
                      type="checkbox"
                      class="checkbox checkbox-sm checkbox-primary"
                      checked={@all_selected}
                      phx-click="toggle_select_all"
                    />
                  </th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Hostname</th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">IP</th>
                  <th
                    class="text-xs font-semibold text-base-content/70 bg-base-200/60"
                    title="OCSF Device Type"
                  >
                    Type
                  </th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Vendor</th>
                  <th
                    class="text-xs font-semibold text-base-content/70 bg-base-200/60"
                    title="GRPC Health Check Status"
                  >
                    Status
                  </th>
                  <th
                    class="text-xs font-semibold text-base-content/70 bg-base-200/60"
                    title="ICMP Network Tests"
                  >
                    Network
                  </th>
                  <th
                    class="text-xs font-semibold text-base-content/70 bg-base-200/60"
                    title="Telemetry availability for this device"
                  >
                    Metrics
                  </th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Risk</th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Last Seen</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@devices == []}>
                  <td
                    colspan={10}
                    class="py-8 text-center text-sm text-base-content/60"
                  >
                    No devices found.
                  </td>
                </tr>

                <%= for row <- Enum.filter(@devices, &is_map/1) do %>
                  <% device_uid = Map.get(row, "uid") || Map.get(row, "id") %>
                  <% is_selected =
                    is_binary(device_uid) and MapSet.member?(@selected_devices, device_uid) %>
                  <% deleted = deleted_device_row?(row) %>
                  <% icmp =
                    if is_binary(device_uid), do: Map.get(@icmp_sparklines, device_uid), else: nil %>
                  <% has_snmp =
                    is_binary(device_uid) and Map.get(@snmp_presence, device_uid, false) == true %>
                  <% has_sysmon =
                    is_binary(device_uid) and Map.get(@sysmon_presence, device_uid, false) == true %>
                  <tr class={"hover:bg-base-200/40 #{if is_selected, do: "bg-primary/5", else: ""} #{if deleted, do: "opacity-60", else: ""}"}>
                    <td class="text-center">
                      <input
                        :if={is_binary(device_uid)}
                        type="checkbox"
                        class="checkbox checkbox-sm checkbox-primary"
                        checked={is_selected}
                        phx-click="toggle_device_select"
                        phx-value-uid={device_uid}
                      />
                    </td>
                    <td class="text-sm max-w-[18rem] truncate">
                      <div class="flex items-center gap-2 min-w-0">
                        <.icon
                          :if={agent_device_row?(row)}
                          name="hero-bolt"
                          class="size-3 text-accent"
                          title="Agent device"
                        />
                        <.link
                          :if={is_binary(device_uid)}
                          navigate={~p"/devices/#{device_uid}"}
                          class="link link-hover truncate"
                          title={"UID: #{device_uid}"}
                        >
                          {Map.get(row, "hostname") || device_uid}
                        </.link>
                        <span :if={not is_binary(device_uid)} class="truncate">
                          {Map.get(row, "hostname") || "—"}
                        </span>
                        <span :if={deleted} class="badge badge-ghost badge-xs">Deleted</span>
                      </div>
                    </td>
                    <td class="font-mono text-xs">{Map.get(row, "ip") || "—"}</td>
                    <td class="text-xs">
                      <.device_type_badge
                        type={Map.get(row, "type")}
                        type_id={Map.get(row, "type_id")}
                      />
                    </td>
                    <td class="text-xs max-w-[8rem] truncate">
                      {Map.get(row, "vendor_name") || "—"}
                    </td>
                    <td class="text-xs">
                      <.availability_badge available={Map.get(row, "is_available")} />
                    </td>
                    <td class="text-xs">
                      <.icmp_sparkline :if={is_map(icmp)} spark={icmp} />
                      <span :if={not is_map(icmp)} class="text-base-content/40">—</span>
                    </td>
                    <td class="text-xs">
                      <.metrics_presence
                        device_uid={device_uid}
                        has_snmp={has_snmp}
                        has_sysmon={has_sysmon}
                      />
                    </td>
                    <td class="text-xs">
                      <.risk_level_badge risk_level={Map.get(row, "risk_level")} />
                    </td>
                    <td class="font-mono text-xs">
                      <.srql_cell col="last_seen" value={Map.get(row, "last_seen")} />
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>

          <div class="mt-4 pt-4 border-t border-base-200">
            <.ui_pagination
              prev_cursor={Map.get(@pagination, "prev_cursor")}
              next_cursor={Map.get(@pagination, "next_cursor")}
              base_path="/devices"
              query={Map.get(@srql, :query, "")}
              limit={@limit}
              result_count={length(@devices)}
              total_count={@total_device_count}
              current_page={@current_page}
            />
          </div>
        </.ui_panel>
      </div>
      
    <!-- Add Device Modal -->
      <.add_device_modal :if={@show_add_device_modal} form={@add_device_form} />
      
    <!-- Import CSV Modal -->
      <.import_csv_modal
        :if={@show_import_modal}
        uploads={@uploads}
        csv_preview={@csv_preview}
        csv_errors={@csv_errors}
      />
      
    <!-- Bulk Edit Modal -->
      <.bulk_edit_modal
        :if={@show_bulk_edit_modal}
        form={@bulk_edit_form}
        selected_count={@effective_count}
      />
      
    <!-- Bulk Delete Modal -->
      <.bulk_delete_modal
        :if={@show_bulk_delete_modal}
        selected_count={@effective_count}
      />
    </Layouts.app>
    """
  end

  # Add Device Modal Component
  attr :form, :any, required: true

  defp add_device_modal(assigns) do
    ~H"""
    <dialog id="add_device_modal" class="modal modal-open">
      <div class="modal-box max-w-lg">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_add_device_modal"
          >
            x
          </button>
        </form>

        <h3 class="text-lg font-bold">Add Device</h3>
        <p class="py-2 text-sm text-base-content/70">
          Add a new device to your inventory. For automatic discovery, use Network Sweeps.
        </p>

        <.form
          for={@form}
          id="add-device-form"
          phx-change="validate_device"
          phx-submit="save_device"
          class="space-y-4"
        >
          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Hostname</span>
            </label>
            <input
              type="text"
              name="device[hostname]"
              value={@form[:hostname].value}
              class="input input-bordered"
              placeholder="server01.example.com"
            />
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">IP Address</span>
            </label>
            <input
              type="text"
              name="device[ip]"
              value={@form[:ip].value}
              class="input input-bordered"
              placeholder="192.168.1.100"
            />
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Device Type</span>
            </label>
            <select name="device[type]" class="select select-bordered">
              <option value="">Select type...</option>
              <option value="server">Server</option>
              <option value="workstation">Workstation</option>
              <option value="router">Router</option>
              <option value="switch">Switch</option>
              <option value="firewall">Firewall</option>
              <option value="printer">Printer</option>
              <option value="other">Other</option>
            </select>
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Tags</span>
              <span class="label-text-alt text-base-content/50">Optional, one per line</span>
            </label>
            <textarea
              name="device[tags]"
              class="textarea textarea-bordered h-20"
              placeholder="env=production&#10;team=infrastructure"
            >{@form[:tags].value}</textarea>
          </div>

          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click="close_add_device_modal">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary">
              <.icon name="hero-plus" class="size-4" /> Add Device
            </button>
          </div>
        </.form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_add_device_modal">close</button>
      </form>
    </dialog>
    """
  end

  # Import CSV Modal Component
  attr :uploads, :any, required: true
  attr :csv_preview, :any, default: nil
  attr :csv_errors, :list, default: []

  defp import_csv_modal(assigns) do
    ~H"""
    <dialog id="import_csv_modal" class="modal modal-open">
      <div class="modal-box max-w-3xl">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_import_modal"
          >
            x
          </button>
        </form>

        <h3 class="text-lg font-bold">Import Devices from CSV</h3>
        <p class="py-2 text-sm text-base-content/70">
          Upload a CSV file to bulk import devices into your inventory.
        </p>
        
    <!-- Error Display -->
        <div :if={@csv_errors != []} class="alert alert-error my-4">
          <.icon name="hero-exclamation-circle" class="size-5" />
          <div>
            <div class="font-semibold">Import Error</div>
            <ul class="text-sm list-disc list-inside">
              <%= for error <- @csv_errors do %>
                <li>{error}</li>
              <% end %>
            </ul>
          </div>
        </div>
        
    <!-- CSV Format Guide (collapsed when preview is shown) -->
        <div :if={is_nil(@csv_preview)} class="my-4 p-4 bg-base-200/50 rounded-lg">
          <h4 class="font-medium text-sm mb-2">CSV Format</h4>
          <p class="text-xs text-base-content/70 mb-3">
            Your CSV file should include the following columns:
          </p>
          <div class="overflow-x-auto">
            <table class="table table-xs">
              <thead>
                <tr>
                  <th>Column</th>
                  <th>Required</th>
                  <th>Description</th>
                </tr>
              </thead>
              <tbody class="text-xs">
                <tr>
                  <td class="font-mono">hostname</td>
                  <td><span class="badge badge-xs badge-success">Yes</span></td>
                  <td>Device hostname</td>
                </tr>
                <tr>
                  <td class="font-mono">ip</td>
                  <td><span class="badge badge-xs badge-success">Yes</span></td>
                  <td>IP address</td>
                </tr>
                <tr>
                  <td class="font-mono">type</td>
                  <td><span class="badge badge-xs badge-ghost">No</span></td>
                  <td>Device type (server, workstation, router, etc.)</td>
                </tr>
                <tr>
                  <td class="font-mono">tags</td>
                  <td><span class="badge badge-xs badge-ghost">No</span></td>
                  <td>Pipe-separated tags (env=prod|team=ops)</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
        
    <!-- File Upload -->
        <.form for={%{}} phx-change="validate_csv" phx-submit="preview_csv" class="space-y-4">
          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Upload CSV File</span>
              <span class="label-text-alt text-base-content/50">Max 5MB</span>
            </label>
            <.live_file_input
              upload={@uploads.csv_file}
              class="file-input file-input-bordered w-full"
            />
            <%= for entry <- @uploads.csv_file.entries do %>
              <div class="mt-2 flex items-center gap-2 text-sm">
                <.icon name="hero-document-text" class="size-4 text-primary" />
                <span>{entry.client_name}</span>
                <span class="text-base-content/50">
                  ({Float.round(entry.client_size / 1024, 1)} KB)
                </span>
                <%= for err <- upload_errors(@uploads.csv_file, entry) do %>
                  <span class="text-error text-xs">{error_to_string(err)}</span>
                <% end %>
              </div>
            <% end %>
          </div>

          <div :if={is_nil(@csv_preview)} class="flex justify-end">
            <button
              type="submit"
              class="btn btn-outline btn-sm"
              disabled={@uploads.csv_file.entries == []}
            >
              <.icon name="hero-eye" class="size-4" /> Preview
            </button>
          </div>
        </.form>
        
    <!-- Preview Table -->
        <div :if={is_list(@csv_preview) and @csv_preview != []} class="mt-4">
          <div class="flex items-center justify-between mb-2">
            <h4 class="font-medium text-sm">
              Preview ({length(@csv_preview)} device(s))
            </h4>
            <span class="badge badge-success badge-sm">Ready to import</span>
          </div>
          <div class="overflow-x-auto max-h-64 border border-base-200 rounded-lg">
            <table class="table table-xs table-pin-rows">
              <thead>
                <tr class="bg-base-200">
                  <th>Hostname</th>
                  <th>IP</th>
                  <th>Type</th>
                  <th>Tags</th>
                </tr>
              </thead>
              <tbody>
                <%= for device <- Enum.take(@csv_preview, 20) do %>
                  <tr class="hover:bg-base-200/50">
                    <td class="font-mono text-xs">{device.hostname}</td>
                    <td class="font-mono text-xs">{device.ip}</td>
                    <td class="text-xs">{device.type}</td>
                    <td class="text-xs">{Enum.join(device.tags || [], ", ")}</td>
                  </tr>
                <% end %>
                <%= if length(@csv_preview) > 20 do %>
                  <tr>
                    <td colspan="4" class="text-center text-xs text-base-content/50 py-2">
                      ... and {length(@csv_preview) - 20} more
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>

        <div class="mt-4 flex items-center gap-2 text-xs text-base-content/60">
          <.icon name="hero-arrow-down-tray" class="size-4" />
          <a
            href="data:text/csv;charset=utf-8,hostname,ip,type,tags%0Aserver01.example.com,192.168.1.10,server,env=prod|team=infra%0Arouter01.example.com,192.168.1.1,router,"
            class="link link-hover"
            download="devices-template.csv"
          >
            Download CSV template
          </a>
        </div>

        <div class="modal-action">
          <button type="button" class="btn btn-ghost" phx-click="close_import_modal">
            Cancel
          </button>
          <button
            :if={is_list(@csv_preview) and @csv_preview != []}
            type="button"
            class="btn btn-primary"
            phx-click="import_csv"
          >
            <.icon name="hero-arrow-up-tray" class="size-4" /> Import {length(@csv_preview)} Device(s)
          </button>
          <.link :if={is_nil(@csv_preview)} navigate={~p"/settings/networks"}>
            <button type="button" class="btn btn-outline">
              <.icon name="hero-signal" class="size-4" /> Use Network Discovery
            </button>
          </.link>
        </div>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_import_modal">close</button>
      </form>
    </dialog>
    """
  end

  defp error_to_string(:too_large), do: "File is too large (max 5MB)"
  defp error_to_string(:not_accepted), do: "Invalid file type (only .csv allowed)"
  defp error_to_string(:too_many_files), do: "Only one file allowed"
  defp error_to_string(err), do: inspect(err)

  # Bulk Edit Modal Component
  attr :form, :any, required: true
  attr :selected_count, :integer, required: true

  defp bulk_edit_modal(assigns) do
    ~H"""
    <dialog id="bulk_edit_modal" class="modal modal-open">
      <div class="modal-box max-w-lg">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_bulk_edit_modal"
          >
            x
          </button>
        </form>

        <h3 class="text-lg font-bold">Bulk Edit Devices</h3>
        <p class="py-2 text-sm text-base-content/70">
          Apply tags to {@selected_count} selected device(s).
        </p>

        <.form for={@form} id="bulk-tags-form" phx-submit="apply_bulk_tags" class="space-y-4">
          <div>
            <label class="label">
              <span class="label-text font-medium">Tags</span>
              <span class="label-text-alt text-base-content/50">key or key=value</span>
            </label>
            <.input
              type="textarea"
              field={@form[:tags]}
              class="textarea textarea-bordered w-full font-mono text-sm"
              rows="4"
              placeholder="env=prod\ncritical\nregion=us-east"
            />
          </div>

          <div class="flex justify-end gap-2 pt-2">
            <button type="button" phx-click="close_bulk_edit_modal" class="btn btn-ghost">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary">
              Apply Tags
            </button>
          </div>
        </.form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_bulk_edit_modal">close</button>
      </form>
    </dialog>
    """
  end

  # Bulk Delete Modal Component
  attr :selected_count, :integer, required: true

  defp bulk_delete_modal(assigns) do
    ~H"""
    <dialog id="bulk_delete_modal" class="modal modal-open">
      <div class="modal-box max-w-lg">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_bulk_delete_modal"
          >
            x
          </button>
        </form>

        <h3 class="text-lg font-bold text-error">Delete Devices</h3>
        <p class="py-2 text-sm text-base-content/70">
          This will hide {@selected_count} selected device(s) from inventory. They can be restored
          later.
        </p>

        <div class="flex justify-end gap-2 pt-2">
          <button type="button" phx-click="close_bulk_delete_modal" class="btn btn-ghost">
            Cancel
          </button>
          <button type="button" phx-click="confirm_bulk_delete" class="btn btn-error">
            Delete Devices
          </button>
        </div>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_bulk_delete_modal">close</button>
      </form>
    </dialog>
    """
  end

  # Device Stats Cards Component
  attr :stats, :map, required: true
  attr :loading, :boolean, default: false

  def device_stats_cards(assigns) do
    stats = assigns.stats || %{}
    total = Map.get(stats, :total, 0)
    available = Map.get(stats, :available, 0)
    unavailable = Map.get(stats, :unavailable, 0)
    by_type = Map.get(stats, :by_type, [])
    by_vendor = Map.get(stats, :by_vendor, [])
    by_risk_level = Map.get(stats, :by_risk_level, [])

    # Get top items for display
    top_type = List.first(by_type)
    top_vendor = List.first(by_vendor)

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:available, available)
      |> assign(:unavailable, unavailable)
      |> assign(:by_type, by_type)
      |> assign(:by_vendor, by_vendor)
      |> assign(:by_risk_level, by_risk_level)
      |> assign(:top_type, top_type)
      |> assign(:top_vendor, top_vendor)

    ~H"""
    <div class="mb-6">
      <div :if={@loading} class="grid grid-cols-2 md:grid-cols-4 gap-3">
        <div class="rounded-xl border border-base-200 bg-base-100 p-4 h-24 animate-pulse">
          <div class="h-4 bg-base-200 rounded w-1/2 mb-2" />
          <div class="h-6 bg-base-200 rounded w-3/4" />
        </div>
        <div class="rounded-xl border border-base-200 bg-base-100 p-4 h-24 animate-pulse">
          <div class="h-4 bg-base-200 rounded w-1/2 mb-2" />
          <div class="h-6 bg-base-200 rounded w-3/4" />
        </div>
        <div class="rounded-xl border border-base-200 bg-base-100 p-4 h-24 animate-pulse">
          <div class="h-4 bg-base-200 rounded w-1/2 mb-2" />
          <div class="h-6 bg-base-200 rounded w-3/4" />
        </div>
        <div class="rounded-xl border border-base-200 bg-base-100 p-4 h-24 animate-pulse">
          <div class="h-4 bg-base-200 rounded w-1/2 mb-2" />
          <div class="h-6 bg-base-200 rounded w-3/4" />
        </div>
      </div>

      <div :if={not @loading} class="grid grid-cols-2 md:grid-cols-4 gap-3">
        <!-- Total Devices -->
        <.link navigate={~p"/devices"} class="block group">
          <div class="rounded-xl border border-base-200 bg-base-100 p-4 hover:shadow-md transition-shadow cursor-pointer flex items-center gap-3">
            <div class="p-2.5 rounded-lg bg-primary/10">
              <.icon name="hero-server" class="size-5 text-primary" />
            </div>
            <div class="flex-1 min-w-0">
              <div class="text-xl font-bold text-base-content">{format_stat_number(@total)}</div>
              <div class="text-xs text-base-content/60">Total Devices</div>
            </div>
          </div>
        </.link>
        
    <!-- Availability -->
        <.link
          navigate={~p"/devices?q=in:devices is_available:true"}
          class="block group"
        >
          <div class={[
            "rounded-xl border p-4 hover:shadow-md transition-shadow cursor-pointer flex items-center gap-3",
            if(@unavailable > 0,
              do: "border-error/30 bg-error/5",
              else: "border-success/30 bg-success/5"
            )
          ]}>
            <div class={[
              "p-2.5 rounded-lg",
              if(@unavailable > 0, do: "bg-error/10", else: "bg-success/10")
            ]}>
              <.icon
                name={if(@unavailable > 0, do: "hero-signal-slash", else: "hero-signal")}
                class={["size-5", if(@unavailable > 0, do: "text-error", else: "text-success")]}
              />
            </div>
            <div class="flex-1 min-w-0">
              <div class="flex items-baseline gap-1">
                <span class={[
                  "text-xl font-bold",
                  if(@unavailable > 0, do: "text-error", else: "text-success")
                ]}>
                  {format_stat_number(@available)}
                </span>
                <span :if={@unavailable > 0} class="text-sm text-error/80">
                  / {format_stat_number(@unavailable)} offline
                </span>
              </div>
              <div class="text-xs text-base-content/60">
                {if @unavailable == 0, do: "All Online", else: "Available"}
              </div>
            </div>
          </div>
        </.link>
        
    <!-- Top Device Type -->
        <.device_breakdown_card
          title="By Type"
          items={@by_type}
          icon="hero-cpu-chip"
          filter_field="type"
          empty_text="No type data"
        />
        
    <!-- Top Vendor -->
        <.device_breakdown_card
          title="By Vendor"
          items={@by_vendor}
          icon="hero-building-office"
          filter_field="vendor_name"
          empty_text="No vendor data"
        />
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :items, :list, required: true
  attr :icon, :string, required: true
  attr :filter_field, :string, required: true
  attr :empty_text, :string, default: "No data"

  defp device_breakdown_card(assigns) do
    items = assigns.items || []
    top_item = List.first(items)
    other_count = items |> Enum.drop(1) |> Enum.reduce(0, fn %{count: c}, acc -> acc + c end)

    # Build the link for the top item (skip "Unknown" since we can't filter NULL values)
    top_item_link =
      if top_item && top_item.name != "Unknown" do
        "/devices?q=" <> URI.encode("in:devices #{assigns.filter_field}:\"#{top_item.name}\"")
      else
        nil
      end

    assigns =
      assigns
      |> assign(:top_item, top_item)
      |> assign(:other_count, other_count)
      |> assign(:item_count, length(items))
      |> assign(:top_item_link, top_item_link)

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 p-4 hover:shadow-md transition-shadow">
      <div class="flex items-center gap-3">
        <div class="p-2.5 rounded-lg bg-info/10">
          <.icon name={@icon} class="size-5 text-info" />
        </div>
        <div class="flex-1 min-w-0">
          <!-- Clickable top item (when not "Unknown") -->
          <.link
            :if={@top_item && @top_item_link}
            navigate={@top_item_link}
            class="block group cursor-pointer"
          >
            <div class="flex items-baseline gap-1">
              <span
                class="text-lg font-bold text-base-content truncate max-w-[8rem] group-hover:text-primary transition-colors"
                title={@top_item.name}
              >
                {@top_item.name}
              </span>
              <span class="text-sm text-base-content/60">({@top_item.count})</span>
            </div>
            <div class="text-xs text-base-content/60">
              {@title}
              <span :if={@other_count > 0} class="text-base-content/40">
                · +{@item_count - 1} more
              </span>
            </div>
          </.link>
          <!-- Non-clickable top item (for "Unknown" values) -->
          <div :if={@top_item && @top_item_link == nil}>
            <div class="flex items-baseline gap-1">
              <span
                class="text-lg font-bold text-base-content truncate max-w-[8rem]"
                title={@top_item.name}
              >
                {@top_item.name}
              </span>
              <span class="text-sm text-base-content/60">({@top_item.count})</span>
            </div>
            <div class="text-xs text-base-content/60">
              {@title}
              <span :if={@other_count > 0} class="text-base-content/40">
                · +{@item_count - 1} more
              </span>
            </div>
          </div>
          <div :if={@top_item == nil} class="text-sm text-base-content/40">{@empty_text}</div>
        </div>
        <div :if={@items != []} class="dropdown dropdown-end">
          <div tabindex="0" role="button" class="btn btn-ghost btn-xs btn-circle">
            <.icon name="hero-chevron-down" class="size-3" />
          </div>
          <ul
            tabindex="0"
            class="dropdown-content z-50 menu p-2 shadow-lg bg-base-100 rounded-lg w-52 border border-base-200"
          >
            <%= for item <- Enum.take(@items, 10) do %>
              <li>
                <%= if item.name == "Unknown" do %>
                  <span class="flex justify-between text-sm text-base-content/50 cursor-not-allowed">
                    <span class="truncate">{item.name}</span>
                    <span class="badge badge-sm badge-ghost">{item.count}</span>
                  </span>
                <% else %>
                  <.link
                    navigate={"/devices?q=" <> URI.encode("in:devices #{@filter_field}:\"#{item.name}\"")}
                    class="flex justify-between text-sm"
                  >
                    <span class="truncate">{item.name}</span>
                    <span class="badge badge-sm badge-ghost">{item.count}</span>
                  </.link>
                <% end %>
              </li>
            <% end %>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  defp format_stat_number(n) when is_integer(n) and n >= 1000 do
    n |> Integer.to_string() |> add_stat_commas()
  end

  defp format_stat_number(n) when is_integer(n), do: Integer.to_string(n)
  defp format_stat_number(n) when is_float(n), do: n |> trunc() |> format_stat_number()
  defp format_stat_number(_), do: "0"

  defp add_stat_commas(str) do
    str
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  attr :available, :any, default: nil

  def availability_badge(assigns) do
    {label, variant} =
      case assigns.available do
        true -> {"Online", "success"}
        false -> {"Offline", "error"}
        _ -> {"Unknown", "ghost"}
      end

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  attr :type, :string, default: nil
  attr :type_id, :integer, default: nil

  def device_type_badge(assigns) do
    label = device_type_label(assigns.type, assigns.type_id)
    icon = device_type_icon(assigns.type_id)

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:icon, icon)

    ~H"""
    <div class="flex items-center gap-1" title={"Type ID: #{@type_id}"}>
      <.icon :if={@icon} name={@icon} class="size-3.5 text-base-content/60" />
      <span class="text-base-content/80">{@label}</span>
    </div>
    """
  end

  defp device_type_label(type, _type_id) when is_binary(type) and type != "", do: type
  defp device_type_label(_type, 0), do: "Unknown"
  defp device_type_label(_type, 1), do: "Server"
  defp device_type_label(_type, 2), do: "Desktop"
  defp device_type_label(_type, 3), do: "Laptop"
  defp device_type_label(_type, 4), do: "Tablet"
  defp device_type_label(_type, 5), do: "Mobile"
  defp device_type_label(_type, 6), do: "Virtual"
  defp device_type_label(_type, 7), do: "IOT"
  defp device_type_label(_type, 8), do: "Browser"
  defp device_type_label(_type, 9), do: "Firewall"
  defp device_type_label(_type, 10), do: "Switch"
  defp device_type_label(_type, 11), do: "Hub"
  defp device_type_label(_type, 12), do: "Router"
  defp device_type_label(_type, 13), do: "IDS"
  defp device_type_label(_type, 14), do: "IPS"
  defp device_type_label(_type, 15), do: "Load Balancer"
  defp device_type_label(_type, 99), do: "Other"
  defp device_type_label(_type, _type_id), do: "—"

  defp device_type_icon(1), do: "hero-server"
  defp device_type_icon(2), do: "hero-computer-desktop"
  defp device_type_icon(3), do: "hero-computer-desktop"
  defp device_type_icon(4), do: "hero-device-tablet"
  defp device_type_icon(5), do: "hero-device-phone-mobile"
  defp device_type_icon(6), do: "hero-cube"
  defp device_type_icon(7), do: "hero-cpu-chip"
  defp device_type_icon(9), do: "hero-shield-check"
  defp device_type_icon(10), do: "hero-square-3-stack-3d"
  defp device_type_icon(12), do: "hero-arrows-right-left"
  defp device_type_icon(15), do: "hero-scale"
  defp device_type_icon(_), do: nil

  attr :risk_level, :string, default: nil

  def risk_level_badge(assigns) do
    {label, variant} = risk_level_style(assigns.risk_level)

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:variant, variant)

    ~H"""
    <.ui_badge :if={@label != "—"} variant={@variant} size="xs">{@label}</.ui_badge>
    <span :if={@label == "—"} class="text-base-content/40">—</span>
    """
  end

  defp risk_level_style("Critical"), do: {"Critical", "error"}
  defp risk_level_style("High"), do: {"High", "warning"}
  defp risk_level_style("Medium"), do: {"Medium", "info"}
  defp risk_level_style("Low"), do: {"Low", "success"}
  defp risk_level_style("Info"), do: {"Info", "ghost"}
  defp risk_level_style(_), do: {"—", "ghost"}

  attr :spark, :map, required: true

  def icmp_sparkline(assigns) do
    points = Map.get(assigns.spark, :points, [])
    {stroke_path, area_path} = sparkline_smooth_paths(points)

    assigns =
      assigns
      |> assign(:points, points)
      |> assign(:latest_ms, Map.get(assigns.spark, :latest_ms, 0.0))
      |> assign(:tone, Map.get(assigns.spark, :tone, "success"))
      |> assign(:title, Map.get(assigns.spark, :title))
      |> assign(:stroke_path, stroke_path)
      |> assign(:area_path, area_path)
      |> assign(:stroke_color, tone_stroke(Map.get(assigns.spark, :tone, "success")))
      |> assign(:spark_id, "spark-#{:erlang.phash2(Map.get(assigns.spark, :title, ""))}")

    ~H"""
    <div class="flex items-center gap-2">
      <div class="h-8 w-20 rounded-md bg-base-200/30 px-1 py-0.5 overflow-hidden">
        <svg viewBox="0 0 400 120" class="w-full h-full" preserveAspectRatio="none">
          <title>{@title || "ICMP latency"}</title>
          <defs>
            <linearGradient id={@spark_id} x1="0" y1="0" x2="0" y2="1">
              <stop offset="5%" stop-color={@stroke_color} stop-opacity="0.5" />
              <stop offset="95%" stop-color={@stroke_color} stop-opacity="0.05" />
            </linearGradient>
          </defs>
          <path d={@area_path} fill={"url(##{@spark_id})"} />
          <path
            d={@stroke_path}
            fill="none"
            stroke={@stroke_color}
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
        </svg>
      </div>
      <div class="tabular-nums text-[11px] font-bold text-base-content">
        {format_ms(@latest_ms)}
      </div>
    </div>
    """
  end

  attr :device_uid, :string, default: nil
  attr :has_snmp, :boolean, default: false
  attr :has_sysmon, :boolean, default: false

  def metrics_presence(assigns) do
    device_path =
      if is_binary(assigns.device_uid) and String.trim(assigns.device_uid) != "" do
        ~p"/devices/#{assigns.device_uid}"
      else
        nil
      end

    assigns = assign(assigns, :device_path, device_path)

    ~H"""
    <div :if={@has_snmp or @has_sysmon} class="flex items-center gap-2">
      <.link
        :if={@has_snmp and is_binary(@device_path)}
        navigate={@device_path}
        class="tooltip inline-flex hover:opacity-90"
        data-tip="SNMP metrics available (last 24h)"
        aria-label="View device details (SNMP metrics available)"
      >
        <.icon name="hero-signal" class="size-4 text-info" />
      </.link>
      <span
        :if={@has_snmp and not is_binary(@device_path)}
        class="tooltip"
        data-tip="SNMP metrics available (last 24h)"
      >
        <.icon name="hero-signal" class="size-4 text-info" />
      </span>

      <.link
        :if={@has_sysmon and is_binary(@device_path)}
        navigate={@device_path}
        class="tooltip inline-flex hover:opacity-90"
        data-tip="Host Health metrics available (last 24h)"
        aria-label="View device details (Host Health metrics available)"
      >
        <.icon name="hero-cpu-chip" class="size-4 text-success" />
      </.link>
      <span
        :if={@has_sysmon and not is_binary(@device_path)}
        class="tooltip"
        data-tip="Host Health metrics available (last 24h)"
      >
        <.icon name="hero-cpu-chip" class="size-4 text-success" />
      </span>
    </div>
    <span :if={not @has_snmp and not @has_sysmon} class="text-base-content/40">—</span>
    """
  end

  attr :profile, :any, default: nil

  def sysmon_profile_badge(assigns) do
    profile_name = sysmon_profile_label(assigns.profile)

    {label, source} =
      if is_binary(profile_name) do
        {profile_name, :direct}
      else
        {"Unassigned", :missing}
      end

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:source, source)

    ~H"""
    <div class="flex items-center gap-1">
      <span
        data-testid="sysmon-profile-label"
        class={[
          "text-xs truncate max-w-[8rem]",
          if(@source == :direct, do: "font-medium text-base-content", else: "text-base-content/60")
        ]}
      >
        {@label}
      </span>
    </div>
    """
  end

  defp sysmon_profile_label(profile) when is_map(profile) do
    with name when is_binary(name) <- Map.get(profile, :name) || Map.get(profile, "name"),
         trimmed_name = String.trim(name),
         true <- trimmed_name != "" do
      trimmed_name
    else
      _ -> nil
    end
  end

  defp sysmon_profile_label(_), do: nil

  defp tone_stroke("error"), do: "#ff5555"
  defp tone_stroke("warning"), do: "#ffb86c"
  defp tone_stroke("success"), do: "#50fa7b"
  defp tone_stroke(_), do: "#6272a4"

  defp format_ms(value) when is_float(value) do
    :erlang.float_to_binary(value, decimals: 1) <> "ms"
  end

  defp format_ms(value) when is_integer(value), do: Integer.to_string(value) <> "ms"
  defp format_ms(_), do: "—"

  # Generate smooth SVG paths using monotone cubic interpolation (Catmull-Rom spline)
  defp sparkline_smooth_paths(values) when is_list(values) do
    values = Enum.filter(values, &is_number/1)

    case {values, Enum.min(values, fn -> 0 end), Enum.max(values, fn -> 0 end)} do
      {[], _, _} ->
        {"", ""}

      {[_single], _, _} ->
        # Single point - just draw a small line
        {"M 200,60 L 200,60", ""}

      {_values, min_v, max_v} ->
        # Normalize values to coordinates
        range = if max_v == min_v, do: 1.0, else: max_v - min_v
        len = length(values)

        coords =
          Enum.with_index(values)
          |> Enum.map(fn {v, idx} ->
            x = idx_to_x(idx, len)
            y = 110.0 - (v - min_v) / range * 100.0
            {x * 1.0, y}
          end)

        stroke_path = monotone_curve_path(coords)
        area_path = monotone_area_path(coords)
        {stroke_path, area_path}
    end
  end

  defp sparkline_smooth_paths(_), do: {"", ""}

  # Monotone cubic interpolation for smooth curves that don't overshoot
  defp monotone_curve_path([]), do: ""
  defp monotone_curve_path([{x, y}]), do: "M #{fmt(x)},#{fmt(y)}"

  defp monotone_curve_path(coords) do
    [{x0, y0} | _rest] = coords
    tangents = compute_tangents(coords)

    # Start with first point
    segments = ["M #{fmt(x0)},#{fmt(y0)}"]

    # Build cubic bezier segments
    curve_segments =
      Enum.zip([coords, tl(coords), tangents, tl(tangents)])
      |> Enum.map(fn {{x0, y0}, {x1, y1}, t0, t1} ->
        dx = (x1 - x0) / 3.0
        cp1x = x0 + dx
        cp1y = y0 + t0 * dx
        cp2x = x1 - dx
        cp2y = y1 - t1 * dx
        "C #{fmt(cp1x)},#{fmt(cp1y)} #{fmt(cp2x)},#{fmt(cp2y)} #{fmt(x1)},#{fmt(y1)}"
      end)

    Enum.join(segments ++ curve_segments, " ")
  end

  defp monotone_area_path([]), do: ""
  defp monotone_area_path([_]), do: ""

  defp monotone_area_path(coords) do
    [{first_x, _} | _] = coords
    {last_x, _} = List.last(coords)
    baseline = 115.0

    stroke = monotone_curve_path(coords)
    "#{stroke} L #{fmt(last_x)},#{fmt(baseline)} L #{fmt(first_x)},#{fmt(baseline)} Z"
  end

  # Compute tangents for monotone interpolation
  defp compute_tangents(coords) when length(coords) < 2, do: []

  defp compute_tangents(coords) do
    # Compute slopes between consecutive points
    slopes =
      Enum.zip(coords, tl(coords))
      |> Enum.map(fn {{x0, y0}, {x1, y1}} ->
        dx = x1 - x0
        if dx == 0, do: 0.0, else: (y1 - y0) / dx
      end)

    # Compute tangents using monotone method
    n = length(coords)

    Enum.map(0..(n - 1), fn i ->
      tangent_for_index(i, n, slopes)
    end)
  end

  defp tangent_for_index(0, _n, slopes), do: Enum.at(slopes, 0) || 0.0
  defp tangent_for_index(i, n, slopes) when i == n - 1, do: List.last(slopes) || 0.0

  defp tangent_for_index(i, _n, slopes) do
    s0 = Enum.at(slopes, i - 1) || 0.0
    s1 = Enum.at(slopes, i) || 0.0

    if s0 * s1 <= 0 do
      0.0
    else
      2.0 * s0 * s1 / (s0 + s1)
    end
  end

  defp fmt(num) when is_float(num), do: :erlang.float_to_binary(num, decimals: 1)
  defp fmt(num) when is_integer(num), do: Integer.to_string(num)

  defp idx_to_x(_idx, 0), do: 0
  defp idx_to_x(0, _len), do: 0

  defp idx_to_x(idx, len) when len > 1 do
    round(idx / (len - 1) * 400)
  end

  defp load_icmp_sparklines(srql_module, devices, scope) do
    device_uids =
      devices
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn row -> Map.get(row, "uid") || Map.get(row, "id") end)
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.take(@sparkline_device_cap)

    if device_uids == [] do
      {%{}, nil}
    else
      query =
        [
          "in:timeseries_metrics",
          "metric_type:icmp",
          "uid:(#{Enum.map_join(device_uids, ",", &escape_list_value/1)})",
          "time:#{@sparkline_window}",
          "bucket:#{@sparkline_bucket}",
          "agg:avg",
          "series:uid",
          "limit:#{min(length(device_uids) * @sparkline_points_per_device, 4000)}"
        ]
        |> Enum.join(" ")

      case srql_module.query(query, %{scope: scope}) do
        {:ok, %{"results" => rows}} when is_list(rows) ->
          {build_icmp_sparklines(rows), nil}

        {:ok, other} ->
          {%{}, "unexpected SRQL response: #{inspect(other)}"}

        {:error, reason} ->
          {%{}, format_error(reason)}
      end
    end
  end

  defp escape_list_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> then(&"\"#{&1}\"")
  end

  defp load_metric_presence(srql_module, devices, scope) do
    device_uids =
      devices
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn row -> Map.get(row, "uid") || Map.get(row, "id") end)
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.take(@presence_device_cap)

    if device_uids == [] do
      {%{}, %{}}
    else
      list = Enum.map_join(device_uids, ",", &escape_list_value/1)
      limit = min(length(device_uids) * 3, 2000)

      snmp_query =
        [
          "in:snmp_metrics",
          "uid:(#{list})",
          "time:#{@presence_window}",
          "bucket:#{@presence_bucket}",
          "agg:count",
          "series:uid",
          "limit:#{limit}"
        ]
        |> Enum.join(" ")

      sysmon_query =
        [
          "in:cpu_metrics",
          "uid:(#{list})",
          "time:#{@presence_window}",
          "bucket:#{@presence_bucket}",
          "agg:count",
          "series:uid",
          "limit:#{limit}"
        ]
        |> Enum.join(" ")

      {snmp_presence, sysmon_presence} =
        [snmp: snmp_query, sysmon: sysmon_query]
        |> Task.async_stream(
          fn {key, query} -> {key, srql_module.query(query, %{scope: scope})} end,
          ordered: false,
          timeout: 30_000
        )
        |> Enum.reduce({%{}, %{}}, fn
          {:ok, {:snmp, {:ok, %{"results" => rows}}}}, {_snmp, sysmon} ->
            {presence_from_downsample(rows), sysmon}

          {:ok, {:sysmon, {:ok, %{"results" => rows}}}}, {snmp, _sysmon} ->
            {snmp, presence_from_downsample(rows)}

          _, acc ->
            acc
        end)

      {snmp_presence, sysmon_presence}
    end
  end

  defp presence_from_downsample(rows) when is_list(rows) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(%{}, fn row, acc ->
      series = Map.get(row, "series")
      value = Map.get(row, "value")

      if is_binary(series) and series != "" and is_number(value) and value > 0 do
        Map.put(acc, series, true)
      else
        acc
      end
    end)
  end

  defp presence_from_downsample(_), do: %{}

  defp build_icmp_sparklines(rows) when is_list(rows) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(%{}, &accumulate_icmp_point/2)
    |> Map.new(fn {device_uid, points} ->
      {device_uid, icmp_sparkline_data(points)}
    end)
  end

  defp build_icmp_sparklines(_), do: %{}

  defp accumulate_icmp_point(row, acc) do
    device_uid = Map.get(row, "series") || Map.get(row, "uid") || Map.get(row, "device_id")
    timestamp = Map.get(row, "timestamp")
    value_ms = latency_ms(Map.get(row, "value"))

    if is_binary(device_uid) and value_ms > 0 do
      Map.update(
        acc,
        device_uid,
        [%{ts: timestamp, v: value_ms}],
        fn existing -> existing ++ [%{ts: timestamp, v: value_ms}] end
      )
    else
      acc
    end
  end

  defp icmp_sparkline_data(points) do
    points =
      points
      |> Enum.sort_by(fn p -> p.ts end)
      |> Enum.take(-@sparkline_points_per_device)

    values = Enum.map(points, & &1.v)
    latest_ms = List.last(values) || 0.0
    tone = icmp_tone(latest_ms)
    title = icmp_title(points, latest_ms)

    %{points: values, latest_ms: latest_ms, tone: tone, title: title}
  end

  defp icmp_tone(latest_ms) do
    cond do
      latest_ms >= @sparkline_threshold_ms -> "warning"
      latest_ms > 0 -> "success"
      true -> "ghost"
    end
  end

  defp icmp_title(points, latest_ms) do
    case List.last(points) do
      %{ts: ts} when is_binary(ts) -> "ICMP #{format_ms(latest_ms)} · #{ts}"
      _ -> "ICMP #{format_ms(latest_ms)}"
    end
  end

  defp latency_ms(value) when is_float(value) or is_integer(value) do
    raw = if is_integer(value), do: value * 1.0, else: value
    if raw > 1_000_000.0, do: raw / 1_000_000.0, else: raw
  end

  defp latency_ms(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> latency_ms(parsed)
      _ -> 0.0
    end
  end

  defp latency_ms(_), do: 0.0

  defp agent_device_row?(row) when is_map(row) do
    agent_id = Map.get(row, "agent_id")
    sources = Map.get(row, "discovery_sources") || []
    agent_list = Map.get(row, "agent_list") || []

    (is_binary(agent_id) and agent_id != "") or
      (is_list(agent_list) and agent_list != []) or
      Enum.any?(sources, &(&1 == "agent"))
  end

  defp agent_device_row?(_), do: false

  defp format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  defp format_error(%ArgumentError{} = err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  # Load device stats for cards using SRQL GROUP BY queries
  defp load_device_stats(srql_module, scope) do
    queries = %{
      total: ~s|in:devices stats:"count() as total"|,
      available: ~s|in:devices is_available:true stats:"count() as count"|,
      unavailable: ~s|in:devices is_available:false stats:"count() as count"|,
      by_type: ~s|in:devices stats:count() as count by type|,
      by_vendor: ~s|in:devices stats:count() as count by vendor_name|,
      by_risk_level: ~s|in:devices stats:count() as count by risk_level|
    }

    results =
      queries
      |> Task.async_stream(
        fn {key, query} -> {key, srql_module.query(query, %{scope: scope})} end,
        ordered: false,
        timeout: 10_000
      )
      |> Enum.reduce(%{}, fn
        {:ok, {key, {:ok, result}}}, acc ->
          Map.put(acc, key, result)

        {:ok, {key, {:error, reason}}}, acc ->
          Logger.warning("Device stats query #{key} failed: #{inspect(reason)}")
          acc

        {:exit, reason}, acc ->
          Logger.warning("Device stats query task exited: #{inspect(reason)}")
          acc

        other, acc ->
          Logger.debug("Device stats unexpected result: #{inspect(other)}")
          acc
      end)

    Logger.debug("Device stats raw results: #{inspect(results, limit: 500)}")

    stats = %{
      total: extract_stats_count(results[:total], "total"),
      available: extract_stats_count(results[:available], "count"),
      unavailable: extract_stats_count(results[:unavailable], "count"),
      by_type: extract_grouped_stats(results[:by_type], "type"),
      by_vendor: extract_grouped_stats(results[:by_vendor], "vendor_name"),
      by_risk_level: extract_grouped_stats(results[:by_risk_level], "risk_level")
    }

    Logger.debug("Device stats parsed: #{inspect(stats)}")
    stats
  rescue
    e ->
      Logger.error("Device stats loading failed: #{inspect(e)}")

      %{
        total: 0,
        available: 0,
        unavailable: 0,
        by_type: [],
        by_vendor: [],
        by_risk_level: []
      }
  end

  # Handle map result (multiple columns): {"results": [{"total": 123}]}
  defp extract_stats_count(%{"results" => [row | _]}, field) when is_map(row) do
    value = Map.get(row, field) || Map.get(row, "count") || Map.get(row, "total")
    to_stats_int(value)
  end

  # Handle single value result (single column): {"results": [123]}
  defp extract_stats_count(%{"results" => [value | _]}, _field) when not is_map(value) do
    to_stats_int(value)
  end

  # Handle payload column (grouped stats): {"results": [%{"payload" => %{...}}]}
  defp extract_stats_count(%{"results" => [%{"payload" => payload} | _]}, field)
       when is_map(payload) do
    value = Map.get(payload, field) || Map.get(payload, "count") || Map.get(payload, "total")
    to_stats_int(value)
  end

  defp extract_stats_count(%{"results" => []}, _field), do: 0
  defp extract_stats_count(nil, _field), do: 0

  defp extract_stats_count(result, field) do
    Logger.warning("Unexpected stats count result format: #{inspect(result)}, field: #{field}")
    0
  end

  defp to_stats_int(nil), do: 0
  defp to_stats_int(value) when is_integer(value), do: value
  defp to_stats_int(value) when is_float(value), do: trunc(value)
  defp to_stats_int(%Decimal{} = value), do: Decimal.to_integer(value)

  defp to_stats_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> parsed
      :error -> 0
    end
  end

  defp to_stats_int(_), do: 0

  defp extract_grouped_stats(%{"results" => results}, field) when is_list(results) do
    Logger.debug(
      "Extracting grouped stats for field '#{field}' from #{inspect(results, limit: 200)}"
    )

    extract_grouped_stats_list(results, field)
  end

  defp extract_grouped_stats(nil, _field), do: []

  defp extract_grouped_stats(result, field) do
    Logger.warning("Unexpected grouped stats result format: #{inspect(result)}, field: #{field}")
    []
  end

  defp extract_grouped_stats_list(results, field) do
    items =
      results
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn row ->
        # Handle both direct field and nested payload
        data = Map.get(row, "payload", row)

        %{
          name: to_string(Map.get(data, field) || "Unknown"),
          count: to_stats_int(Map.get(data, "count") || 0)
        }
      end)
      |> Enum.filter(fn %{count: count} -> count > 0 end)

    # Separate known values from "Unknown" - show known types first
    {known, unknown} = Enum.split_with(items, fn %{name: name} -> name != "Unknown" end)

    known_sorted = Enum.sort_by(known, fn %{count: count} -> -count end)
    unknown_sorted = Enum.sort_by(unknown, fn %{count: count} -> -count end)

    (known_sorted ++ unknown_sorted)
    |> Enum.take(10)
  end

  defp get_total_matching_count(scope, query) do
    srql_module = srql_module()
    query = to_string(query || "") |> String.trim()

    full_query =
      if query == "" do
        ~s|in:devices stats:"count() as total"|
      else
        ~s|in:devices #{query} stats:"count() as total"|
      end

    case srql_module.query(full_query, %{scope: scope}) do
      {:ok, %{"results" => [%{"total" => count} | _]}} when is_integer(count) ->
        count

      _ ->
        nil
    end
  end

  defp parse_page_param(params) do
    case params["page"] do
      nil ->
        1

      "" ->
        1

      page when is_binary(page) ->
        case Integer.parse(page) do
          {n, _} when n > 0 -> n
          _ -> 1
        end

      page when is_integer(page) and page > 0 ->
        page

      _ ->
        1
    end
  end

  defp get_all_matching_uids(scope, query) do
    srql_module = srql_module()
    fetch_all_uids_paginated(srql_module, scope, query, nil, [])
  end

  defp fetch_all_uids_paginated(srql_module, scope, query, cursor, acc) do
    full_query = "in:devices #{query} limit:1000"
    opts = if cursor, do: %{scope: scope, cursor: cursor}, else: %{scope: scope}

    case srql_module.query(full_query, opts) do
      {:ok, %{"results" => results, "pagination" => pagination}} when is_list(results) ->
        uids =
          results
          |> Enum.filter(&is_map/1)
          |> Enum.map(fn row -> Map.get(row, "uid") || Map.get(row, "id") end)
          |> Enum.filter(&is_binary/1)

        next_cursor = Map.get(pagination, "next_cursor")
        new_acc = [uids | acc]

        if is_binary(next_cursor) do
          fetch_all_uids_paginated(srql_module, scope, query, next_cursor, new_acc)
        else
          finalize_uid_acc(new_acc)
        end

      {:ok, %{"results" => results}} when is_list(results) ->
        uids =
          results
          |> Enum.filter(&is_map/1)
          |> Enum.map(fn row -> Map.get(row, "uid") || Map.get(row, "id") end)
          |> Enum.filter(&is_binary/1)

        finalize_uid_acc([uids | acc])

      _ ->
        finalize_uid_acc(acc)
    end
  end

  defp finalize_uid_acc(acc) do
    acc
    |> Enum.reverse()
    |> List.flatten()
    |> Enum.uniq()
  end

  defp format_changeset_errors(changeset) do
    case changeset do
      %Ash.Changeset{errors: errors} when is_list(errors) and errors != [] ->
        Enum.map_join(errors, ", ", &format_single_error/1)

      %Ecto.Changeset{errors: errors} when is_list(errors) and errors != [] ->
        Enum.map_join(errors, ", ", fn {field, {msg, _opts}} -> "#{field}: #{msg}" end)

      _ ->
        "Unknown error"
    end
  end

  defp format_single_error(%Ash.Error.Changes.InvalidAttribute{field: field, message: msg}),
    do: "#{field}: #{msg}"

  defp format_single_error(%Ash.Error.Changes.Required{field: field}),
    do: "#{field} is required"

  defp format_single_error(%{message: msg}) when is_binary(msg),
    do: msg

  defp format_single_error(err),
    do: inspect(err)

  # Filter helpers for quick filter buttons
  defp has_filter?(srql, field, value) do
    query = Map.get(srql || %{}, :query, "") || ""
    String.contains?(query, "#{field}:#{value}")
  end

  defp has_any_filter?(srql) do
    query = Map.get(srql || %{}, :query, "") || ""
    String.trim(query) != ""
  end

  defp toggle_include_deleted_query(query) when is_binary(query) do
    case SRQLBuilder.parse(query) do
      {:ok, builder} ->
        filters = Map.get(builder, "filters", [])
        {updated_filters, _enabled} = toggle_builder_filter(filters, "include_deleted")

        builder
        |> Map.put("filters", updated_filters)
        |> SRQLBuilder.build()

      _ ->
        fallback_toggle_include_deleted_query(query)
    end
  end

  defp toggle_include_deleted_query(_), do: "in:devices include_deleted:true"

  defp toggle_builder_filter(filters, field) do
    {matches, rest} = Enum.split_with(filters, fn filter -> Map.get(filter, "field") == field end)

    if matches == [] do
      {rest ++ [%{"field" => field, "op" => "equals", "value" => "true"}], true}
    else
      {rest, false}
    end
  end

  defp fallback_toggle_include_deleted_query(query) do
    if String.contains?(query, "include_deleted:true") do
      query
      |> String.replace(~r/\s*include_deleted:true\b/, "")
      |> String.trim()
    else
      query
      |> String.trim()
      |> case do
        "" -> "in:devices include_deleted:true"
        trimmed -> "#{trimmed} include_deleted:true"
      end
    end
  end

  defp device_list_path(query, limit) do
    params =
      %{"limit" => limit}
      |> maybe_put_param("q", query)

    ~p"/devices?#{params}"
  end

  defp maybe_put_param(params, _key, value) when value in [nil, ""], do: params
  defp maybe_put_param(params, key, value), do: Map.put(params, key, value)

  defp deleted_device_row?(row) when is_map(row) do
    value = Map.get(row, "deleted_at")
    not is_nil(value) and value != ""
  end

  defp deleted_device_row?(_), do: false

  # Sysmon profile helpers
  # Note: Profile-per-device tracking removed - profiles now target devices via SRQL queries.
  # This function returns an empty map for profiles_by_device.
  defp load_sysmon_profiles_for_devices(_scope, _devices) do
    %{}
  rescue
    _ -> %{}
  end

  # CSV Import helpers
  defp parse_csv_file(path) do
    try do
      content = File.read!(path)
      lines = String.split(content, ~r/\r?\n/, trim: true)

      case lines do
        [] ->
          {:error, ["CSV file is empty"]}

        [header | data_lines] ->
          headers = parse_csv_line(header)
          required = ["hostname", "ip"]
          missing = required -- Enum.map(headers, &String.downcase/1)

          if missing != [] do
            {:error, ["Missing required columns: #{Enum.join(missing, ", ")}"]}
          else
            header_map = headers |> Enum.with_index() |> Map.new()
            devices = Enum.map(data_lines, &parse_device_row(&1, header_map))
            valid_devices = Enum.filter(devices, &(&1 != nil))

            if valid_devices == [] do
              {:error, ["No valid device rows found in CSV"]}
            else
              {:ok, valid_devices}
            end
          end
      end
    rescue
      e ->
        {:error, ["Failed to parse CSV: #{inspect(e)}"]}
    end
  end

  defp parse_csv_line(line) do
    # Simple CSV parsing - handles basic quoted fields
    line
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.trim(&1, "\""))
  end

  defp parse_device_row(line, header_map) do
    values = parse_csv_line(line)

    hostname = get_csv_value(values, header_map, "hostname")
    ip = get_csv_value(values, header_map, "ip")

    if hostname && hostname != "" && ip && ip != "" do
      %{
        hostname: hostname,
        ip: ip,
        type: get_csv_value(values, header_map, "type") || "",
        tags: parse_tags(get_csv_value(values, header_map, "tags"))
      }
    else
      nil
    end
  end

  defp get_csv_value(values, header_map, column) do
    # Try both lowercase and original case
    index =
      Map.get(header_map, column) ||
        Map.get(header_map, String.capitalize(column)) ||
        Map.get(header_map, String.upcase(column))

    if index, do: Enum.at(values, index), else: nil
  end

  defp parse_tags(nil), do: []
  defp parse_tags(""), do: []

  defp parse_tags(tags_string) do
    # Tags can be pipe-separated (env=prod|team=ops)
    tags_string
    |> String.split("|")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # Device creation helpers

  defp import_success_message(created, skipped) when skipped > 0 and created > 0 do
    "Created #{created} device(s). #{skipped} device(s) skipped (already exist)."
  end

  defp import_success_message(_created, skipped) when skipped > 0 do
    "All #{skipped} device(s) already exist."
  end

  defp import_success_message(created, _skipped) do
    "Created #{created} device(s) successfully."
  end

  defp import_devices(scope, devices) do
    do_import_devices(devices, scope)
  end

  defp do_import_devices(devices, scope) do
    {created, skipped, errors} =
      Enum.reduce(devices, {0, 0, []}, fn device_data, acc ->
        process_device_import(device_data, scope, acc)
      end)

    if errors == [], do: {:ok, {created, skipped}}, else: {:error, Enum.reverse(errors)}
  end

  defp process_device_import(device_data, scope, {created, skipped, errors}) do
    case create_single_device(device_data, scope) do
      {:ok, _device} ->
        {created + 1, skipped, errors}

      {:error, :already_exists} ->
        {created, skipped + 1, errors}

      {:error, reason} ->
        error_msg = "Row #{created + skipped + 1}: #{format_create_error(reason)}"
        {created, skipped, [error_msg | errors]}
    end
  end

  defp create_device(scope, params) do
    if is_nil(scope) do
      {:error, :missing_scope}
    else
      # Build device data from form params
      device_data = %{
        hostname: params["hostname"],
        ip: params["ip"],
        type: params["type"],
        tags: parse_form_tags(params["tags"])
      }

      create_single_device(device_data, scope)
    end
  end

  defp create_single_device(device_data, scope) do
    # Generate a UID based on IP (or use a UUID)
    uid = generate_device_uid(device_data.ip)

    if is_nil(uid) or uid == "" do
      Logger.error("Device create failed: generated UID is empty for #{inspect(device_data)}")
      {:error, :invalid_uid}
    else
      create_new_device(uid, device_data, scope)
      |> normalize_create_result()
    end
  end

  defp normalize_create_result({:ok, device}), do: {:ok, device}

  defp normalize_create_result({:error, %Ash.Error.Invalid{} = error}) do
    if unique_uid_error?(error) do
      {:error, :already_exists}
    else
      {:error, error}
    end
  end

  defp normalize_create_result({:error, error}), do: {:error, error}

  defp create_new_device(uid, device_data, scope) do
    # Device doesn't exist, create it
    now = DateTime.utc_now()

    attrs =
      %{
        uid: uid,
        hostname: device_data.hostname,
        ip: device_data.ip,
        name: device_data.hostname || device_data.ip,
        type: device_data[:type],
        type_id: parse_type_id(device_data[:type]),
        tags: normalize_tags(device_data[:tags]),
        discovery_sources: ["manual"],
        first_seen_time: now,
        last_seen_time: now,
        created_time: now
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new()

    Device
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(scope: scope)
  end

  defp generate_device_uid(ip) when is_binary(ip) do
    # Generate a deterministic UID based on IP
    # This allows for upsert behavior on re-import
    :crypto.hash(:sha256, "manual:#{ip}")
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end

  defp generate_device_uid(_), do: Ash.UUID.generate()

  defp parse_type_id(nil), do: 0
  defp parse_type_id(""), do: 0
  defp parse_type_id("server"), do: 1
  defp parse_type_id("Server"), do: 1
  defp parse_type_id("desktop"), do: 2
  defp parse_type_id("Desktop"), do: 2
  defp parse_type_id("laptop"), do: 3
  defp parse_type_id("Laptop"), do: 3
  defp parse_type_id("switch"), do: 10
  defp parse_type_id("Switch"), do: 10
  defp parse_type_id("router"), do: 12
  defp parse_type_id("Router"), do: 12
  defp parse_type_id("firewall"), do: 9
  defp parse_type_id("Firewall"), do: 9
  defp parse_type_id(_), do: 0

  defp normalize_tags(nil), do: %{}
  defp normalize_tags(tags) when is_map(tags), do: tags

  defp normalize_tags(tags) when is_list(tags) do
    Enum.reduce(tags, %{}, fn tag, acc ->
      case String.split(tag, "=", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
        [key] -> Map.put(acc, String.trim(key), nil)
      end
    end)
  end

  defp normalize_tags(_), do: %{}

  defp parse_form_tags(nil), do: []
  defp parse_form_tags(""), do: []

  defp parse_form_tags(tags_string) when is_binary(tags_string) do
    tags_string
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp format_device_error(%Ash.Error.Invalid{errors: errors}) do
    Enum.map_join(errors, ", ", &format_single_device_error/1)
  end

  defp format_device_error(error), do: inspect(error)

  defp format_create_error(%Ash.Error.Invalid{errors: errors}) do
    Enum.map_join(errors, ", ", &format_single_device_error/1)
  end

  defp format_create_error(error), do: inspect(error)

  defp format_single_device_error(%Ash.Error.Changes.InvalidAttribute{
         field: field,
         message: msg
       }),
       do: "#{field}: #{msg}"

  defp format_single_device_error(%Ash.Error.Changes.Required{field: field}),
    do: "#{field} is required"

  defp format_single_device_error(%Ash.Error.Query.NotFound{}),
    do: "Device not found"

  defp format_single_device_error(%{message: msg}) when is_binary(msg),
    do: msg

  defp format_single_device_error(err),
    do: inspect(err)

  defp unique_uid_error?(%Ash.Error.Invalid{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &unique_uid_error_detail?/1)
  end

  defp unique_uid_error?(_), do: false

  defp unique_uid_error_detail?(%Ash.Error.Changes.InvalidAttribute{} = error) do
    field = Map.get(error, :field)
    validation = Map.get(error, :validation)
    message = Map.get(error, :message)

    field == :uid and
      (unique_validation?(validation) or
         (is_binary(message) and String.contains?(message, "has already been taken")))
  end

  defp unique_uid_error_detail?(%Ash.Error.Changes.InvalidChanges{} = error) do
    fields = Map.get(error, :fields, [])
    validation = Map.get(error, :validation)
    message = Map.get(error, :message)

    Enum.member?(List.wrap(fields), :uid) and
      (unique_validation?(validation) or
         (is_binary(message) and String.contains?(message, "has already been taken")))
  end

  defp unique_uid_error_detail?(_), do: false

  defp unique_validation?(:unique), do: true

  defp unique_validation?({Ash.Resource.Validation.Uniqueness, _opts}), do: true

  defp unique_validation?(_), do: false
end
