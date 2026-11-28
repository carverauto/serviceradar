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
    assigns = assign(assigns, :tone, chart_tone(assigns.tone))

    ~H"""
    <ServiceRadarUI.Charts.sparkline values={@values} tone={@tone} class={@class} />
    """
  end

  # Dashboard tones include names the package chart does not (error, violet).
  defp chart_tone(tone) when is_atom(tone) and not is_nil(tone) do
    tone |> Atom.to_string() |> chart_tone()
  end

  defp chart_tone(tone) when tone in ~w(brand success warning danger info neutral), do: tone
  defp chart_tone(tone) when tone in ~w(error critical fatal destructive), do: "danger"
  defp chart_tone(tone) when tone in ~w(warn degraded), do: "warning"
  defp chart_tone(tone) when tone in ~w(ok healthy up), do: "success"
  defp chart_tone("primary"), do: "brand"
  defp chart_tone(_tone), do: "neutral"

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
end
