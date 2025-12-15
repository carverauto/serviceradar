defmodule ServiceRadarWebNGWeb.ServiceLive.Index do
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @default_limit 100
  @max_limit 500

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Services")
     |> assign(:services, [])
     |> assign(:limit, @default_limit)
     |> SRQLPage.init("services", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {:noreply,
     socket
     |> SRQLPage.load_list(params, uri, :services,
       default_limit: @default_limit,
       max_limit: @max_limit
     )}
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, fallback_path: "/services")}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "services")}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "services")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "services")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6">
        <.header>
          Services
          <:subtitle>Showing up to {@limit} services.</:subtitle>
          <:actions>
            <.ui_button variant="ghost" size="sm" patch={~p"/services?#{%{limit: @limit}}"}>
              Reset
            </.ui_button>
            <.ui_button
              variant="ghost"
              size="sm"
              patch={
                ~p"/services?#{%{q: "in:services time:last_24h sort:timestamp:desc", limit: @limit}}"
              }
            >
              Last 24h
            </.ui_button>
            <.ui_button
              variant="ghost"
              size="sm"
              patch={
                ~p"/services?#{%{q: "in:services available:false time:last_24h sort:timestamp:desc", limit: @limit}}"
              }
            >
              Unavailable
            </.ui_button>
          </:actions>
        </.header>

        <.ui_panel>
          <:header>
            <div class="min-w-0">
              <div class="text-sm font-semibold">Service Status</div>
              <div class="text-xs text-base-content/70">
                Availability and recent status messages.
              </div>
            </div>
            <div class="shrink-0 flex items-center gap-2">
              <.ui_badge size="sm">{length(Enum.filter(@services, &is_map/1))} rows</.ui_badge>
            </div>
          </:header>

          <.srql_results_table
            id="services"
            rows={@services}
            columns={
              ~w(timestamp available service_type service_name message device_id poller_id agent_id)
            }
            max_columns={8}
            container={false}
            empty_message="No services found."
          />
        </.ui_panel>
      </div>
    </Layouts.app>
    """
  end
end
