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
     |> SRQLPage.init("services", default_limit: @default_limit, builder_available: false)}
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
  def handle_event("srql_change", %{"q" => query}, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", %{"q" => query})}
  end

  def handle_event("srql_submit", %{"q" => raw_query}, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_submit", %{"q" => raw_query}, fallback_path: "/services")}
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
            <.link class="btn btn-ghost btn-sm" patch={~p"/services?limit=#{@limit}"}>
              Reset
            </.link>
          </:actions>
        </.header>

        <.srql_results_table id="services" rows={@services} empty_message="No services found." />
      </div>
    </Layouts.app>
    """
  end
end
