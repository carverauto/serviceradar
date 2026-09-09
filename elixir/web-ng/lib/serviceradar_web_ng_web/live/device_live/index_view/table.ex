defmodule ServiceRadarWebNGWeb.DeviceLive.IndexView.Table do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DeviceLive.IndexView.Badges
  import ServiceRadarWebNGWeb.DeviceLive.IndexView.DeviceType
  import ServiceRadarWebNGWeb.DeviceLive.IndexView.Rows
  import ServiceRadarWebNGWeb.DeviceLive.IndexView.Sparkline
  import ServiceRadarWebNGWeb.DeviceLive.IndexView.Stats, only: [format_stat_number: 1]
  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadarWebNGWeb.Components.PrefixTagChips
  alias ServiceRadarWebNGWeb.DeviceLive.DeviceFormData
  alias ServiceRadarWebNGWeb.DeviceLive.IndexPath

  def render(assigns) do
    ~H"""
    <.ui_panel
      class="flex h-full min-h-[28rem] flex-col"
      body_class="flex min-h-0 flex-1 flex-col"
    >
      <:header>
        <div class="flex w-full flex-wrap items-center justify-between gap-3">
          <div class="min-w-0">
            <div class="text-sm font-semibold text-sr-ink">Matching Devices</div>
            <div class="text-xs text-sr-muted">
              <%= if is_integer(@total_device_count) do %>
                {format_stat_number(@total_device_count)} total {if @total_device_count == 1,
                  do: "result",
                  else: "results"}
              <% else %>
                Counting total results…
              <% end %>
            </div>
          </div>
          <.ui_badge :if={is_binary(@icmp_error)} size="sm" variant="warning">
            ICMP: {@icmp_error}
          </.ui_badge>
        </div>
      </:header>

      <div class="sr-ui-table-shell min-h-0 flex-1 overflow-auto">
        <table class={ui_table_class(size: "sm", zebra: true, class: "w-full")}>
          <thead>
            <tr>
              <th class="w-10 text-center">
                <input
                  type="checkbox"
                  class={ui_checkbox_class()}
                  checked={@all_selected}
                  phx-click="toggle_select_all"
                />
              </th>
              <th>Device</th>
              <th title="OCSF Device Type">Type</th>
              <th>Vendor</th>
              <th>Model</th>
              <th>Tags</th>
              <th title="GRPC Health Check Status">Status</th>
              <th title="ICMP Network Tests">Network</th>
              <th title="Telemetry availability for this device">Metrics</th>
              <th>Risk</th>
              <th :if={@composite_verdicts_by_device != %{}} title="Composite check verdict">
                Verdict
              </th>
              <th>Last Seen</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@devices == []}>
              <td
                colspan={if @composite_verdicts_by_device == %{}, do: 11, else: 12}
                class="py-8 text-center text-sm text-sr-muted"
              >
                No devices found.
              </td>
            </tr>

            <%= for {row, row_idx} <- @devices |> Enum.filter(&is_map/1) |> Enum.with_index() do %>
              <% device_uid = Map.get(row, "uid") || Map.get(row, "id") %>
              <% is_selected =
                is_binary(device_uid) and MapSet.member?(@selected_devices, device_uid) %>
              <% deleted = deleted_device_row?(row) %>
              <% active = active_device_row?(row) %>
              <% icmp =
                if is_binary(device_uid), do: Map.get(@icmp_sparklines, device_uid), else: nil %>
              <% has_snmp =
                is_binary(device_uid) and Map.get(@snmp_presence, device_uid, false) == true %>
              <% has_sysmon =
                is_binary(device_uid) and Map.get(@sysmon_presence, device_uid, false) == true %>
              <tr class={"hover:bg-sr-subtle/40 #{if is_selected, do: "bg-sr-brand/5", else: ""} #{if deleted or not active, do: "opacity-60", else: ""}"}>
                <td class="text-center">
                  <input
                    :if={is_binary(device_uid)}
                    type="checkbox"
                    class={ui_checkbox_class()}
                    checked={is_selected}
                    phx-click="toggle_device_select"
                    phx-value-uid={device_uid}
                  />
                </td>
                <td class="max-w-[18rem]">
                  <div class="flex items-center gap-2 min-w-0">
                    <div class="flex items-center gap-2 min-w-0">
                      <.link
                        :if={is_binary(device_uid)}
                        navigate={IndexPath.show_path(device_uid, return_to: @devices_return_path)}
                        class="text-sr-brand hover:underline truncate text-sm"
                        title={"UID: #{device_uid}"}
                      >
                        {Map.get(row, "hostname") || device_uid}
                      </.link>
                      <.icon
                        :if={agent_device_row?(row, @agent_device_uids)}
                        name="hero-bolt"
                        class="size-4 shrink-0 text-amber-400"
                        title="Agent device"
                      />
                      <span :if={not is_binary(device_uid)} class="truncate text-sm">
                        {Map.get(row, "hostname") || "—"}
                      </span>
                    </div>
                    <.ui_badge :if={deleted} size="xs" variant="ghost" class="shrink-0">
                      Deleted
                    </.ui_badge>
                    <.ui_badge :if={not active} size="xs" variant="warning" class="shrink-0">
                      Out of service
                    </.ui_badge>
                  </div>
                  <div class="font-mono text-[0.7rem] text-sr-muted truncate mt-0.5">
                    {Map.get(row, "ip") || "—"}
                  </div>
                </td>
                <td class="text-xs">
                  <.device_type_badge
                    type={device_type_value(row)}
                    type_id={Map.get(row, "type_id")}
                  />
                </td>
                <td class="text-xs max-w-[8rem] truncate">
                  {Map.get(row, "vendor_name") || "—"}
                  <.ui_badge
                    :if={snmp_fallback_derived?(row) and present_text?(Map.get(row, "vendor_name"))}
                    size="xs"
                    variant="ghost"
                    class="ml-1"
                  >
                    SNMP
                  </.ui_badge>
                </td>
                <td class="text-xs max-w-[12rem] truncate">
                  {display_model(Map.get(row, "model"))}
                </td>
                <% tag_list = DeviceFormData.format_tag_list(Map.get(row, "tags")) %>
                <td class="text-xs max-w-[12rem]">
                  <PrefixTagChips.static :if={tag_list != []} tags={tag_list} />
                  <span :if={tag_list == []} class="text-sr-muted">—</span>
                </td>
                <td class="text-xs">
                  <.availability_badge available={
                    effective_availability(row, @effective_availability_by_device)
                  } />
                </td>
                <td class="text-xs">
                  <.icmp_sparkline :if={is_map(icmp)} spark={icmp} />
                  <span :if={not is_map(icmp)} class="text-sr-muted">—</span>
                </td>
                <td class="text-xs">
                  <div class="flex flex-col gap-1">
                    <.metrics_presence
                      device_uid={device_uid}
                      has_snmp={has_snmp}
                      has_sysmon={has_sysmon}
                      return_to={@devices_return_path}
                    />
                    <.sysmon_profile_badge
                      :if={has_sysmon and is_map(Map.get(@sysmon_profiles_by_device, device_uid))}
                      profile={Map.get(@sysmon_profiles_by_device, device_uid)}
                    />
                  </div>
                </td>
                <td class="text-xs">
                  <.risk_level_badge risk_level={Map.get(row, "risk_level")} />
                </td>
                <td :if={@composite_verdicts_by_device != %{}} class="text-xs">
                  <.composite_verdict_cell verdict={
                    Map.get(@composite_verdicts_by_device, device_uid)
                  } />
                </td>
                <td class="font-mono text-xs">
                  <.srql_cell
                    id={"device-last-seen-#{row_idx}"}
                    col="last_seen"
                    value={Map.get(row, "last_seen")}
                    timezone={@current_scope.user.timezone}
                  />
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <div class="mt-4 pt-4 border-t border-sr-line">
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
    """
  end

  attr(:verdict, :map, default: nil)

  # A device in the filtered scope with no recorded verdict has not been
  # evaluated yet. An empty cell would read as "no verdict", which is a
  # different and wrong claim.
  defp composite_verdict_cell(assigns) do
    ~H"""
    <span :if={is_nil(@verdict)} class="text-sr-muted">not yet evaluated</span>

    <span
      :if={@verdict}
      class="inline-flex items-center gap-1.5"
      data-list-verdict={@verdict.verdict}
      data-list-status={@verdict.status}
    >
      <span class={["size-1.5 rounded-full", verdict_dot_class(@verdict.status)]} />
      <span class="font-mono">{@verdict.verdict}</span>
    </span>
    """
  end

  defp verdict_dot_class(:healthy), do: "bg-emerald-500"
  defp verdict_dot_class(:degraded), do: "bg-amber-500"
  defp verdict_dot_class(:down), do: "bg-rose-500"
  defp verdict_dot_class(_status), do: "bg-sr-muted"
end
