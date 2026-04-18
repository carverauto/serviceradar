defmodule ServiceRadarWebNGWeb.ObservabilityComponents do
  @moduledoc """
  Shared observability shell components.
  """

  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: ServiceRadarWebNGWeb.Endpoint,
    router: ServiceRadarWebNGWeb.Router,
    statics: ServiceRadarWebNGWeb.static_paths()

  import ServiceRadarWebNGWeb.CoreComponents, only: [icon: 1]

  attr :active_pane, :string, required: true
  attr :active_subsection, :string, default: nil
  attr :tab_link_kind, :string, default: "navigate", values: ~w(navigate patch)
  attr :title, :string, default: "Observability"
  attr :subtitle, :string, default: "Unified view of logs, traces, metrics, and infrastructure signals."
  attr :class, :any, default: nil

  slot :actions

  def observability_chrome(assigns) do
    ~H"""
    <div class={["space-y-4", @class]}>
      <div class="flex items-start justify-between gap-4">
        <div class="min-w-0">
          <div class="text-xl font-semibold">{@title}</div>
          <div class="text-sm text-base-content/60">{@subtitle}</div>
        </div>

        <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
          {render_slot(@actions)}
        </div>
      </div>

      <.observability_tabs active_pane={@active_pane} tab_link_kind={@tab_link_kind} />
      <.camera_relay_subtabs
        :if={@active_pane == "camera-relays"}
        active_subsection={@active_subsection}
      />
    </div>
    """
  end

  attr :active_pane, :string, required: true
  attr :tab_link_kind, :string, default: "navigate", values: ~w(navigate patch)

  def observability_tabs(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 p-2">
      <div class="flex flex-wrap gap-2">
        <.query_tab_button
          id="logs"
          label="Logs"
          icon="hero-rectangle-stack"
          active_pane={@active_pane}
          path={~p"/observability?#{%{tab: "logs"}}"}
          link_kind={@tab_link_kind}
        />
        <.query_tab_button
          id="traces"
          label="Traces"
          icon="hero-clock"
          active_pane={@active_pane}
          path={~p"/observability?#{%{tab: "traces"}}"}
          link_kind={@tab_link_kind}
        />
        <.query_tab_button
          id="metrics"
          label="Metrics"
          icon="hero-chart-bar"
          active_pane={@active_pane}
          path={~p"/observability?#{%{tab: "metrics"}}"}
          link_kind={@tab_link_kind}
        />
        <.query_tab_button
          id="events"
          label="Events"
          icon="hero-bell-alert"
          active_pane={@active_pane}
          path={~p"/observability?#{%{tab: "events"}}"}
          link_kind={@tab_link_kind}
        />
        <.query_tab_button
          id="alerts"
          label="Alerts"
          icon="hero-exclamation-triangle"
          active_pane={@active_pane}
          path={~p"/observability?#{%{tab: "alerts"}}"}
          link_kind={@tab_link_kind}
        />
        <.query_tab_button
          id="netflows"
          label="Flows"
          icon="hero-arrow-path"
          active_pane={@active_pane}
          path={~p"/observability?#{%{tab: "netflows"}}"}
          link_kind={@tab_link_kind}
        />
        <.navigate_tab_button
          id="bmp"
          label="BMP"
          icon="hero-arrows-right-left"
          active_pane={@active_pane}
          path={~p"/observability/bmp"}
        />
        <.navigate_tab_button
          id="bgp"
          label="BGP Routing"
          icon="hero-globe-alt"
          active_pane={@active_pane}
          path={~p"/observability/bgp"}
        />
        <.navigate_tab_button
          id="camera-relays"
          label="Camera Relays"
          icon="hero-video-camera"
          active_pane={@active_pane}
          path={~p"/observability/camera-relays"}
        />
      </div>
    </div>
    """
  end

  attr :active_subsection, :string, default: nil

  def camera_relay_subtabs(assigns) do
    active_subsection = normalize_camera_relay_subsection(assigns.active_subsection)
    assigns = assign(assigns, :active_subsection, active_subsection)

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 p-2">
      <div class="flex flex-wrap gap-2">
        <.navigate_tab_button
          id="operations"
          label="Operations"
          icon="hero-video-camera"
          active_pane={@active_subsection}
          path={~p"/observability/camera-relays"}
        />
        <.navigate_tab_button
          id="analysis-workers"
          label="Analysis Workers"
          icon="hero-cpu-chip"
          active_pane={@active_subsection}
          path={~p"/observability/camera-relays/workers"}
        />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :active_pane, :string, required: true
  attr :path, :string, required: true
  attr :link_kind, :string, default: "navigate", values: ~w(navigate patch)

  defp query_tab_button(assigns) do
    assigns = assign(assigns, :active?, assigns.active_pane == assigns.id)

    ~H"""
    <.link
      :if={@link_kind == "patch"}
      patch={@path}
      class={tab_button_class(@active?)}
    >
      <.icon name={@icon} class="size-4" />
      {@label}
    </.link>
    <.link
      :if={@link_kind != "patch"}
      navigate={@path}
      class={tab_button_class(@active?)}
    >
      <.icon name={@icon} class="size-4" />
      {@label}
    </.link>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :active_pane, :string, required: true
  attr :path, :string, required: true

  defp navigate_tab_button(assigns) do
    assigns = assign(assigns, :active?, assigns.active_pane == assigns.id)

    ~H"""
    <.link navigate={@path} class={tab_button_class(@active?)}>
      <.icon name={@icon} class="size-4" />
      {@label}
    </.link>
    """
  end

  defp tab_button_class(true), do: "btn btn-sm btn-primary rounded-lg flex items-center gap-2 transition-colors"

  defp tab_button_class(false), do: "btn btn-sm btn-ghost rounded-lg flex items-center gap-2 transition-colors"

  defp normalize_camera_relay_subsection(nil), do: "operations"
  defp normalize_camera_relay_subsection(""), do: "operations"
  defp normalize_camera_relay_subsection(subsection), do: subsection
end
