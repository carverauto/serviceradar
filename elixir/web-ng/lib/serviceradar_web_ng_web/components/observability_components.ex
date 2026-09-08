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
  import ServiceRadarWebNGWeb.UIComponents

  attr :active_pane, :string, required: true
  attr :active_subsection, :string, default: nil
  attr :tab_link_kind, :string, default: "navigate", values: ~w(navigate patch)
  attr :title, :string, default: "Observability"
  attr :subtitle, :string, default: "Unified view of logs, traces, metrics, and infrastructure signals."
  attr :class, :any, default: nil

  slot :actions

  def observability_chrome(assigns) do
    ~H"""
    <div class={["space-y-4 font-sans", @class]}>
      <div class="flex items-start justify-between gap-4">
        <div class="min-w-0">
          <div class="text-xl font-semibold tracking-tight text-sr-ink">{@title}</div>
          <div class="text-sm leading-relaxed text-sr-muted">{@subtitle}</div>
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
    <div class="rounded-xl border border-sr-line bg-sr-surface p-2">
      <div class="flex flex-wrap gap-2">
        <.query_tab_button
          id="logs"
          label="Logs"
          icon="hero-rectangle-stack"
          active_pane={@active_pane}
          path={~p"/observability/logs"}
          link_kind={@tab_link_kind}
        />
        <.query_tab_button
          id="traces"
          label="Traces"
          icon="hero-clock"
          active_pane={@active_pane}
          path={~p"/observability/traces"}
          link_kind={@tab_link_kind}
        />
        <.query_tab_button
          id="metrics"
          label="Metrics"
          icon="hero-chart-bar"
          active_pane={@active_pane}
          path={~p"/observability/metrics"}
          link_kind={@tab_link_kind}
        />
        <.query_tab_button
          id="events"
          label="Events"
          icon="hero-bell-alert"
          active_pane={@active_pane}
          path={~p"/observability/events"}
          link_kind={@tab_link_kind}
        />
        <.query_tab_button
          id="alerts"
          label="Alerts"
          icon="hero-exclamation-triangle"
          active_pane={@active_pane}
          path={~p"/observability/alerts"}
          link_kind={@tab_link_kind}
        />
        <.navigate_tab_button
          id="health"
          label="Health"
          icon="hero-heart"
          active_pane={@active_pane}
          path={~p"/observability/health"}
        />
        <.query_tab_button
          id="netflows"
          label="Flows"
          icon="hero-arrow-path"
          active_pane={@active_pane}
          path={~p"/observability/netflows"}
          link_kind={@tab_link_kind}
        />
        <.navigate_tab_button
          id="attributed-flows"
          label="Attributed Flows"
          icon="hero-cpu-chip"
          active_pane={@active_pane}
          path={~p"/observability/flows/attributed"}
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
    <div class="rounded-xl border border-sr-line bg-sr-surface p-2">
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
    <.ui_button
      :if={@link_kind == "patch"}
      patch={@path}
      size="sm"
      variant={if(@active?, do: "primary", else: "ghost")}
      active={@active?}
    >
      <.icon name={@icon} class="size-4" />
      {@label}
    </.ui_button>
    <.ui_button
      :if={@link_kind != "patch"}
      navigate={@path}
      size="sm"
      variant={if(@active?, do: "primary", else: "ghost")}
      active={@active?}
    >
      <.icon name={@icon} class="size-4" />
      {@label}
    </.ui_button>
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
    <.ui_button
      navigate={@path}
      size="sm"
      variant={if(@active?, do: "primary", else: "ghost")}
      active={@active?}
    >
      <.icon name={@icon} class="size-4" />
      {@label}
    </.ui_button>
    """
  end

  defp normalize_camera_relay_subsection(nil), do: "operations"
  defp normalize_camera_relay_subsection(""), do: "operations"
  defp normalize_camera_relay_subsection(subsection), do: subsection
end
