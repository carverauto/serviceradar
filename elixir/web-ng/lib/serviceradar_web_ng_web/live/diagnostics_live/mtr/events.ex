defmodule ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.Events do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView

  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.Bulk
  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.Config
  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.Loader
  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.Params
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  def handle_event("filter", %{"target" => target, "agent" => agent}, socket) do
    params =
      socket.assigns
      |> Map.get(:last_params, %{})
      |> Map.merge(%{"target" => Params.normalize_text(target), "agent" => Params.normalize_text(agent), "page" => 1})
      |> Map.put("limit", socket.assigns.limit)
      |> Params.maybe_put_query(socket.assigns.srql[:query] || "")

    {:noreply, push_patch(socket, to: Params.patch_path(params))}
  end

  def handle_event("srql_change", params, socket), do: {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}

  def handle_event("srql_submit", params, socket) do
    opts = [fallback_path: "/diagnostics/mtr", extra_params: Params.extra_query_params(socket)]
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, opts)}
  end

  def handle_event("srql_reset", params, socket) do
    opts = [fallback_path: "/diagnostics/mtr", extra_params: Params.extra_query_params(socket)]
    {:noreply, SRQLPage.handle_event(socket, "srql_reset", params, opts)}
  end

  def handle_event("srql_builder_toggle", _params, socket),
    do: {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "mtr_traces")}

  def handle_event("srql_builder_change", params, socket),
    do: {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}

  def handle_event("srql_builder_apply", _params, socket),
    do: {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}

  def handle_event("srql_builder_run", _params, socket) do
    opts = [fallback_path: "/diagnostics/mtr", extra_params: Params.extra_query_params(socket)]
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_run", %{}, opts)}
  end

  def handle_event("srql_builder_add_filter", params, socket),
    do: {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "mtr_traces")}

  def handle_event("srql_builder_remove_filter", params, socket),
    do: {:noreply, SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "mtr_traces")}

  def handle_event("open_mtr_modal", _params, socket),
    do:
      {:noreply,
       socket
       |> assign(:show_mtr_modal, true)
       |> assign(:mtr_agents, list_online_agents())
       |> assign(:mtr_error, nil)
       |> assign(:mtr_running, false)}

  def handle_event("close_mtr_modal", _params, socket), do: {:noreply, assign(socket, :show_mtr_modal, false)}

  def handle_event("open_bulk_mtr_modal", _params, socket),
    do:
      {:noreply,
       socket
       |> assign(:show_bulk_mtr_modal, true)
       |> assign(:mtr_agents, list_online_agents())
       |> assign(:bulk_mtr_error, nil)}

  def handle_event("close_bulk_mtr_modal", _params, socket), do: {:noreply, assign(socket, :show_bulk_mtr_modal, false)}

  def handle_event("run_mtr", %{"mtr" => mtr_params}, socket) do
    target = String.trim(mtr_params[Config.payload_target_key()] || "")
    agent_id = mtr_params[Config.payload_agent_id_key()] || ""
    protocol = Bulk.normalize_protocol(Map.get(mtr_params, Config.payload_protocol_key(), Config.protocol_icmp()))

    cond do
      target == "" -> {:noreply, assign(socket, :mtr_error, "Target is required")}
      agent_id == "" -> {:noreply, assign(socket, :mtr_error, "Please select an agent")}
      true -> dispatch_mtr(socket, agent_id, target, protocol, true)
    end
  end

  def handle_event("run_again", %{"target" => target, "agent_id" => agent_id} = params, socket) do
    protocol = Bulk.normalize_protocol(Map.get(params, Config.payload_protocol_key(), Config.protocol_icmp()))
    dispatch_mtr(socket, agent_id, target, protocol, false)
  end

  def handle_event("run_bulk_mtr", %{"bulk_mtr" => params}, socket) do
    socket = assign(socket, :bulk_mtr_form, to_form(Bulk.normalize_form_params(params), as: :bulk_mtr))
    agent_id = params[Config.payload_agent_id_key()] || ""
    protocol = Bulk.normalize_protocol(Map.get(params, Config.payload_protocol_key(), Config.protocol_icmp()))

    execution_profile =
      Bulk.normalize_execution_profile(
        Map.get(params, Config.payload_execution_profile_key(), Config.execution_profile_fast())
      )

    concurrency = Bulk.parse_positive_integer(Map.get(params, "concurrency"), 64)
    selector_limit = Bulk.parse_positive_integer(Map.get(params, Config.payload_selector_limit_key()), 100)

    with :ok <- Bulk.validate_agent(agent_id),
         {:ok, targets} <- Bulk.targets_from_params(params, selector_limit),
         {:ok, _command_id} <-
           AgentCommandBus.dispatch_bulk_mtr(agent_id, targets,
             protocol: protocol,
             execution_profile: execution_profile,
             concurrency: concurrency,
             target_query: Bulk.target_query(params),
             selector_limit: selector_limit
           ) do
      {:noreply,
       socket
       |> assign(:show_bulk_mtr_modal, false)
       |> assign(:bulk_mtr_error, nil)
       |> put_flash(:info, "Bulk MTR job queued for #{length(targets)} targets")
       |> Loader.refresh_diagnostics()}
    else
      {:error, reason} -> {:noreply, assign(socket, :bulk_mtr_error, bulk_error(reason))}
    end
  end

  def handle_info({:command_result, %{command_type: type} = msg}, socket) do
    case type do
      "mtr.run" -> {:noreply, msg |> maybe_clear_active_command(socket) |> Loader.schedule_refresh()}
      "mtr.bulk_run" -> {:noreply, Loader.schedule_refresh(socket)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({event, %{command_type: type}}, socket) when event in [:command_ack, :command_progress] do
    if type in [Config.command_type_mtr_run(), Config.command_type_mtr_bulk_run()] do
      {:noreply, Loader.schedule_refresh(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:mtr_trace_ingested, _event}, socket), do: {:noreply, Loader.schedule_refresh(socket)}

  def handle_info(:refresh_diagnostics, socket) do
    {:noreply, socket |> assign(:refresh_timer, nil) |> Loader.refresh_diagnostics()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp dispatch_mtr(socket, agent_id, target, protocol, modal?) do
    payload = %{Config.payload_target_key() => target, Config.payload_protocol_key() => protocol}

    case AgentCommandBus.dispatch(agent_id, Config.command_type_mtr_run(), payload, required_capability: "mtr") do
      {:ok, command_id} ->
        mtr_dispatched(socket, command_id, modal?)

      {:error, {:agent_offline, _}} ->
        mtr_error(socket, "Agent is offline", modal?)

      {:error, {:agent_busy, :too_many_concurrent_mtr_traces}} ->
        mtr_error(socket, "Agent is already running the maximum number of concurrent MTR traces", modal?)

      {:error, reason} ->
        mtr_error(socket, "Failed to dispatch: #{inspect(reason)}", modal?)
    end
  end

  defp mtr_dispatched(socket, command_id, true) do
    {:noreply,
     socket
     |> assign(:show_mtr_modal, false)
     |> assign(:mtr_running, true)
     |> assign(:mtr_error, nil)
     |> assign(:mtr_command_id, command_id)
     |> put_flash(:info, "MTR trace queued")
     |> Loader.refresh_diagnostics()}
  end

  defp mtr_dispatched(socket, command_id, false) do
    {:noreply,
     socket |> assign(:mtr_command_id, command_id) |> put_flash(:info, "MTR trace queued") |> Loader.refresh_diagnostics()}
  end

  defp mtr_error(socket, message, true), do: {:noreply, assign(socket, :mtr_error, message)}
  defp mtr_error(socket, message, false), do: {:noreply, put_flash(socket, :error, message)}

  defp maybe_clear_active_command(msg, socket) do
    command_id = Map.get(msg, :command_id) || Map.get(msg, "command_id")

    if is_binary(command_id) and command_id != "" and socket.assigns[:mtr_command_id] == command_id do
      socket |> assign(:mtr_running, false) |> assign(:mtr_command_id, nil)
    else
      socket
    end
  end

  defp list_online_agents do
    AgentCommandBus.list_online_agents()
  rescue
    _ -> []
  end

  defp bulk_error(:missing_targets), do: "Provide at least one target or an SRQL query"
  defp bulk_error(:missing_agent), do: "Please select an agent"
  defp bulk_error(:empty_srql_targets), do: "SRQL query returned no eligible targets"
  defp bulk_error({:srql_query_failed, reason}), do: "SRQL target resolution failed: #{inspect(reason)}"
  defp bulk_error({:agent_busy, :bulk_mtr_job_running}), do: "Agent already has a bulk MTR job in progress"
  defp bulk_error({:agent_offline, _}), do: "Agent is offline"
  defp bulk_error(reason), do: "Failed to dispatch bulk job: #{inspect(reason)}"
end
