defmodule ServiceRadarWebNGWeb.ServiceLive.Index.CardGrid do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.ServiceLive.Service

  attr :cards, :any, required: true
  attr :timezone, :string, required: true

  def render(assigns) do
    ~H"""
    <div
      id="service-cards"
      phx-update="stream"
      class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4"
    >
      <div :for={{id, card} <- @cards} id={id}>
        <.card card={card} timezone={@timezone} />
      </div>
    </div>
    """
  end

  attr :card, :map, required: true
  attr :timezone, :string, required: true

  defp card(assigns) do
    ~H"""
    <.link
      navigate={@card.path}
      class={[
        "group block h-full rounded-2xl border border-sr-line bg-sr-surface",
        "p-4 transition hover:-translate-y-0.5 hover:shadow-md"
      ]}
    >
      <div class="flex items-center justify-between">
        <div class="text-[11px] uppercase tracking-wider text-sr-muted">
          {@card.type || "Service"}
        </div>
        <.status_badge available={@card.available} />
      </div>

      <div class="mt-2 text-lg font-semibold tracking-tight">
        {@card.name || "Service"}
      </div>

      <div class="mt-1 text-xs text-sr-muted line-clamp-2">
        {@card.summary || "—"}
      </div>

      <div class="mt-3 flex flex-wrap items-center gap-2 text-[11px] text-sr-muted">
        <.user_time
          id={"#{@card.id}-timestamp"}
          value={@card.timestamp}
          timezone={@timezone}
          style={:full}
          fallback={Map.get(@card, :timestamp_fallback, "—")}
        />
        <span class="text-sr-ink/30">•</span>
        <span>Agent {@card.agent_id || "—"}</span>
      </div>

      <div :if={@card.display != []} class="mt-4 space-y-3">
        <%= for instruction <- @card.display do %>
          {render_compact_widget(instruction)}
        <% end %>
      </div>
    </.link>
    """
  end

  attr :available, :any, default: nil

  defp status_badge(assigns) do
    {label, variant} =
      case Service.normalize_available(assigns.available) do
        true -> {"OK", "success"}
        false -> {"FAIL", "error"}
        _ -> {"—", "ghost"}
      end

    assigns = assigns |> assign(:label, label) |> assign(:variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp render_compact_widget(%{"widget" => "stat_card"} = data) do
    assigns = %{
      label: Map.get(data, "label") || "Value",
      value: Map.get(data, "value") || "—",
      tone: Map.get(data, "tone") || Map.get(data, "color") || "neutral"
    }

    ~H"""
    <div class="rounded-lg border border-sr-line/60 bg-sr-subtle/40 p-3">
      <div class="text-[11px] text-sr-muted">{@label}</div>
      <div class={stat_value_class(@tone)}>{@value}</div>
    </div>
    """
  end

  defp render_compact_widget(%{"widget" => "sparkline"} = data) do
    assigns = %{
      points: sparkline_points(Map.get(data, "data")),
      label: Map.get(data, "label") || "Trend"
    }

    ~H"""
    <div class="rounded-lg border border-sr-line/60 bg-sr-subtle/40 p-3">
      <div class="text-[11px] text-sr-muted mb-2">{@label}</div>
      <svg viewBox="0 0 100 32" class="w-full h-8 text-sr-brand">
        <polyline fill="none" stroke="currentColor" stroke-width="2" points={@points} />
      </svg>
    </div>
    """
  end

  defp render_compact_widget(_instruction), do: nil

  defp sparkline_points(values) when is_list(values) and values != [] do
    numbers = values |> Enum.map(&to_float/1) |> Enum.reject(&is_nil/1)

    case numbers do
      [] ->
        ""

      _ ->
        min = Enum.min(numbers)
        max = Enum.max(numbers)
        range = if max - min == 0, do: 1.0, else: max - min
        step = 100 / max(Enum.count(numbers) - 1, 1)

        numbers
        |> Enum.with_index()
        |> Enum.map_join(" ", fn {value, index} ->
          x = index * step
          y = 32 - (value - min) / range * 28 - 2
          "#{Float.round(x, 2)},#{Float.round(y, 2)}"
        end)
    end
  end

  defp sparkline_points(_values), do: ""

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0

  defp to_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp to_float(_value), do: nil

  defp stat_value_class(tone) do
    base = "text-lg font-semibold"

    case tone do
      "success" -> [base, "text-success"]
      "warning" -> [base, "text-warning"]
      "error" -> [base, "text-error"]
      "info" -> [base, "text-info"]
      _ -> [base, "text-sr-ink"]
    end
  end
end
