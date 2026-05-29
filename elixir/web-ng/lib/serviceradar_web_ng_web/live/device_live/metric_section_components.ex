defmodule ServiceRadarWebNGWeb.DeviceLive.MetricSectionComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.SRQLComponents, only: [srql_results_table: 1]

  attr(:sections, :list, default: [])
  attr(:device_uid, :string, required: true)

  def metric_sections_content(assigns) do
    ~H"""
    <%= for section <- @sections do %>
      <div class="rounded-xl border border-base-200 bg-base-100">
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
end
