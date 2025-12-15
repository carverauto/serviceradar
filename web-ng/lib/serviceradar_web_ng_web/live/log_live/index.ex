defmodule ServiceRadarWebNGWeb.LogLive.Index do
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @default_limit 100
  @max_limit 500

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Logs")
     |> assign(:logs, [])
     |> assign(:limit, @default_limit)
     |> SRQLPage.init("logs", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {:noreply,
     socket
     |> SRQLPage.load_list(params, uri, :logs,
       default_limit: @default_limit,
       max_limit: @max_limit
     )}
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, fallback_path: "/logs")}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "logs")}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "logs")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "logs")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6">
        <.header>
          Logs
          <:subtitle>Showing up to {@limit} log entries.</:subtitle>
          <:actions>
            <.ui_button variant="ghost" size="sm" patch={~p"/logs?#{%{limit: @limit}}"}>
              Reset
            </.ui_button>
            <.ui_button
              variant="ghost"
              size="sm"
              patch={~p"/logs?#{%{q: "in:logs time:last_24h sort:timestamp:desc", limit: @limit}}"}
            >
              Last 24h
            </.ui_button>
            <.ui_button
              variant="ghost"
              size="sm"
              patch={
                ~p"/logs?#{%{q: "in:logs severity_text:(fatal,error,FATAL,ERROR) time:last_24h sort:timestamp:desc", limit: @limit}}"
              }
            >
              Errors
            </.ui_button>
          </:actions>
        </.header>

        <.ui_panel>
          <:header>
            <div class="min-w-0">
              <div class="text-sm font-semibold">Log Stream</div>
              <div class="text-xs text-base-content/70">
                Severity badges, timestamps, and message previews.
              </div>
            </div>
            <div class="shrink-0 flex items-center gap-2">
              <.ui_badge size="sm">{length(Enum.filter(@logs, &is_map/1))} rows</.ui_badge>
            </div>
          </:header>

          <.srql_results_table
            id="logs"
            rows={@logs}
            columns={~w(timestamp severity_text service_name body trace_id span_id)}
            max_columns={7}
            container={false}
            empty_message="No log entries found."
          />
        </.ui_panel>
      </div>
    </Layouts.app>
    """
  end
end
