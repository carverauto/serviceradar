defmodule ServiceRadarWebNGWeb.DeviceLive.IndexView.Table do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DeviceLive.IndexView.Badges
  import ServiceRadarWebNGWeb.DeviceLive.IndexView.DeviceType
  import ServiceRadarWebNGWeb.DeviceLive.IndexView.Rows
  import ServiceRadarWebNGWeb.DeviceLive.IndexView.Sparkline
  import ServiceRadarWebNGWeb.DeviceLive.IndexView.Stats, only: [format_stat_number: 1]
  import ServiceRadarWebNGWeb.UIComponents

  def render(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex w-full flex-wrap items-center justify-between gap-3">
          <div class="min-w-0">
            <div class="text-sm font-semibold text-base-content">Matching Devices</div>
            <div class="text-xs text-base-content/60">
              <%= if is_integer(@total_device_count) do %>
                {format_stat_number(@total_device_count)} total {if @total_device_count == 1,
                  do: "result",
                  else: "results"}
              <% else %>
                Counting total results…
              <% end %>
            </div>
          </div>
          <div :if={is_binary(@icmp_error)} class="badge badge-warning badge-sm">
            ICMP: {@icmp_error}
          </div>
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
              <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Device</th>
              <th
                class="text-xs font-semibold text-base-content/70 bg-base-200/60"
                title="OCSF Device Type"
              >
                Type
              </th>
              <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Vendor</th>
              <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Model</th>
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
              <% active = active_device_row?(row) %>
              <% icmp =
                if is_binary(device_uid), do: Map.get(@icmp_sparklines, device_uid), else: nil %>
              <% has_snmp =
                is_binary(device_uid) and Map.get(@snmp_presence, device_uid, false) == true %>
              <% has_sysmon =
                is_binary(device_uid) and Map.get(@sysmon_presence, device_uid, false) == true %>
              <tr class={"hover:bg-base-200/40 #{if is_selected, do: "bg-primary/5", else: ""} #{if deleted or not active, do: "opacity-60", else: ""}"}>
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
                <td class="max-w-[18rem]">
                  <div class="flex items-center gap-2 min-w-0">
                    <div class="flex items-center gap-2 min-w-0">
                      <.link
                        :if={is_binary(device_uid)}
                        navigate={~p"/devices/#{device_uid}"}
                        class="link link-hover truncate text-sm"
                        title={"UID: #{device_uid}"}
                      >
                        {Map.get(row, "hostname") || device_uid}
                      </.link>
                      <.icon
                        :if={agent_device_row?(row, @agent_device_uids)}
                        name="hero-bolt"
                        class="w-4 h-4 text-warning shrink-0"
                        title="Agent device"
                      />
                      <span :if={not is_binary(device_uid)} class="truncate text-sm">
                        {Map.get(row, "hostname") || "—"}
                      </span>
                    </div>
                    <span :if={deleted} class="badge badge-ghost badge-xs shrink-0">Deleted</span>
                    <span :if={not active} class="badge badge-warning badge-xs shrink-0">
                      Out of service
                    </span>
                  </div>
                  <div class="font-mono text-[0.7rem] text-base-content/60 truncate mt-0.5">
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
                  <span
                    :if={snmp_fallback_derived?(row) and present_text?(Map.get(row, "vendor_name"))}
                    class="badge badge-ghost badge-xs ml-1"
                  >
                    SNMP
                  </span>
                </td>
                <td class="text-xs max-w-[12rem] truncate">
                  {display_model(Map.get(row, "model"))}
                </td>
                <td class="text-xs">
                  <.availability_badge available={
                    effective_availability(row, @effective_availability_by_device)
                  } />
                </td>
                <td class="text-xs">
                  <.icmp_sparkline :if={is_map(icmp)} spark={icmp} />
                  <span :if={not is_map(icmp)} class="text-base-content/40">—</span>
                </td>
                <td class="text-xs">
                  <div class="flex flex-col gap-1">
                    <.metrics_presence
                      device_uid={device_uid}
                      has_snmp={has_snmp}
                      has_sysmon={has_sysmon}
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
    """
  end
end
