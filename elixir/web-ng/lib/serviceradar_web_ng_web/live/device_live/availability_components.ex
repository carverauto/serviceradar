defmodule ServiceRadarWebNGWeb.DeviceLive.AvailabilityComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DeviceLive.SweepComponents,
    only: [
      format_ports_compact: 1,
      format_response_time: 1,
      get_sweep_agent_id: 1,
      truncate_agent_id: 1
    ]

  # ---------------------------------------------------------------------------
  # Availability Section
  # ---------------------------------------------------------------------------

  attr(:availability, :map, required: true)

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
    <div class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line">
        <div class="flex items-center justify-between gap-3">
          <div>
            <div class="text-sm font-semibold">Availability Timeline</div>
            <div class="text-xs text-sr-muted">
              Last 24h · each block = 30m bucket · green = online, red = offline
            </div>
          </div>
          <div class="text-right">
            <div class="text-sm font-semibold tabular-nums">{format_pct(@uptime_pct)}%</div>
            <div class="text-xs text-sr-muted">uptime (bucketed)</div>
          </div>
        </div>
      </div>

      <div class="p-4">
        <div :if={@segments != []} class="space-y-2">
          <div class="flex items-center justify-between text-xs text-sr-muted">
            <span>24h ago</span>
            <span>now</span>
          </div>

          <div class="h-6 rounded-lg bg-sr-subtle/50 p-0.5">
            <div class="h-full grid grid-flow-col auto-cols-fr gap-px rounded-md overflow-hidden bg-sr-control/60">
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
                <span class="text-sr-muted">online buckets</span>
              </div>
              <div class="flex items-center gap-2">
                <span class="w-3 h-3 rounded-sm bg-error"></span>
                <span class="tabular-nums font-semibold">{@offline_checks}</span>
                <span class="text-sr-muted">offline buckets</span>
              </div>
            </div>
            <div class="text-xs text-sr-muted tabular-nums">
              {@total_checks} total buckets
            </div>
          </div>
        </div>

        <div :if={@segments == []} class="text-sm text-sr-muted">
          No availability data found.
        </div>
      </div>
    </div>
    """
  end

  attr(:rows, :list, required: true)
  attr(:device_row, :map, default: %{})
  attr(:sweep_results, :map, default: nil)
  attr(:timezone, :string, default: "Etc/UTC")

  def agent_availability_section(assigns) do
    primary_agent_id = device_availability_source_agent_id(assigns.device_row)
    source_profile_id = device_availability_source_profile_id(assigns.device_row)

    {display_rows, availability_source} =
      availability_display_rows(assigns.rows, assigns.sweep_results)

    assigns =
      assigns
      |> assign(:primary_agent_id, primary_agent_id)
      |> assign(:source_profile_id, source_profile_id)
      |> assign(:display_rows, display_rows)
      |> assign(:availability_source, availability_source)
      |> assign(:row_count, length(display_rows))

    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line">
        <div class="flex items-center justify-between gap-3">
          <div class="flex items-center gap-2">
            <.icon name="hero-map-pin" class="size-4 text-sr-brand" />
            <span class="text-sm font-semibold">Agent Availability</span>
            <span :if={@row_count > 0} class="text-xs text-sr-muted">({@row_count})</span>
            <.ui_badge :if={present?(@source_profile_id)} size="xs" variant="info">
              profile assigned
            </.ui_badge>
          </div>
          <form
            :if={@availability_source == :canonical}
            phx-change="set_availability_source"
            class="flex items-center gap-2"
          >
            <label for="availability-source-agent" class="text-xs text-sr-muted">
              Canonical source
            </label>
            <select
              id="availability-source-agent"
              name="agent_id"
              class={ui_field_class(size: "xs", class: "w-48")}
            >
              <option value="" selected={!present?(@primary_agent_id)}>Fallback</option>
              <%= for {row, index} <- Enum.with_index(@display_rows) do %>
                <option value={row.agent_id} selected={row.agent_id == @primary_agent_id}>
                  {availability_agent_label(row)}
                </option>
              <% end %>
            </select>
          </form>
          <div
            :if={@availability_source == :sweep_history}
            class="text-xs text-sr-muted"
          >
            Source: recent sweep history
          </div>
          <div :if={@availability_source == :none} class="text-xs text-sr-muted">
            Canonical source: fallback
          </div>
        </div>
      </div>

      <div class="p-4">
        <div :if={@display_rows == []} class="text-sm text-sr-muted">
          No per-agent sweep availability has been recorded for this device yet.
        </div>

        <div :if={@display_rows != []} class="overflow-x-auto">
          <table class={ui_table_class(size: "xs")}>
            <thead>
              <tr class="text-xs text-sr-muted">
                <th>Agent</th>
                <th>Status</th>
                <th>Checked</th>
                <th>Response</th>
                <th>Ports</th>
                <th>Checks</th>
              </tr>
            </thead>
            <tbody>
              <%= for {row, index} <- Enum.with_index(@display_rows) do %>
                <tr class="hover:bg-sr-subtle/40">
                  <td>
                    <div class="flex items-center gap-2">
                      <span class="font-mono text-xs">{availability_agent_label(row)}</span>
                      <.ui_badge
                        :if={@availability_source == :canonical and row.agent_id == @primary_agent_id}
                        size="xs"
                        variant="primary"
                      >
                        source
                      </.ui_badge>
                      <.ui_badge
                        :if={
                          @availability_source == :canonical and row.agent_id == @primary_agent_id and
                            present?(@source_profile_id)
                        }
                        size="xs"
                        variant="info"
                      >
                        profile
                      </.ui_badge>
                    </div>
                  </td>
                  <td>
                    <span class={[
                      "inline-flex items-center gap-1",
                      row.is_available && "text-success",
                      !row.is_available && "text-error"
                    ]}>
                      <span class="size-1.5 rounded-full bg-current"></span>
                      {if row.is_available, do: "Available", else: "Unavailable"}
                    </span>
                  </td>
                  <td class="font-mono text-xs">
                    <.user_time
                      id={"device-agent-availability-#{availability_time_key(row, index)}-checked-at"}
                      value={row.checked_at}
                      timezone={@timezone}
                      style={:compact}
                    />
                  </td>
                  <td class="font-mono text-xs">{format_response_time(row.response_time_ms)}</td>
                  <td class="font-mono text-xs">{format_ports_compact(row.open_ports || [])}</td>
                  <td class="text-xs text-sr-muted">
                    {format_mode_results(row.sweep_modes_results)}
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

  defp availability_time_key(row, index) do
    [Map.get(row, :agent_id) || Map.get(row, "agent_id"), Map.get(row, :id) || Map.get(row, "id")]
    |> Enum.find_value(&availability_id_fragment/1)
    |> Kernel.||(Integer.to_string(index))
  end

  defp availability_id_fragment(value) when value in [nil, ""], do: nil

  defp availability_id_fragment(value) do
    case value |> to_string() |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-") |> String.trim("-") do
      "" -> nil
      fragment -> fragment
    end
  end

  defp device_availability_source_agent_id(device_row) when is_map(device_row) do
    Map.get(device_row, "availability_source_agent_id") ||
      Map.get(device_row, :availability_source_agent_id)
  end

  defp device_availability_source_agent_id(_), do: nil

  defp device_availability_source_profile_id(device_row) when is_map(device_row) do
    Map.get(device_row, "availability_source_profile_id") ||
      Map.get(device_row, :availability_source_profile_id)
  end

  defp device_availability_source_profile_id(_), do: nil

  defp availability_display_rows(rows, _sweep_results) when is_list(rows) and rows != [] do
    {rows, :canonical}
  end

  defp availability_display_rows(_rows, %{results: results}) when is_list(results) do
    results
    |> Enum.map(&availability_row_from_sweep/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> {[], :none}
      rows -> {rows, :sweep_history}
    end
  end

  defp availability_display_rows(_rows, _sweep_results), do: {[], :none}

  defp availability_row_from_sweep(result) do
    agent_id = get_sweep_agent_id(result)

    if agent_id == "—" do
      nil
    else
      %{
        agent_id: agent_id,
        agent_name: nil,
        is_available: Map.get(result, :status) == :available,
        checked_at: Map.get(result, :inserted_at),
        response_time_ms: Map.get(result, :response_time_ms),
        open_ports: Map.get(result, :open_ports) || [],
        sweep_modes_results: Map.get(result, :sweep_modes_results) || %{}
      }
    end
  end

  defp availability_agent_label(%{agent_name: name, agent_id: agent_id}) when is_binary(name) and name != "" do
    "#{name} (#{truncate_agent_id(agent_id)})"
  end

  defp availability_agent_label(%{agent_id: agent_id}), do: truncate_agent_id(agent_id)
  defp availability_agent_label(_), do: "—"

  defp format_mode_results(results) when is_map(results) do
    results
    |> Enum.map_join(" · ", fn {mode, status} ->
      "#{String.upcase(to_string(mode))} #{format_mode_status(status)}"
    end)
    |> case do
      "" -> "—"
      text -> text
    end
  end

  defp format_mode_results(_), do: "—"

  defp format_mode_status("success"), do: "ok"
  defp format_mode_status("failed"), do: "failed"
  defp format_mode_status("no_response"), do: "no response"
  defp format_mode_status(status), do: to_string(status)

  defp format_pct(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  defp format_pct(value) when is_integer(value), do: Integer.to_string(value)
  defp format_pct(_), do: "—"

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
end
