defmodule ServiceRadarWebNGWeb.Observability.SignalDisplayComponents do
  @moduledoc false
  use Phoenix.Component

  import ServiceRadarWebNGWeb.UIComponents

  attr(:widgets, :list, required: true)

  def signal_display_panel(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 p-6 space-y-5">
      <span class="text-xs text-base-content/50 uppercase tracking-wider block">
        Signal Details
      </span>

      <%= for widget <- @widgets do %>
        <.signal_display_widget widget={widget} />
      <% end %>
    </div>
    """
  end

  attr(:widget, :map, required: true)

  def signal_display_widget(%{widget: %{type: :summary}} = assigns) do
    ~H"""
    <div class="space-y-2">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <h2 class="text-lg font-semibold leading-tight">{@widget.title || "Signal event"}</h2>
        <.signal_severity_badge value={@widget.severity} />
      </div>
      <p :if={@widget.message} class="text-sm text-base-content/80 whitespace-pre-wrap">
        {@widget.message}
      </p>
      <p :if={@widget.source} class="text-xs text-base-content/50">
        Source: <span class="font-mono">{@widget.source}</span>
      </p>
    </div>
    """
  end

  def signal_display_widget(%{widget: %{type: :badges}} = assigns) do
    ~H"""
    <div class="flex flex-wrap gap-2">
      <.ui_badge :for={field <- @widget.fields} variant={signal_badge_variant(field)} size="sm">
        {field.label}: {field.value}
      </.ui_badge>
    </div>
    """
  end

  def signal_display_widget(%{widget: %{type: type}} = assigns) when type in [:facts, :timeline] do
    assigns = assign(assigns, :heading, if(type == :timeline, do: "Timeline", else: "Facts"))

    ~H"""
    <div>
      <span class="text-xs text-base-content/50 uppercase tracking-wider block mb-3">
        {@heading}
      </span>
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-3">
        <div :for={field <- @widget.fields} class="flex flex-col gap-0.5 min-w-0">
          <span class="text-xs text-base-content/50">{field.label}</span>
          <.link
            :if={Map.get(field, :href)}
            navigate={field.href}
            class="link link-primary text-sm break-words"
            aria-label={"View device for #{field.label} #{field.value}"}
          >
            {field.value}
          </.link>
          <span :if={!Map.get(field, :href)} class="text-sm break-words">{field.value}</span>
        </div>
      </div>
    </div>
    """
  end

  def signal_display_widget(%{widget: %{type: :json_section}} = assigns) do
    ~H"""
    <div>
      <span class="text-xs text-base-content/50 uppercase tracking-wider block mb-3">
        {@widget.title || "JSON"}
      </span>
      <div class="space-y-3">
        <details :for={section <- @widget.sections} class="rounded-lg border border-base-200 p-3">
          <summary class="cursor-pointer text-xs font-mono text-base-content/70">
            {section.path}
          </summary>
          <pre class="mt-3 text-xs font-mono bg-base-200/30 p-2 rounded overflow-x-auto max-h-48">{section.json}</pre>
        </details>
      </div>
    </div>
    """
  end

  def signal_display_widget(%{widget: %{type: :table}} = assigns) do
    ~H"""
    <div>
      <span class="text-xs text-base-content/50 uppercase tracking-wider block mb-3">
        {@widget.title || "Rows"}
      </span>
      <div class="max-w-full overflow-x-auto rounded-lg border border-base-200">
        <table class="table table-sm">
          <thead>
            <tr>
              <th :for={column <- @widget.columns}>{column.label}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @widget.rows}>
              <td :for={cell <- row.values} class="max-w-sm align-top">
                <span class="line-clamp-3 break-words">{cell.value}</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  def signal_display_widget(assigns), do: ~H""

  attr(:value, :any, default: nil)

  defp signal_severity_badge(assigns) do
    variant = severity_variant(assigns.value)
    label = severity_label(assigns.value)

    assigns = assigns |> assign(:variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="sm">{@label}</.ui_badge>
    """
  end

  defp severity_variant(value) do
    case normalize_value(value) do
      value when value in ["critical", "fatal", "error"] -> "error"
      value when value in ["high", "warn", "warning"] -> "warning"
      value when value in ["medium", "info"] -> "info"
      value when value in ["low", "debug", "ok"] -> "success"
      _ -> "ghost"
    end
  end

  defp severity_label(nil), do: "—"
  defp severity_label(""), do: "—"
  defp severity_label(value) when is_binary(value), do: value
  defp severity_label(value), do: to_string(value)

  defp signal_badge_variant(%{tone: "severity", value: value}), do: severity_variant(value)
  defp signal_badge_variant(%{tone: "status", value: value}), do: status_variant(value)
  defp signal_badge_variant(%{tone: "success"}), do: "success"
  defp signal_badge_variant(%{tone: "warning"}), do: "warning"
  defp signal_badge_variant(%{tone: "error"}), do: "error"
  defp signal_badge_variant(%{tone: "info"}), do: "info"
  defp signal_badge_variant(_field), do: "ghost"

  defp status_variant(value) do
    case normalize_value(value) do
      status when status in ["success", "allowed", "ok"] -> "success"
      status when status in ["failure", "blocked", "denied", "error"] -> "error"
      status when status in ["warning", "warn"] -> "warning"
      _ -> "ghost"
    end
  end

  defp normalize_value(nil), do: ""
  defp normalize_value(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_value(value), do: value |> to_string() |> normalize_value()
end
