defmodule ServiceRadarWebNGWeb.DeviceLive.Index do
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage
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
     |> assign(:limit, @default_limit)
     # Bulk selection
     |> assign(:selected_devices, MapSet.new())
     |> assign(:select_all_matching, false)
     |> assign(:total_matching_count, nil)
     |> assign(:show_bulk_edit_modal, false)
     |> assign(:bulk_edit_form, to_form(%{"tags" => ""}, as: :bulk))
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

    {icmp_sparklines, icmp_error} =
      load_icmp_sparklines(srql_module(), socket.assigns.devices, scope)

    {snmp_presence, sysmon_presence} =
      load_metric_presence(srql_module(), socket.assigns.devices, scope)

    {:noreply,
     assign(socket,
       icmp_sparklines: icmp_sparklines,
       icmp_error: icmp_error,
       snmp_presence: snmp_presence,
       sysmon_presence: sysmon_presence
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

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "devices")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "devices")}
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

    {:noreply, assign(socket, :selected_devices, updated)}
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

    {:noreply, assign(socket, :selected_devices, updated)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected_devices, MapSet.new())}
  end

  def handle_event("open_bulk_edit_modal", _params, socket) do
    {:noreply, assign(socket, :show_bulk_edit_modal, true)}
  end

  def handle_event("close_bulk_edit_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_bulk_edit_modal, false)
     |> assign(:bulk_edit_form, to_form(%{"tags" => ""}, as: :bulk))}
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
    case get_selected_uids(socket) do
      [] ->
        {:error, "No devices selected"}

      uids ->
        update_tags_for_uids(scope, uids, tags)
    end
  end

  defp update_tags_for_uids(scope, uids, tags) do
    Enum.reduce_while(uids, {:ok, 0}, fn uid, {:ok, count} ->
      case update_device_tags(scope, uid, tags) do
        :ok -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp update_device_tags(scope, uid, tags) do
    case Ash.get(Device, uid, scope: scope) do
      {:ok, device} ->
        existing = Map.get(device, :tags) || %{}
        merged = Map.merge(existing, tags)

        device
        |> Ash.Changeset.for_update(:update, %{tags: merged}, scope: scope)
        |> Ash.update()
        |> case do
          {:ok, _} -> :ok
          {:error, error} -> {:error, format_changeset_errors(error)}
        end

      {:error, _} ->
        {:error, "Device #{uid} not found"}
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
        <!-- Quick Filters -->
        <div class="mb-4 flex flex-wrap items-center gap-2">
          <span class="text-xs font-medium text-base-content/60 mr-1">Quick filters:</span>
          <.link
            navigate={~p"/devices?q=is_available:true"}
            class={"btn btn-xs #{if has_filter?(@srql, "is_available", "true"), do: "btn-primary", else: "btn-ghost"}"}
          >
            <.icon name="hero-check-circle" class="size-3" /> Available
          </.link>
          <.link
            navigate={~p"/devices?q=is_available:false"}
            class={"btn btn-xs #{if has_filter?(@srql, "is_available", "false"), do: "btn-error", else: "btn-ghost"}"}
          >
            <.icon name="hero-x-circle" class="size-3" /> Unavailable
          </.link>
          <.link
            navigate={~p"/devices?q=discovery_sources:sweep"}
            class={"btn btn-xs #{if has_filter?(@srql, "discovery_sources", "sweep"), do: "btn-info", else: "btn-ghost"}"}
          >
            <.icon name="hero-signal" class="size-3" /> Swept
          </.link>
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
            <.ui_button variant="primary" size="sm" phx-click="open_bulk_edit_modal">
              <.icon name="hero-tag" class="size-4" /> Bulk Edit
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
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">UID</th>
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
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Gateway</th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Last Seen</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@devices == []}>
                  <td colspan="12" class="py-8 text-center text-sm text-base-content/60">
                    No devices found.
                  </td>
                </tr>

                <%= for row <- Enum.filter(@devices, &is_map/1) do %>
                  <% device_uid = Map.get(row, "uid") || Map.get(row, "id") %>
                  <% is_selected =
                    is_binary(device_uid) and MapSet.member?(@selected_devices, device_uid) %>
                  <% icmp =
                    if is_binary(device_uid), do: Map.get(@icmp_sparklines, device_uid), else: nil %>
                  <% has_snmp =
                    is_binary(device_uid) and Map.get(@snmp_presence, device_uid, false) == true %>
                  <% has_sysmon =
                    is_binary(device_uid) and Map.get(@sysmon_presence, device_uid, false) == true %>
                  <tr class={"hover:bg-base-200/40 #{if is_selected, do: "bg-primary/5", else: ""}"}>
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
                    <td class="font-mono text-xs">
                      <.link
                        :if={is_binary(device_uid)}
                        navigate={~p"/devices/#{device_uid}"}
                        class="link link-hover"
                      >
                        {device_uid}
                      </.link>
                      <span :if={not is_binary(device_uid)} class="text-base-content/70">—</span>
                    </td>
                    <td class="text-sm max-w-[18rem] truncate">{Map.get(row, "hostname") || "—"}</td>
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
                    <td class="font-mono text-xs">{Map.get(row, "gateway_id") || "—"}</td>
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
            />
          </div>
        </.ui_panel>
      </div>
      
    <!-- Bulk Edit Modal -->
      <.bulk_edit_modal
        :if={@show_bulk_edit_modal}
        form={@bulk_edit_form}
        selected_count={@effective_count}
      />
    </Layouts.app>
    """
  end

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
        data-tip="Sysmon metrics available (last 24h)"
        aria-label="View device details (Sysmon metrics available)"
      >
        <.icon name="hero-cpu-chip" class="size-4 text-success" />
      </.link>
      <span
        :if={@has_sysmon and not is_binary(@device_path)}
        class="tooltip"
        data-tip="Sysmon metrics available (last 24h)"
      >
        <.icon name="hero-cpu-chip" class="size-4 text-success" />
      </span>
    </div>
    <span :if={not @has_snmp and not @has_sysmon} class="text-base-content/40">—</span>
    """
  end

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

  defp format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  defp format_error(%ArgumentError{} = err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  defp get_total_matching_count(scope, query) do
    srql_module = srql_module()
    # Get count by querying with limit 0 - SRQL should return total_count
    full_query = "in:devices #{query} limit:0"

    case srql_module.query(full_query, %{scope: scope}) do
      {:ok, %{"pagination" => %{"total_count" => count}}} when is_integer(count) ->
        count

      {:ok, %{"results" => results}} when is_list(results) ->
        # Fall back to fetching actual count with larger limit
        count_query = "in:devices #{query} limit:10000"

        case srql_module.query(count_query, %{scope: scope}) do
          {:ok, %{"results" => results}} -> length(results)
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp get_all_matching_uids(scope, query) do
    srql_module = srql_module()
    full_query = "in:devices #{query} limit:10000"

    case srql_module.query(full_query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        results
        |> Enum.filter(&is_map/1)
        |> Enum.map(fn row -> Map.get(row, "uid") || Map.get(row, "id") end)
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()

      _ ->
        []
    end
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
end
