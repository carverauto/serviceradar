defmodule ServiceRadarWebNGWeb.DashboardLive.Index do
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNGWeb.Dashboard.Engine
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @default_limit 100
  @max_limit 500

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:results, [])
     |> assign(:panels, [])
     |> assign(:limit, @default_limit)
     |> SRQLPage.init("cpu_metrics", default_limit: @default_limit, builder_available: true)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket =
      SRQLPage.load_list(socket, params, uri, :results,
        default_limit: @default_limit,
        max_limit: @max_limit
      )

    srql_response = %{
      "results" => socket.assigns.results,
      "viz" => get_in(socket.assigns, [:srql, :viz])
    }

    {:noreply, assign(socket, :panels, Engine.build_panels(srql_response))}
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, fallback_path: "/dashboard")}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "cpu_metrics")}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_run", _params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_run", %{}, fallback_path: "/dashboard")}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "cpu_metrics")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "cpu_metrics")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6">
        <.header>
          Dashboard
          <:subtitle>Auto-generated panels based on your SRQL query.</:subtitle>
          <:actions>
            <.ui_dropdown>
              <:trigger>
                <.ui_icon_button aria-label="Dashboard actions" title="Dashboard actions">
                  <.icon name="hero-ellipsis-horizontal" class="size-4" />
                </.ui_icon_button>
              </:trigger>
              <:item>
                <button type="button" class="w-full text-left opacity-60 cursor-not-allowed">
                  Save dashboard (soon)
                </button>
              </:item>
              <:item>
                <button type="button" class="w-full text-left opacity-60 cursor-not-allowed">
                  Add panel (soon)
                </button>
              </:item>
            </.ui_dropdown>
          </:actions>
        </.header>

        <div class="grid grid-cols-1 gap-6">
          <%= for panel <- @panels do %>
            <.live_component
              module={panel.plugin}
              id={panel.id}
              title={panel.title}
              panel_assigns={panel.assigns}
            />
          <% end %>

          <.srql_results_table id="dashboard-results" rows={@results} empty_message="No results." />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
