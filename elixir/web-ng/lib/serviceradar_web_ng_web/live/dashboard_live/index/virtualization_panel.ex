defmodule ServiceRadarWebNGWeb.DashboardLive.Index.VirtualizationPanel do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DashboardLive.Index.Common

  alias ServiceRadarWebNGWeb.DashboardLive.Index.Common

  attr(:dashboard, :map, required: true)

  def render(%{dashboard: dashboard} = assigns) do
    assigns = Map.merge(assigns, dashboard)

    ~H"""
    <Common.panel title="Virtualization Efficiency">
      <:actions>
        <span class={[
          "sr-ops-virt-status",
          virtualization_status_class(@virtualization_summary.status_tone)
        ]}>
          {@virtualization_summary.status_label}
        </span>
      </:actions>
      <div class="sr-ops-virtualization" data-testid="virtualization-efficiency">
        <div :if={!@virtualization_summary.available} class="sr-ops-virt-empty">
          <.icon name="hero-cube-transparent" class="size-8 text-slate-500" />
          <p>No hypervisor inventory</p>
          <span>Hypervisor enrichment will populate this panel.</span>
        </div>

        <div :if={@virtualization_summary.available} class="sr-ops-virt-body">
          <div class="sr-ops-virt-summary">
            <.link
              navigate={virt_devices_href(:hosts)}
              class="sr-ops-virt-summary-link"
              aria-label="Open hypervisor devices"
            >
              <span>{@virtualization_summary.provider_label}</span>
              <strong>
                {format_compact_count(@virtualization_summary.host_count)} hosts
              </strong>
            </.link>
            <.link
              navigate={virt_devices_href(:guests)}
              class="sr-ops-virt-summary-link"
              aria-label="Open virtual guest devices"
            >
              <span>Guests</span>
              <strong>
                {format_compact_count(@virtualization_summary.guest_count)}
              </strong>
            </.link>
            <.link
              navigate={virt_devices_href(:running)}
              class="sr-ops-virt-summary-link"
              aria-label="Open running virtual guest devices"
            >
              <span>Running</span>
              <strong>
                {format_compact_count(@virtualization_summary.running_guests)}
              </strong>
            </.link>
            <a
              href="#virtualization-pressure-details"
              class="sr-ops-virt-summary-link"
              aria-label="Show virtualization pressure sources"
            >
              <span>Pressure</span>
              <strong>
                {format_compact_count(@virtualization_summary.bottleneck_count)}
              </strong>
            </a>
          </div>

          <div class="sr-ops-virt-pressure-list">
            <.virtualization_pressure_row
              label="Host CPU"
              value={@virtualization_summary.max_host_cpu_pct}
            />
            <.virtualization_pressure_row
              label="Host Memory"
              value={@virtualization_summary.max_host_memory_pct}
            />
            <.virtualization_pressure_row
              label="Guest CPU"
              value={@virtualization_summary.max_guest_cpu_pct}
            />
            <.virtualization_pressure_row
              label="Datastore"
              value={@virtualization_summary.max_datastore_pct}
            />
          </div>

          <details
            :if={@virtualization_summary.pressure_items != []}
            id="virtualization-pressure-details"
            class="sr-ops-virt-pressure-details"
          >
            <summary>Pressure sources</summary>
            <div class="sr-ops-virt-pressure-sources">
              <.link
                :for={item <- @virtualization_summary.pressure_items}
                href={item.href || "#virtualization-pressure-details"}
                class={[
                  "sr-ops-virt-pressure-source",
                  !is_binary(item.href) && "is-static"
                ]}
              >
                <span>
                  <em>{item.metric}</em>
                  <strong>{item.label}</strong>
                </span>
                <b>{item.value_label}</b>
              </.link>
            </div>
          </details>

          <div class="sr-ops-virt-footer">
            <span>
              {format_compact_count(@virtualization_summary.datastore_count)} datastores
            </span>
            <strong>{@virtualization_summary.ceph_health_label}</strong>
          </div>
        </div>
      </div>
    </Common.panel>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)

  defp virtualization_pressure_row(assigns) do
    value = clamp_percent(assigns.value)

    assigns =
      assigns
      |> assign(:value, value)
      |> assign(:value_label, format_dashboard_percent(value))
      |> assign(:bar_style, "width: #{Float.round(value, 1)}%;")
      |> assign(:tone_class, virtualization_pressure_class(value))

    ~H"""
    <div class={["sr-ops-virt-pressure-row", @tone_class]}>
      <div>
        <span>{@label}</span>
        <strong>{@value_label}</strong>
      </div>
      <i><b style={@bar_style}></b></i>
    </div>
    """
  end

  defp virtualization_pressure_class(value) when value >= 90.0, do: "is-critical"
  defp virtualization_pressure_class(value) when value >= 75.0, do: "is-warning"
  defp virtualization_pressure_class(_value), do: "is-ok"

  defp virtualization_status_class("error"), do: "is-error"
  defp virtualization_status_class("warning"), do: "is-warning"
  defp virtualization_status_class("ok"), do: "is-ok"
  defp virtualization_status_class(_), do: "is-idle"

  # Summary tiles deep-link into /devices with an SRQL inventory filter so operators
  # can jump from the ops dashboard straight into the matching device list.
  defp virt_devices_href(:hosts), do: ~p"/devices?#{%{q: ~s(in:devices type:"Hypervisor")}}"

  defp virt_devices_href(:guests), do: ~p"/devices?#{%{q: ~s(in:devices type:"Virtual")}}"

  # Guest power state lives on virtualization_guests; inventory uses availability as
  # the closest durable signal for "running" VMs/LXCs on the devices index.
  defp virt_devices_href(:running), do: ~p"/devices?#{%{q: ~s(in:devices type:"Virtual" is_available:true)}}"
end
