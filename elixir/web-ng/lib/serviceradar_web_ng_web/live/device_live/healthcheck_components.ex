defmodule ServiceRadarWebNGWeb.DeviceLive.HealthcheckComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  # ---------------------------------------------------------------------------
  # Healthcheck Section (GRPC/Service Health)
  # ---------------------------------------------------------------------------

  attr(:summary, :map, required: true)
  attr(:timezone, :string, default: "Etc/UTC")

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
          <%= for {svc, index} <- Enum.with_index(Enum.take(@services, 10)) do %>
            <.healthcheck_row service={svc} index={index} timezone={@timezone} />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr(:service, :map, required: true)
  attr(:index, :integer, required: true)
  attr(:timezone, :string, required: true)

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
        <.user_time
          id={"device-healthcheck-#{healthcheck_time_key(@service, @index)}-timestamp"}
          value={@timestamp}
          timezone={@timezone}
          style={:time}
          fallback=""
        />
      </div>
    </div>
    """
  end

  defp healthcheck_time_key(service, index) do
    [
      Map.get(service, :id) || Map.get(service, "id"),
      Map.get(service, :service_id) || Map.get(service, "service_id"),
      Map.get(service, :uid) || Map.get(service, "uid"),
      Map.get(service, :service_name) || Map.get(service, "service_name"),
      Map.get(service, :service_type) || Map.get(service, "service_type")
    ]
    |> Enum.find_value(&healthcheck_id_fragment/1)
    |> Kernel.||(Integer.to_string(index))
  end

  defp healthcheck_id_fragment(value) when value in [nil, ""], do: nil

  defp healthcheck_id_fragment(value) do
    case value |> to_string() |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-") |> String.trim("-") do
      "" -> nil
      fragment -> fragment
    end
  end
end
