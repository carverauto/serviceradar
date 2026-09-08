defmodule ServiceRadarWebNGWeb.DiagnosticsLive.Mtr do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Observability.MtrPubSub
  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.Config
  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.Events
  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.Loader
  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.Params
  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.View
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @impl true
  def mount(_params, _session, socket) do
    default_limit = Params.default_page_size()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "agent:commands")
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, MtrPubSub.topic())
    end

    {:ok,
     socket
     |> assign(:page_title, "MTR Diagnostics")
     |> assign(:page_path, "/diagnostics/mtr")
     |> assign(:last_params, %{})
     |> assign(:last_uri, "/diagnostics/mtr")
     |> assign(:traces, [])
     |> assign(:pending_jobs, [])
     |> assign(:bulk_jobs, [])
     |> assign(:limit, default_limit)
     |> assign(:default_limit, default_limit)
     |> assign(:current_page, 1)
     |> assign(:total_count, 0)
     |> assign(:trace_coverage, Config.empty_trace_coverage())
     |> assign(:mtr_retention_status, Config.degraded_retention_status())
     |> assign(:filter_target, "")
     |> assign(:filter_agent, "")
     |> assign(:show_mtr_modal, false)
     |> assign(:mtr_agents, [])
     |> assign(:mtr_form, to_form(Config.default_mtr_form(), as: :mtr))
     |> assign(:mtr_running, false)
     |> assign(:mtr_error, nil)
     |> assign(:mtr_command_id, nil)
     |> assign(:show_bulk_mtr_modal, false)
     |> assign(:bulk_mtr_form, to_form(Config.default_bulk_mtr_form(), as: :bulk_mtr))
     |> assign(:bulk_mtr_error, nil)
     |> assign(:refresh_timer, nil)
     |> SRQLPage.init("mtr_traces", default_limit: default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    default_limit = Map.get(socket.assigns, :default_limit, Config.default_limit())

    socket =
      socket
      |> assign(:last_params, params)
      |> assign(:last_uri, uri)
      |> assign(:filter_target, Params.normalize_text(Map.get(params, "target")))
      |> assign(:filter_agent, Params.normalize_text(Map.get(params, "agent")))
      |> assign(:current_page, Params.parse_page(Map.get(params, "page")))
      |> assign(:limit, Params.parse_limit(Map.get(params, "limit"), default_limit))
      |> Params.sync_srql_state(params, uri)

    {:noreply, Loader.refresh_diagnostics(socket)}
  end

  @impl true
  def handle_event(event, params, socket), do: Events.handle_event(event, params, socket)

  @impl true
  def handle_info(message, socket), do: Events.handle_info(message, socket)

  @impl true
  def render(assigns), do: View.render(assigns)
end
