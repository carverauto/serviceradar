defmodule ServiceRadarWebNGWeb.PluginResults do
  @moduledoc false

  use Phoenix.Component

  require Logger

  import Phoenix.HTML, only: [raw: 1]
  import ServiceRadarWebNGWeb.UIComponents

  attr :display, :list, default: []
  attr :fallback, :map, default: %{}

  def plugin_results(assigns) do
    assigns = assign(assigns, :display, normalize_display(assigns.display))

    ~H"""
    <div class="space-y-4">
      <div :if={@display == []} class="text-xs text-base-content/60">
        No custom display instructions found for this result.
      </div>

      <div :if={@display != []} class="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <%= for instruction <- @display do %>
          <div class={widget_container_class(instruction)}>
            {render_widget(instruction)}
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp normalize_display(display) when is_list(display) do
    Enum.reduce(display, [], fn item, acc ->
      cond do
        is_map(item) and supported_widget?(item) ->
          [stringify_keys(item) | acc]

        is_map(item) ->
          Logger.warning(
            "Unsupported plugin widget: #{inspect(Map.get(item, "widget") || Map.get(item, :widget))}"
          )

          acc

        true ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp normalize_display(_), do: []

  defp supported_widget?(%{"widget" => widget}) when is_binary(widget),
    do: widget in supported_widgets()

  defp supported_widget?(%{widget: widget}) when is_binary(widget),
    do: widget in supported_widgets()

  defp supported_widget?(_), do: false

  defp supported_widgets do
    ["status_badge", "stat_card", "table", "markdown", "sparkline"]
  end

  defp widget_container_class(instruction) do
    layout = Map.get(instruction, "layout") || Map.get(instruction, :layout)

    base = "rounded-xl border border-base-200 bg-base-100 p-4 shadow-sm"

    case layout do
      "full" -> [base, "lg:col-span-2"]
      "half" -> base
      _ -> base
    end
  end

  defp render_widget(%{"widget" => "status_badge"} = data) do
    label = Map.get(data, "label") || "Status"
    status = Map.get(data, "status") || Map.get(data, "value") || "UNKNOWN"
    uptime = Map.get(data, "uptime")

    assigns = %{label: label, status: status, uptime: uptime}

    ~H"""
    <div class="flex items-center justify-between">
      <div>
        <div class="text-xs text-base-content/60">{@label}</div>
        <div class="text-sm font-semibold">{@status}</div>
      </div>
      <div class="flex items-center gap-2">
        <.ui_badge variant={status_variant(@status)} size="xs">{@status}</.ui_badge>
        <span :if={@uptime} class="text-xs text-base-content/60">{@uptime}</span>
      </div>
    </div>
    """
  end

  defp render_widget(%{"widget" => "stat_card"} = data) do
    label = Map.get(data, "label") || "Value"
    value = Map.get(data, "value") || "—"
    tone = Map.get(data, "tone") || Map.get(data, "color") || "neutral"

    assigns = %{label: label, value: value, tone: tone}

    ~H"""
    <div>
      <div class="text-xs text-base-content/60">{@label}</div>
      <div class={stat_value_class(@tone)}>{@value}</div>
    </div>
    """
  end

  defp render_widget(%{"widget" => "table"} = data) do
    rows = normalize_table_rows(data)

    assigns = assign(data, :rows, rows)

    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-sm w-full">
        <tbody>
          <%= for {key, value} <- @rows do %>
            <tr>
              <td class="text-xs font-semibold text-base-content/60">{key}</td>
              <td class="text-xs">{value}</td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  defp render_widget(%{"widget" => "markdown"} = data) do
    content = Map.get(data, "content") || ""
    html = markdown_to_html(content)
    assigns = %{html: html}

    ~H"""
    <div class="prose prose-sm max-w-none">
      {raw(@html)}
    </div>
    """
  end

  defp render_widget(%{"widget" => "sparkline"} = data) do
    points = sparkline_points(Map.get(data, "data"))
    label = Map.get(data, "label") || "Trend"
    assigns = %{points: points, label: label}

    ~H"""
    <div>
      <div class="text-xs text-base-content/60 mb-2">{@label}</div>
      <svg viewBox="0 0 100 32" class="w-full h-8">
        <polyline
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          class="text-primary"
          points={@points}
        />
      </svg>
    </div>
    """
  end

  defp render_widget(_), do: nil

  defp normalize_table_rows(%{"rows" => rows}) when is_list(rows) do
    Enum.map(rows, fn
      %{"key" => key, "value" => value} -> {to_string(key), format_value(value)}
      %{:key => key, :value => value} -> {to_string(key), format_value(value)}
      _ -> {"", ""}
    end)
    |> Enum.reject(fn {key, _} -> key == "" end)
  end

  defp normalize_table_rows(%{"data" => data}) when is_map(data) do
    data
    |> Enum.map(fn {key, value} -> {to_string(key), format_value(value)} end)
  end

  defp normalize_table_rows(_), do: []

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_number(value), do: to_string(value)
  defp format_value(value) when is_boolean(value), do: to_string(value)
  defp format_value(value) when is_map(value), do: Jason.encode!(value)
  defp format_value(value) when is_list(value), do: Jason.encode!(value)
  defp format_value(value), do: inspect(value)

  defp sparkline_points(values) when is_list(values) and values != [] do
    numbers =
      values
      |> Enum.map(&to_float/1)
      |> Enum.reject(&is_nil/1)

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
        |> Enum.map_join(" ", fn {value, idx} ->
          x = idx * step
          y = 32 - (value - min) / range * 28 - 2
          "#{Float.round(x, 2)},#{Float.round(y, 2)}"
        end)
    end
  end

  defp sparkline_points(_), do: ""

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0

  defp to_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {num, ""} -> num
      _ -> nil
    end
  end

  defp to_float(_), do: nil

  defp markdown_to_html(content) do
    content = to_string(content || "")
    escaped = content |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
    opts = %Earmark.Options{gfm: true, breaks: true, smartypants: false, escape: true}

    case Earmark.as_html(escaped, opts) do
      {:ok, html, _} -> html
      {:error, html, _} -> html
    end
  end

  defp status_variant(status) do
    case String.upcase(to_string(status)) do
      "OK" -> "success"
      "WARNING" -> "warning"
      "CRITICAL" -> "error"
      "FAIL" -> "error"
      _ -> "ghost"
    end
  end

  defp stat_value_class(tone) do
    base = "text-2xl font-semibold"

    case tone do
      "success" -> [base, "text-success"]
      "warning" -> [base, "text-warning"]
      "error" -> [base, "text-error"]
      "info" -> [base, "text-info"]
      _ -> [base, "text-base-content"]
    end
  end

  defp stringify_keys(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), stringify_keys(value)} end)
    |> Map.new()
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
