defmodule ServiceRadarWebNGWeb.PollerLive.Index do
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @default_limit 200
  @max_limit 500

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Pollers")
     |> assign(:pollers, [])
     |> assign(:limit, @default_limit)
     |> SRQLPage.init("pollers", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {:noreply,
     socket
     |> SRQLPage.load_list(params, uri, :pollers,
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
     SRQLPage.handle_event(socket, "srql_submit", %{"q" => raw_query}, fallback_path: "/pollers")}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "pollers")}
  end

  def handle_event("srql_builder_change", %{"builder" => params}, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", %{"builder" => params})}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "pollers")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "pollers")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6">
        <.header>
          Pollers
          <:subtitle>Showing up to {@limit} pollers.</:subtitle>
          <:actions>
            <.link class="btn btn-ghost btn-sm" patch={~p"/pollers?limit=#{@limit}"}>
              Reset
            </.link>
          </:actions>
        </.header>

        <.srql_results_table id="pollers" rows={@pollers} empty_message="No pollers found." />
      </div>
    </Layouts.app>
    """
  end
end
