defmodule ServiceRadarWebNGWeb.DeviceLive.InterfaceComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.Helpers.InterfaceTypes

  # ---------------------------------------------------------------------------
  # Interfaces Tab Content (full interfaces list)
  # ---------------------------------------------------------------------------

  attr(:interfaces, :list, required: true)
  attr(:error, :string, default: nil)
  attr(:selected_interfaces, :any, required: true)
  attr(:favorited_interfaces, :any, required: true)
  attr(:device_uid, :string, required: true)
  attr(:interface_metrics, :map, default: nil)
  attr(:loading, :boolean, default: false)
  attr(:metrics_loading, :boolean, default: false)
  attr(:discovery_job, :any, default: nil)
  attr(:northbound_actions, :list, default: [])
  attr(:northbound_actions_loading, :boolean, default: false)
  attr(:can_launch_northbound, :boolean, default: false)

  def interfaces_tab_content(assigns) do
    selected_count = MapSet.size(assigns.selected_interfaces)

    run_task_disabled? =
      assigns.northbound_actions_loading or assigns.northbound_actions == [] or
        selected_count == 0

    run_task_title =
      cond do
        assigns.northbound_actions_loading ->
          "Checking configured task integrations"

        assigns.northbound_actions == [] ->
          "No launchable interface task integrations are configured"

        selected_count == 0 ->
          "Select at least one interface"

        true ->
          "Run task for selected interfaces"
      end

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
      |> assign(:run_task_disabled?, run_task_disabled?)
      |> assign(:run_task_title, run_task_title)

    ~H"""
    <div :if={@loading} class="rounded-xl border border-base-200 bg-base-100 p-8 text-center">
      <.ui_spinner size="md" />
      <p class="mt-3 text-sm font-semibold">Loading network interfaces</p>
      <p class="mt-1 text-xs text-base-content/60">
        You can keep using the rest of this device page.
      </p>
    </div>

    <div
      :if={!@loading && @metrics_loading}
      class="mb-4 rounded-xl border border-base-200 bg-base-100 p-5"
    >
      <div class="flex items-center gap-3 text-sm text-base-content/70">
        <.ui_spinner size="sm" />
        Loading favorited interface metrics&hellip;
      </div>
    </div>

    <%!-- Interface Metrics Visualization for Favorited Interfaces --%>
    <.interface_metrics_section
      :if={!@loading && @interface_metrics}
      metrics={@interface_metrics}
      device_uid={@device_uid}
    />

    <%= if !@loading && @interfaces == [] and is_nil(@error) do %>
      <div class="rounded-xl border border-base-200 bg-base-100 p-6 text-center">
        <.icon name="hero-arrows-right-left" class="size-8 text-base-content/30 mx-auto" />
        <p class="text-sm font-semibold text-base-content/80 mt-3">
          No interface data yet.
        </p>
        <p class="text-xs text-base-content/60 mt-1">
          Discovery is configured for this device, but no interface observations were returned.
        </p>
        <div :if={@discovery_job} class="mt-4 inline-flex flex-col gap-2 text-xs">
          <div class="flex flex-wrap items-center justify-center gap-2">
            <span class="font-medium">{@discovery_job.name}</span>
            <.ui_badge variant={mapper_run_status_variant(@discovery_job)} size="xs">
              {mapper_run_status_label(@discovery_job)}
            </.ui_badge>
          </div>
          <div class="text-base-content/60">
            Last run: {format_timestamp(Map.get(@discovery_job, :last_run_at))}
          </div>
          <div
            :if={is_integer(@discovery_job.last_run_interface_count)}
            class="text-base-content/60"
          >
            Interfaces observed: {@discovery_job.last_run_interface_count}
          </div>
          <div
            :if={is_binary(@discovery_job.last_run_error)}
            class="text-error"
            title={@discovery_job.last_run_error}
          >
            {@discovery_job.last_run_error}
          </div>
          <.link navigate={~p"/settings/networks/discovery/#{@discovery_job.id}/edit"}>
            <.ui_button variant="ghost" size="xs">View discovery job</.ui_button>
          </.link>
        </div>
      </div>
    <% else %>
      <div :if={!@loading} class="rounded-xl border border-base-200 bg-base-100">
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
              <.ui_button type="button" phx-click="clear_interface_selection" size="xs" variant="ghost">
                Clear
              </.ui_button>
              <.ui_button :if={@can_launch_northbound} type="button" phx-click="run_task_for_interface_selection" disabled={@run_task_disabled?} title={@run_task_title} size="xs" variant="primary">
                <.icon name="hero-play" class="size-3" />
                {if @northbound_actions_loading, do: "Checking jobs...", else: "Run Task"}
              </.ui_button>
              <.ui_button type="button" phx-click="open_interfaces_bulk_edit" size="xs" variant="outline">
                <.icon name="hero-pencil-square" class="size-3" /> Bulk Edit
              </.ui_button>
            </div>
          </div>
        </div>
        <div class="p-4">
          <div :if={is_binary(@error)} class="mb-3 flex items-center gap-2 text-xs text-error">
            <span>{@error}</span>
            <.ui_button type="button" phx-click="switch_tab" phx-value-tab="interfaces" size="xs" variant="outline">
              Retry
            </.ui_button>
          </div>
          <div class="sr-ui-table-shell">
            <table class={ui_table_class(size: "xs", class: "w-full")}>
              <thead class="sticky top-0 bg-base-100">
                <tr>
                  <th class="w-8">
                    <input
                      type="checkbox"
                      class={ui_checkbox_class(size: "xs")}
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
                        class={ui_checkbox_class(size: "xs")}
                        checked={is_selected}
                        phx-click="toggle_interface_select"
                        phx-value-uid={iface_uid}
                      />
                    </td>
                    <td class="w-8 text-center">
                      <.ui_button :if={iface_uid} type="button" phx-click="toggle_interface_favorite" phx-value-uid={iface_uid} title={if is_favorited, do: "Remove from favorites", else: "Add to favorites"} size="xs" variant="ghost" class="p-0">
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
                      </.ui_button>
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
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # Interface Metrics Section
  # ---------------------------------------------------------------------------

  attr(:metrics, :map, required: true)
  attr(:device_uid, :string, required: true)

  defp interface_metrics_section(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 mb-4">
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
        <div class={ui_alert_class("error")}>
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

      <%!-- Metrics panels: viewport-filling responsive grid (auto-fit) --%>
      <div
        :if={@metrics.panels != []}
        class="p-4 grid gap-4 grid-cols-[repeat(auto-fit,minmax(22rem,1fr))]"
      >
        <%= for {panel, idx} <- Enum.with_index(@metrics.panels) do %>
          <.live_component
            module={panel.plugin}
            id={"interface-metrics-#{@device_uid}-#{panel.id}-#{idx}"}
            title={Map.get(panel.assigns, :interface_label, "Interface Metrics")}
            panel_assigns={Map.put(panel.assigns, :compact, false)}
          />
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Interfaces Bulk Edit Modal
  # ---------------------------------------------------------------------------

  attr(:form, :any, required: true)
  attr(:selected_count, :integer, required: true)

  def interfaces_bulk_edit_modal(assigns) do
    ~H"""
    <.ui_modal id="interfaces_bulk_edit_modal" size="sm" on_cancel="close_interfaces_bulk_edit">
      <:title>Bulk Edit Interfaces</:title>

      <p class="text-sm text-sr-muted">
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
            <label class="flex cursor-pointer items-center gap-3 rounded-lg border border-sr-line p-3 hover:bg-sr-subtle/70">
              <input
                type="radio"
                name="bulk[action]"
                value="favorite"
                class="radio radio-primary radio-sm"
                checked
              />
              <div>
                <div class="flex items-center gap-2">
                  <.icon name="hero-star-solid" class="size-4 text-amber-500" />
                  <span class="font-medium text-sr-ink">Add to Favorites</span>
                </div>
                <p class="mt-1 text-xs text-sr-muted">
                  Mark selected interfaces as favorites for quick access
                </p>
              </div>
            </label>

            <label class="flex cursor-pointer items-center gap-3 rounded-lg border border-sr-line p-3 hover:bg-sr-subtle/70">
              <input
                type="radio"
                name="bulk[action]"
                value="unfavorite"
                class="radio radio-primary radio-sm"
              />
              <div>
                <div class="flex items-center gap-2">
                  <.icon name="hero-star" class="size-4 text-sr-muted" />
                  <span class="font-medium text-sr-ink">Remove from Favorites</span>
                </div>
                <p class="mt-1 text-xs text-sr-muted">
                  Remove selected interfaces from favorites
                </p>
              </div>
            </label>

            <label class="flex cursor-pointer items-center gap-3 rounded-lg border border-sr-line p-3 hover:bg-sr-subtle/70">
              <input
                type="radio"
                name="bulk[action]"
                value="enable_metrics"
                class="radio radio-primary radio-sm"
              />
              <div>
                <div class="flex items-center gap-2">
                  <.icon name="hero-chart-bar-solid" class="size-4 text-emerald-500" />
                  <span class="font-medium text-sr-ink">Enable Metrics Collection</span>
                </div>
                <p class="mt-1 text-xs text-sr-muted">
                  Start collecting metrics for selected interfaces
                </p>
              </div>
            </label>

            <label class="flex cursor-pointer items-center gap-3 rounded-lg border border-sr-line p-3 hover:bg-sr-subtle/70">
              <input
                type="radio"
                name="bulk[action]"
                value="disable_metrics"
                class="radio radio-primary radio-sm"
              />
              <div>
                <div class="flex items-center gap-2">
                  <.icon name="hero-chart-bar" class="size-4 text-sr-muted" />
                  <span class="font-medium text-sr-ink">Disable Metrics Collection</span>
                </div>
                <p class="mt-1 text-xs text-sr-muted">
                  Stop collecting metrics for selected interfaces
                </p>
              </div>
            </label>

            <label class="flex cursor-pointer items-center gap-3 rounded-lg border border-sr-line p-3 hover:bg-sr-subtle/70">
              <input
                type="radio"
                name="bulk[action]"
                value="add_tags"
                class="radio radio-primary radio-sm"
              />
              <div class="flex-1">
                <div class="flex items-center gap-2">
                  <.icon name="hero-tag-solid" class="size-4 text-sr-brand" />
                  <span class="font-medium text-sr-ink">Add Tags</span>
                </div>
                <p class="mt-1 text-xs text-sr-muted">
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
            class={ui_field_class()}
            placeholder="Enter tags separated by commas (e.g., wan, critical, primary)"
          />
          <label class="label">
            <span class="label-text-alt text-sr-muted">
              Tags will be added to existing tags
            </span>
          </label>
        </div>

        <div class="flex justify-end gap-2 pt-2">
          <.ui_button type="button" phx-click="close_interfaces_bulk_edit" size="sm" variant="ghost">
            Cancel
          </.ui_button>
          <.ui_button type="submit" size="sm" variant="primary">
            Apply
          </.ui_button>
        </div>
      </.form>
    </.ui_modal>
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

  attr(:iface, :map, required: true)

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

  attr(:status, :any, required: true)

  defp oper_status_badge(assigns) do
    ~H"""
    <.ui_badge
      :if={@status != nil}
      size="xs"
      variant={oper_status_variant(@status)}
      class="min-w-[4.5rem]"
      title="Operational Status"
    >
      <.icon name={oper_status_icon(@status)} class="size-3" />
      {oper_status_text(@status)}
    </.ui_badge>
    <.ui_badge
      :if={@status == nil}
      size="xs"
      variant="ghost"
      class="min-w-[4.5rem]"
      title="Operational Status"
    >
      <.icon name="hero-question-mark-circle" class="size-3" /> Unknown
    </.ui_badge>
    """
  end

  attr(:status, :any, required: true)

  defp admin_status_badge(assigns) do
    ~H"""
    <.ui_badge
      :if={@status != nil}
      size="xs"
      variant={admin_status_variant(@status)}
      class="min-w-[5rem]"
      title="Admin Status"
    >
      <.icon name={admin_status_icon(@status)} class="size-3" />
      {admin_status_text(@status)}
    </.ui_badge>
    """
  end

  # Operational status styling (1=up, 2=down, 3=testing)
  defp oper_status_variant(1), do: "success"
  defp oper_status_variant(2), do: "error"
  defp oper_status_variant(3), do: "warning"
  defp oper_status_variant(_), do: "ghost"

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
  defp admin_status_variant(1), do: "success"
  defp admin_status_variant(2), do: "warning"
  defp admin_status_variant(3), do: "info"
  defp admin_status_variant(_), do: "ghost"

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

  defp mapper_run_status_label(job) do
    case Map.get(job, :last_run_status) do
      :success -> "Success"
      :error -> "Error"
      _ -> "No runs"
    end
  end

  defp mapper_run_status_variant(job) do
    case Map.get(job, :last_run_status) do
      :success -> "success"
      :error -> "error"
      _ -> "ghost"
    end
  end

  defp format_timestamp(nil), do: "—"

  defp format_timestamp(value) do
    case parse_datetime(value) do
      {:ok, %DateTime{} = dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      _ -> "—"
    end
  end

  defp parse_datetime(%DateTime{} = dt), do: {:ok, dt}

  defp parse_datetime(%NaiveDateTime{} = ndt) do
    {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
  end

  defp parse_datetime(value) when is_binary(value) do
    with {:error, _} <- DateTime.from_iso8601(value),
         {:ok, ndt} <- NaiveDateTime.from_iso8601(value) do
      {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
    else
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> {:error, :invalid_datetime}
    end
  end

  defp parse_datetime(_), do: {:error, :invalid_datetime}
end
