defmodule ServiceRadarWebNGWeb.DeviceLive.SweepComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  # ---------------------------------------------------------------------------
  # Sweep Status Section
  # ---------------------------------------------------------------------------

  attr(:sweep_results, :map, required: true)
  attr(:timezone, :string, default: "Etc/UTC")

  def sweep_status_section(assigns) do
    results = Map.get(assigns.sweep_results, :results, [])
    latest = List.first(results)

    assigns =
      assigns
      |> assign(:results, results)
      |> assign(:latest, latest)
      |> assign(:total, length(results))

    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line">
        <div class="flex items-center justify-between gap-3">
          <div class="flex items-center gap-2">
            <.icon name="hero-signal" class="size-4 text-info" />
            <span class="text-sm font-semibold">Network Sweep Status</span>
          </div>
          <.link navigate={~p"/settings/networks"} class="text-xs text-sr-brand hover:underline">
            Manage Sweeps
          </.link>
        </div>
      </div>

      <div class="p-4">
        <%= if @latest do %>
          <div class="grid grid-cols-1 sm:grid-cols-3 gap-4 mb-4">
            <div class="p-3 bg-sr-subtle/50 rounded-lg">
              <div class="text-xs text-sr-muted uppercase">Status</div>
              <div class="mt-1 flex items-center gap-2">
                <span class={[
                  "size-2 rounded-full",
                  @latest.status == :available && "bg-success",
                  @latest.status == :unavailable && "bg-error",
                  @latest.status not in [:available, :unavailable] && "bg-warning"
                ]}></span>
                <span class="font-medium">{status_label(@latest.status)}</span>
              </div>
            </div>
            <div class="p-3 bg-sr-subtle/50 rounded-lg">
              <div class="text-xs text-sr-muted uppercase">Response Time</div>
              <div class="mt-1 font-mono">
                {format_response_time(@latest.response_time_ms)}
              </div>
            </div>
            <div class="p-3 bg-sr-subtle/50 rounded-lg">
              <div class="text-xs text-sr-muted uppercase">Last Sweep</div>
              <div class="mt-1 text-sm">
                <.user_time
                  id="device-sweep-latest-inserted-at"
                  value={@latest.inserted_at}
                  timezone={@timezone}
                  style={:compact}
                />
              </div>
            </div>
          </div>

          <%= if @latest.open_ports != [] do %>
            <div class="mt-4">
              <div class="text-xs text-sr-muted uppercase mb-2">Open Ports</div>
              <div class="flex flex-wrap gap-2">
                <%= for port <- @latest.open_ports do %>
                  <.ui_badge variant="ghost" size="sm" class="font-mono">{port}</.ui_badge>
                <% end %>
              </div>
            </div>
          <% end %>

          <%= if @total > 1 do %>
            <div class="mt-4 pt-4 border-t border-sr-line">
              <div class="text-xs text-sr-muted mb-2">
                Recent Sweep History ({@total} results)
              </div>
              <div class="sr-ui-table-shell">
                <table class={ui_table_class(size: "xs")}>
                  <thead>
                    <tr class="text-xs text-sr-muted">
                      <th>Time</th>
                      <th>Agent</th>
                      <th>Status</th>
                      <th>Checks</th>
                      <th>Response</th>
                      <th>Ports</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for {result, index} <- Enum.with_index(Enum.take(@results, 5)) do %>
                      <tr class="hover:bg-sr-subtle/40">
                        <td class="font-mono text-xs">
                          <.user_time
                            id={"device-sweep-history-#{sweep_time_key(result, index)}-inserted-at"}
                            value={result.inserted_at}
                            timezone={@timezone}
                            style={:compact}
                          />
                        </td>
                        <td
                          class="font-mono text-xs truncate max-w-[8rem]"
                          title={get_sweep_agent_id(result)}
                        >
                          {truncate_agent_id(get_sweep_agent_id(result))}
                        </td>
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
                        <td class="text-xs whitespace-nowrap">
                          {format_sweep_checks(result)}
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
          <div class="text-center py-4 text-sr-muted">
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

  attr(:aliases, :list, required: true)
  attr(:show_stale, :boolean, default: false)
  attr(:error, :string, default: nil)
  attr(:timezone, :string, default: "Etc/UTC")

  def ip_aliases_section(assigns) do
    assigns =
      assigns
      |> assign(:alias_count, length(assigns.aliases))
      |> assign(:toggle_label, if(assigns.show_stale, do: "Hide stale", else: "Show stale"))

    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line flex items-center justify-between gap-3">
        <div class="flex items-center gap-2">
          <.icon name="hero-arrow-path-rounded-square" class="size-4 text-sr-brand" />
          <span class="text-sm font-semibold">IP Aliases</span>
          <span class="text-xs text-sr-muted">({@alias_count})</span>
        </div>
        <.ui_button
          type="button"
          phx-click="toggle_aliases"
          aria-pressed={@show_stale}
          size="xs"
          variant="ghost"
        >
          {@toggle_label}
        </.ui_button>
      </div>

      <div class="p-4">
        <div :if={is_binary(@error)} class="text-sm text-error">
          {@error}
        </div>

        <div :if={!is_binary(@error) and @aliases == []} class="text-sm text-sr-muted">
          No IP aliases recorded yet.
        </div>

        <div :if={!is_binary(@error) and @aliases != []} class="overflow-x-auto">
          <table class={ui_table_class(size: "xs")}>
            <thead>
              <tr class="text-xs text-sr-muted">
                <th>IP Address</th>
                <th>Type</th>
                <th>State</th>
                <th>Sightings</th>
                <th>Last Seen</th>
              </tr>
            </thead>
            <tbody>
              <%= for alias_state <- @aliases do %>
                <tr class="hover:bg-sr-subtle/40">
                  <td class="font-mono text-xs">{alias_state.alias_value}</td>
                  <td>
                    <.ui_badge size="sm" variant={alias_type_variant(alias_state.alias_type)}>
                      {alias_type_label(alias_state.alias_type)}
                    </.ui_badge>
                  </td>
                  <td>
                    <.ui_badge size="sm" variant={alias_state_variant(alias_state.state)}>
                      {alias_state_label(alias_state.state)}
                    </.ui_badge>
                  </td>
                  <td class="text-xs tabular-nums">{alias_state.sighting_count || 0}</td>
                  <td class="font-mono text-xs">
                    <.user_time
                      id={"device-ip-alias-#{time_key(alias_state.alias_value)}-last-seen-at"}
                      value={alias_state.last_seen_at}
                      timezone={@timezone}
                      style={:compact}
                    />
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

  # "Identity" is the alias DIRE merges devices on. "Interface" is an address
  # seen on the device's own interface and deliberately excluded from merging --
  # see ServiceRadar.Identity.DeviceAliasState. The visual distinction matters:
  # an interface address may legitimately be reported by several devices (VRRP,
  # anycast, vendor internals), so it is evidence of "this device has it", not
  # evidence of "this device IS it".
  defp alias_type_label(:interface_ip), do: "Interface"
  defp alias_type_label(_), do: "Identity"

  # Variants drawn from the same palette as @alias_state_variants above:
  # "outline" for identity (the load-bearing one), "ghost" to visually recede an
  # interface observation.
  defp alias_type_variant(:interface_ip), do: "ghost"
  defp alias_type_variant(_), do: "outline"

  defp status_label(:available), do: "Available"
  defp status_label(:unavailable), do: "Unavailable"
  defp status_label(:timeout), do: "Timeout"
  defp status_label(:error), do: "Error"
  defp status_label(other), do: to_string(other)

  def format_response_time(nil), do: "—"
  def format_response_time(ms) when is_number(ms), do: "#{ms}ms"
  def format_response_time(_), do: "—"

  def format_ports_compact([]), do: "—"
  def format_ports_compact(ports) when length(ports) <= 3, do: Enum.join(ports, ", ")
  def format_ports_compact(ports), do: "#{length(ports)} ports"

  defp format_sweep_checks(%{sweep_modes_results: modes}) when is_map(modes) do
    modes
    |> sweep_check_parts()
    |> case do
      [] -> "—"
      parts -> Enum.join(parts, " · ")
    end
  end

  defp format_sweep_checks(_), do: "—"

  defp sweep_check_parts(modes) do
    Enum.reject(
      [sweep_mode_part(modes, "icmp", "ICMP"), sweep_mode_part(modes, "tcp", "TCP")],
      &is_nil/1
    )
  end

  defp sweep_mode_part(modes, key, label) do
    case Map.get(modes, key) || Map.get(modes, sweep_mode_atom_key(key)) do
      nil -> nil
      value -> "#{label} #{sweep_mode_status_label(value)}"
    end
  end

  defp sweep_mode_atom_key("icmp"), do: :icmp
  defp sweep_mode_atom_key("tcp"), do: :tcp

  defp sweep_mode_status_label("success"), do: "ok"
  defp sweep_mode_status_label(:success), do: "ok"
  defp sweep_mode_status_label("failed"), do: "failed"
  defp sweep_mode_status_label(:failed), do: "failed"
  defp sweep_mode_status_label("no_response"), do: "no response"
  defp sweep_mode_status_label(:no_response), do: "no response"
  defp sweep_mode_status_label(value), do: to_string(value)

  def get_sweep_agent_id(result) do
    case result do
      %{execution: %{agent_id: agent_id}} when is_binary(agent_id) -> agent_id
      _ -> "—"
    end
  end

  def truncate_agent_id("—"), do: "—"

  def truncate_agent_id(agent_id) when is_binary(agent_id) do
    if String.length(agent_id) > 12 do
      String.slice(agent_id, 0, 12) <> "…"
    else
      agent_id
    end
  end

  defp alias_state_label(nil), do: "Unknown"

  defp alias_state_label(state) do
    state
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  @alias_state_variants %{
    "confirmed" => "success",
    "detected" => "info",
    "updated" => "warning",
    "stale" => "ghost",
    "replaced" => "ghost",
    "archived" => "ghost"
  }

  defp alias_state_variant(state) do
    state
    |> normalize_alias_state()
    |> then(&Map.get(@alias_state_variants, &1, "outline"))
  end

  defp normalize_alias_state(nil), do: ""
  defp normalize_alias_state(state) when is_atom(state), do: Atom.to_string(state)
  defp normalize_alias_state(state) when is_binary(state), do: state
  defp normalize_alias_state(_), do: ""

  defp sweep_time_key(result, index) do
    [
      Map.get(result, :id) || Map.get(result, "id"),
      Map.get(result, :uid) || Map.get(result, "uid"),
      Map.get(result, :execution_id) || Map.get(result, "execution_id")
    ]
    |> Enum.find_value(&optional_time_key/1)
    |> Kernel.||(Integer.to_string(index))
  end

  defp optional_time_key(value) when value in [nil, ""], do: nil

  defp optional_time_key(value) do
    case time_key(value) do
      "" -> nil
      key -> key
    end
  end

  defp time_key(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")
    |> String.trim("-")
  end
end
