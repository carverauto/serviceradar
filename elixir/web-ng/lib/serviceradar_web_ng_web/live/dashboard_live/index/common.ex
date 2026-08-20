defmodule ServiceRadarWebNGWeb.DashboardLive.Index.Common do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  attr(:card, :map, required: true)

  def kpi_card(assigns) do
    loading? = Map.get(assigns.card, :loading, false)

    assigns = assign(assigns, :loading?, loading?)

    ~H"""
    <.link
      href={@card.href}
      class={[
        "sr-ops-kpi-card",
        "sr-ops-kpi-card-link",
        "tone-#{@card.tone}",
        @loading? && "is-loading"
      ]}
      aria-label={@card.aria_label}
      aria-busy={@loading?}
      data-loading={to_string(@loading?)}
    >
      <div class="sr-ops-kpi-icon">
        <.icon name={@card.icon} class="size-9" />
      </div>
      <div class="min-w-0">
        <p>{@card.title}</p>
        <span :if={@loading?} class="skeleton mt-1 h-7 w-16 rounded-sm"></span>
        <strong :if={!@loading?}>{@card.value}</strong>
        <span :if={@loading?} class="skeleton mt-1 h-3 w-24 rounded-sm"></span>
        <span :if={!@loading?}>{@card.detail}</span>
      </div>
      <.sparkline values={@card.sparkline} tone={@card.tone} class="sr-ops-kpi-sparkline" />
    </.link>
    """
  end

  attr(:title, :string, required: true)
  attr(:class, :string, default: "")
  slot(:actions)
  slot(:inner_block, required: true)

  def panel(assigns) do
    ~H"""
    <article class={["sr-ops-panel", @class]}>
      <header class="sr-ops-panel-header">
        <h2>{@title}</h2>
        <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
      </header>
      {render_slot(@inner_block)}
    </article>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:icon, :string, default: nil)
  attr(:href, :string, default: nil)
  attr(:aria_label, :string, default: nil)

  def small_stat(assigns) do
    ~H"""
    <.link
      :if={is_binary(@href) and @href != ""}
      href={@href}
      class="sr-ops-small-stat sr-ops-small-stat-link"
      aria-label={@aria_label || "Open #{@label}"}
    >
      <span class="flex items-center gap-2">
        <.icon :if={@icon} name={@icon} class="size-4" />
        {@label}
      </span>
      <strong>{@value}</strong>
    </.link>
    <div :if={!is_binary(@href) or @href == ""} class="sr-ops-small-stat">
      <span class="flex items-center gap-2">
        <.icon :if={@icon} name={@icon} class="size-4" />
        {@label}
      </span>
      <strong>{@value}</strong>
    </div>
    """
  end

  attr(:values, :list, default: [])
  attr(:tone, :string, default: "neutral")
  attr(:class, :string, default: "")

  def sparkline(assigns) do
    assigns =
      assigns
      |> assign(:spark_values, sparkline_values(assigns.values))
      |> assign(:line_path, sparkline_line_path(assigns.values))
      |> assign(:area_path, sparkline_area_path(assigns.values))

    ~H"""
    <svg
      class={["sr-ops-sparkline", "tone-#{@tone}", @class]}
      viewBox="0 0 100 32"
      preserveAspectRatio="none"
      aria-hidden="true"
    >
      <line
        :if={@spark_values == []}
        class="sr-ops-sparkline-baseline"
        x1="0"
        x2="100"
        y1="24"
        y2="24"
      />
      <g class="sr-ops-sparkline-grid" aria-hidden="true">
        <line x1="0" x2="100" y1="8" y2="8" />
        <line x1="0" x2="100" y1="16" y2="16" />
        <line x1="0" x2="100" y1="24" y2="24" />
        <line x1="25" x2="25" y1="5" y2="29" />
        <line x1="50" x2="50" y1="5" y2="29" />
        <line x1="75" x2="75" y1="5" y2="29" />
      </g>
      <path :if={@spark_values != []} class="sr-ops-sparkline-area" d={@area_path} />
      <path :if={@spark_values != []} class="sr-ops-sparkline-line" d={@line_path} />
    </svg>
    """
  end

  def visible_kpi_cards(kpi_cards, camera_summary, survey_summary) when is_list(kpi_cards) do
    kpi_cards
    |> Enum.reject(fn
      %{title: "Camera Fleet"} -> not camera_panel_visible?(camera_summary)
      %{title: "Wi-Fi Coverage"} -> not survey_panel_visible?(survey_summary)
      _card -> false
    end)
    |> Enum.take(5)
  end

  def visible_kpi_cards(_kpi_cards, _camera_summary, _survey_summary), do: []

  def survey_raster_cell_count(%{raster_cell_count: count}) when is_integer(count), do: count
  def survey_raster_cell_count(_summary), do: 0

  def survey_panel_visible?(summary) do
    survey_raster_cell_count(summary) > 0 or Map.get(summary || %{}, :sample_count, 0) > 0
  end

  def camera_panel_visible?(summary), do: Map.get(summary || %{}, :total, 0) > 0

  def to_int(value) when is_integer(value), do: value
  def to_int(value) when is_float(value), do: round(value)
  def to_int(_value), do: 0

  def to_float(value) when is_float(value), do: value
  def to_float(value) when is_integer(value), do: value * 1.0
  def to_float(_value), do: 0.0

  def clamp_percent(value) do
    value
    |> to_float()
    |> max(0.0)
    |> min(100.0)
  end

  def format_dashboard_percent(value) do
    formatted =
      value
      |> clamp_percent()
      |> Float.round(1)
      |> :erlang.float_to_binary(decimals: 1)

    formatted <> "%"
  end

  def format_compact_count(value) do
    value = to_int(value)

    cond do
      value >= 1_000_000 -> "#{compact_decimal(value / 1_000_000)}M"
      value >= 1_000 -> "#{compact_decimal(value / 1_000)}K"
      true -> Integer.to_string(value)
    end
  end

  def compact_decimal(value) do
    value
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
    |> String.trim_trailing(".0")
  end

  def sparkline_values(values) do
    values
    |> List.wrap()
    |> Enum.map(&sparkline_value/1)
    |> Enum.filter(&is_number/1)
  end

  def sparkline_value(%{value: value}), do: sparkline_value(value)
  def sparkline_value(value) when is_integer(value), do: value * 1.0
  def sparkline_value(value) when is_float(value), do: value
  def sparkline_value(_), do: nil

  def sparkline_line_path(values) do
    values
    |> sparkline_coordinates()
    |> case do
      [] ->
        ""

      [{x, y} | rest] ->
        "M #{x} #{y} " <> Enum.map_join(rest, " ", fn {px, py} -> "L #{px} #{py}" end)
    end
  end

  def sparkline_area_path(values) do
    case sparkline_coordinates(values) do
      [] ->
        ""

      [{x, y} | rest] ->
        top = "M #{x} #{y} " <> Enum.map_join(rest, " ", fn {px, py} -> "L #{px} #{py}" end)
        "#{top} L 100 32 L 0 32 Z"
    end
  end

  def sparkline_coordinates(values) do
    values = sparkline_values(values)
    count = length(values)

    if count == 0 do
      []
    else
      min_value = Enum.min(values)
      max_value = Enum.max(values)
      range = max(max_value - min_value, 1.0)

      values
      |> Enum.with_index()
      |> Enum.map(fn {value, idx} ->
        x = Float.round(idx * 100 / max(count - 1, 1), 2)
        y = Float.round(28 - (value - min_value) / range * 22, 2)
        {x, y}
      end)
    end
  end
end
