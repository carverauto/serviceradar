defmodule ServiceRadarWebNGWeb.DeviceLive.Index do
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @default_limit 100
  @max_limit 500

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Devices")
     |> assign(:devices, [])
     |> assign(:limit, @default_limit)
     |> SRQLPage.init("devices", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {:noreply,
     socket
     |> SRQLPage.load_list(params, uri, :devices,
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
     SRQLPage.handle_event(socket, "srql_submit", %{"q" => raw_query}, fallback_path: "/devices")}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "devices")}
  end

  def handle_event("srql_builder_change", %{"builder" => params}, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", %{"builder" => params})}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "devices")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "devices")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6">
        <.header>
          Devices
          <:subtitle>Showing up to {@limit} devices.</:subtitle>
          <:actions>
            <.link class="btn btn-ghost btn-sm" patch={~p"/devices?limit=#{@limit}"}>
              Reset
            </.link>
          </:actions>
        </.header>

        <.srql_results_table id="devices" rows={@devices} empty_message="No devices found." />
      </div>
    </Layouts.app>
    """
  end
end
