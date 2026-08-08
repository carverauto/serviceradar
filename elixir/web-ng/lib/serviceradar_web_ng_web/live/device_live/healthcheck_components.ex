defmodule ServiceRadarWebNGWeb.DeviceLive.HealthcheckComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  # ---------------------------------------------------------------------------
  # Healthcheck Section (GRPC/Service Health)
  # ---------------------------------------------------------------------------

  attr(:summary, :map, required: true)

  def healthcheck_section(assigns) do
    services = Map.get(assigns.summary, :services, [])
    total = Map.get(assigns.summary, :total, 0)
    available = Map.get(assigns.summary, :available, 0)
    unavailable = Map.get(assigns.summary, :unavailable, 0)
    uptime_pct = if total > 0, do: Float.round(available / total * 100.0, 1), else: 0.0

    assigns =
      assigns
      |> assign(:services, services)
      |> assign(:total, total)
      |> assign(:available, available)
      |> assign(:unavailable, unavailable)
      |> assign(:uptime_pct, uptime_pct)

    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line flex items-center justify-between">
        <span class="text-sm font-semibold">Service Health (GRPC)</span>
        <div class="flex items-center gap-4 text-sm">
          <div class="flex items-center gap-2">
            <span class="w-2 h-2 rounded-full bg-success"></span>
            <span class="tabular-nums">{@available}</span>
            <span class="text-sr-muted text-xs">healthy</span>
          </div>
          <div class="flex items-center gap-2">
            <span class="w-2 h-2 rounded-full bg-error"></span>
            <span class="tabular-nums">{@unavailable}</span>
            <span class="text-sr-muted text-xs">unhealthy</span>
          </div>
        </div>
      </div>

      <div class="p-4">
        <div :if={@services == []} class="text-sm text-sr-muted">
          No service health data available.
        </div>

        <div :if={@services != []} class="space-y-2">
          <%= for svc <- Enum.take(@services, 10) do %>
            <.healthcheck_row service={svc} />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr(:service, :map, required: true)

  defp healthcheck_row(assigns) do
    svc = assigns.service
    available = Map.get(svc, :available, false)
    service_name = Map.get(svc, :service_name, "Unknown")
    service_type = Map.get(svc, :service_type, "")
    message = Map.get(svc, :message, "")
    timestamp = Map.get(svc, :timestamp, "")

    assigns =
      assigns
      |> assign(:available, available)
      |> assign(:service_name, service_name)
      |> assign(:service_type, service_type)
      |> assign(:message, message)
      |> assign(:timestamp, timestamp)

    ~H"""
    <div class="flex items-center gap-3 p-2 rounded-lg bg-sr-subtle/30">
      <div class={["w-2.5 h-2.5 rounded-full shrink-0", (@available && "bg-success") || "bg-error"]} />
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2">
          <span class="text-sm font-medium truncate">{@service_name}</span>
          <span
            :if={@service_type != ""}
            class="text-xs text-sr-muted px-1.5 py-0.5 rounded bg-sr-subtle"
          >
            {@service_type}
          </span>
        </div>
        <div :if={@message != ""} class="text-xs text-sr-muted truncate">{@message}</div>
      </div>
      <div class="text-xs text-sr-muted shrink-0 font-mono">
        {format_healthcheck_time(@timestamp)}
      </div>
    </div>
    """
  end

  defp format_healthcheck_time(nil), do: ""
  defp format_healthcheck_time(""), do: ""

  defp format_healthcheck_time(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> ts
    end
  end

  defp format_healthcheck_time(_), do: ""
end
