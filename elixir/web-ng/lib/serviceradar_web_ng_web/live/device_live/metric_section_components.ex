defmodule ServiceRadarWebNGWeb.DeviceLive.MetricSectionComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.SRQLComponents, only: [srql_results_table: 1]

  attr(:sections, :list, default: [])
  attr(:device_uid, :string, required: true)
  attr(:timezone, :string, required: true)
  attr(:chart_focus, :any, default: nil)
  attr(:time_range, :string, default: "last_24h")

  def metric_sections_content(assigns) do
    ~H"""
    <div :if={@sections != []} class="flex items-center justify-end gap-2">
      <span class="text-[11px] uppercase tracking-wide text-sr-muted">Window</span>
      <div class="flex flex-wrap gap-1">
        <.ui_button
          :for={{label, value} <- sysmon_range_options()}
          type="button"
          phx-click="sysmon_set_range"
          phx-value-range={value}
          size="xs"
          variant={if(@time_range == value, do: "primary", else: "ghost")}
          active={@time_range == value}
        >
          {label}
        </.ui_button>
      </div>
    </div>

    <%= for {section, section_index} <- Enum.with_index(@sections) do %>
      <div class="rounded-xl border border-sr-line bg-sr-surface">
        <div class="px-4 py-3 border-b border-sr-line flex items-center justify-between gap-3">
          <div class="flex items-center gap-3">
            <span class="text-sm font-semibold">{section.title}</span>
            <span class="text-xs text-sr-muted">{section.subtitle}</span>
            <span
              :if={Map.get(section, :subtitle_time)}
              class="text-xs text-sr-muted"
            >
              · centered at
              <.user_time
                id={"device-#{@device_uid}-#{section.key}-#{section_index}-subtitle-time"}
                value={Map.get(section, :subtitle_time)}
                timezone={@timezone}
                style={:compact}
                fallback=""
              />
            </span>
          </div>
          <div class="flex items-center gap-3">
            <div
              :if={is_map(Map.get(section, :header_stats))}
              class="flex items-center gap-2 text-[11px] text-sr-muted"
            >
              <% stats = Map.get(section, :header_stats) %>
              <span class="font-mono">min {format_metric_value(Map.get(stats, :min), section)}</span>
              <span class="font-mono">avg {format_metric_value(Map.get(stats, :avg), section)}</span>
              <span class="font-mono">max {format_metric_value(Map.get(stats, :max), section)}</span>
            </div>
            <div
              :if={is_number(Map.get(section, :header_value))}
              class="flex items-center gap-2"
            >
              <% header_value = Map.get(section, :header_value) %>
              <div
                :if={percent_metric?(section)}
                class="h-1.5 w-20 rounded-full bg-sr-subtle overflow-hidden"
              >
                <div
                  class="h-full bg-accent"
                  style={"width: #{percent_width(header_value)}%"}
                />
              </div>
              <span class="text-xs font-mono">{format_metric_value(header_value, section)}</span>
            </div>
          </div>
        </div>

        <div :if={is_binary(section.error)} class="px-4 py-3 text-sm text-sr-muted">
          {section.error}
        </div>

        <div :if={is_nil(section.error)}>
          <%= if section.key == "processes" do %>
            <.srql_results_table
              id={"device-#{@device_uid}-processes"}
              rows={Map.get(section, :rows, [])}
              columns={["process", "pid", "cpu_pct", "memory_pct"]}
              container={false}
              timezone={@timezone}
              empty_message="No process metrics yet."
            />
          <% else %>
            <%= for {panel, idx} <- Enum.with_index(section.panels) do %>
              <.live_component
                module={panel.plugin}
                id={"device-#{@device_uid}-#{section.key}-#{panel.id}-#{idx}"}
                title={Map.get(panel, :title) || section.title}
                panel_assigns={panel_assigns(panel, @chart_focus, @timezone)}
              />
            <% end %>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  defp sysmon_range_options do
    [{"1h", "last_1h"}, {"6h", "last_6h"}, {"24h", "last_24h"}, {"7d", "last_7d"}]
  end

  defp format_pct(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  defp format_pct(value) when is_integer(value), do: Integer.to_string(value)
  defp format_pct(_), do: "—"

  defp format_metric_value(value, section) do
    case metric_unit(section) do
      :percent -> "#{format_pct(value)}%"
      :count -> format_count(value)
      _ -> format_pct(value)
    end
  end

  defp format_count(value) when is_integer(value), do: Integer.to_string(value)

  defp format_count(value) when is_float(value) do
    if value == Float.round(value, 0) do
      value |> round() |> Integer.to_string()
    else
      :erlang.float_to_binary(value, decimals: 1)
    end
  end

  defp format_count(_), do: "—"

  defp percent_metric?(section), do: metric_unit(section) == :percent

  defp metric_unit(section) when is_map(section), do: Map.get(section, :unit, :percent)
  defp metric_unit(_), do: :percent

  defp percent_width(value) when is_number(value) do
    value = value * 1.0

    cond do
      value < 0.0 -> 0.0
      value > 100.0 -> 100.0
      true -> value
    end
  end

  defp percent_width(_), do: 0

  defp panel_assigns(panel, chart_focus, timezone) do
    panel.assigns
    |> Map.put(:compact, true)
    |> Map.put(:timezone, timezone)
    |> maybe_put_chart_focus(chart_focus)
  end

  defp maybe_put_chart_focus(assigns, %{row: %{} = row, kind: kind}) do
    case chart_focus(row, kind) do
      nil -> assigns
      focus -> Map.put(assigns, :chart_focus, focus)
    end
  end

  defp maybe_put_chart_focus(assigns, _chart_focus), do: assigns

  defp chart_focus(row, kind) do
    case first_present(row, ["time", "timestamp", "window_ended_at", "projected_exhaustion_at"]) do
      nil ->
        nil

      timestamp ->
        %{
          timestamp: timestamp,
          label: focus_label(row, kind),
          severity: value(row, "severity") || value(row, "status"),
          series: first_present(row, ["series", "series_key", "metric_name", "resource_key"]),
          series_key: value(row, "series_key"),
          metric_name: value(row, "metric_name"),
          resource_key: value(row, "resource_key"),
          window_minutes: 15
        }
    end
  end

  defp focus_label(row, "capacity") do
    value(row, "resource_label") || value(row, "metric_name") || "Capacity finding"
  end

  defp focus_label(row, _kind) do
    value(row, "finding_title") || value(row, "metric_name") || "Anomaly finding"
  end

  defp first_present(row, keys) do
    Enum.find_value(keys, fn key ->
      case value(row, key) do
        nil -> nil
        value when is_binary(value) -> if String.trim(value) == "", do: nil, else: value
        value -> value
      end
    end)
  end

  defp value(row, key) when is_map(row), do: Map.get(row, key) || Map.get(row, known_atom_key(key))

  defp known_atom_key("finding_title"), do: :finding_title
  defp known_atom_key("metric_name"), do: :metric_name
  defp known_atom_key("projected_exhaustion_at"), do: :projected_exhaustion_at
  defp known_atom_key("resource_key"), do: :resource_key
  defp known_atom_key("resource_label"), do: :resource_label
  defp known_atom_key("series"), do: :series
  defp known_atom_key("series_key"), do: :series_key
  defp known_atom_key("severity"), do: :severity
  defp known_atom_key("status"), do: :status
  defp known_atom_key("time"), do: :time
  defp known_atom_key("timestamp"), do: :timestamp
  defp known_atom_key("window_ended_at"), do: :window_ended_at
  defp known_atom_key(_key), do: nil
end
