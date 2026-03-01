defmodule ServiceRadarWebNGWeb.DiagnosticsLive.Mtr do
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.AgentRegistry
  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrData
  alias ServiceRadar.Observability.MtrPubSub

  @default_limit 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "agent:commands")
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, MtrPubSub.topic())
    end

    {:ok,
     socket
     |> assign(:page_title, "MTR Diagnostics")
     |> assign(:page_path, "/diagnostics/mtr")
     |> assign(:traces, [])
     |> assign(:pending_jobs, [])
     |> assign(:limit, @default_limit)
     |> assign(:filter_target, "")
     |> assign(:filter_agent, "")
     # On-demand MTR modal state
     |> assign(:show_mtr_modal, false)
     |> assign(:mtr_agents, [])
     |> assign(:mtr_form, to_form(%{"target" => "", "agent_id" => "", "protocol" => "icmp"}, as: :mtr))
     |> assign(:mtr_running, false)
     |> assign(:mtr_error, nil)
     |> assign(:mtr_command_id, nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, refresh_diagnostics(socket)}
  end

  @impl true
  def handle_event("filter", %{"target" => target, "agent" => agent}, socket) do
    {:noreply,
     socket
     |> assign(:filter_target, target || "")
     |> assign(:filter_agent, agent || "")
     |> refresh_diagnostics()}
  end

  def handle_event("open_mtr_modal", _params, socket) do
    agents =
      try do
        AgentRegistry.find_agents()
      rescue
        _ -> []
      end

    {:noreply,
     socket
     |> assign(:show_mtr_modal, true)
     |> assign(:mtr_agents, agents)
     |> assign(:mtr_error, nil)
     |> assign(:mtr_running, false)}
  end

  def handle_event("close_mtr_modal", _params, socket) do
    {:noreply, assign(socket, :show_mtr_modal, false)}
  end

  def handle_event("run_mtr", %{"mtr" => mtr_params}, socket) do
    target = String.trim(mtr_params["target"] || "")
    agent_id = mtr_params["agent_id"] || ""
    protocol = mtr_params["protocol"] || "icmp"

    cond do
      target == "" ->
        {:noreply, assign(socket, :mtr_error, "Target is required")}

      agent_id == "" ->
        {:noreply, assign(socket, :mtr_error, "Please select an agent")}

      true ->
        payload = %{"target" => target, "protocol" => protocol}

        case AgentCommandBus.dispatch(agent_id, "mtr.run", payload) do
          {:ok, command_id} ->
            {:noreply,
             socket
             |> assign(:show_mtr_modal, false)
             |> assign(:mtr_running, false)
             |> assign(:mtr_error, nil)
             |> assign(:mtr_command_id, command_id)
             |> put_flash(:info, "MTR trace queued")
             |> refresh_diagnostics()}

          {:error, {:agent_offline, _}} ->
            {:noreply, assign(socket, :mtr_error, "Agent is offline")}

          {:error, reason} ->
            {:noreply, assign(socket, :mtr_error, "Failed to dispatch: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def handle_info({:command_result, %{command_type: "mtr.run"}}, socket) do
    {:noreply,
     socket
     |> assign(:mtr_running, false)
     |> refresh_diagnostics()}
  end

  def handle_info({:mtr_trace_ingested, _event}, socket) do
    {:noreply, refresh_diagnostics(socket)}
  end

  def handle_info({:command_ack, %{command_type: "mtr.run"}}, socket),
    do: {:noreply, refresh_diagnostics(socket)}

  def handle_info({:command_progress, %{command_type: "mtr.run"}}, socket),
    do: {:noreply, refresh_diagnostics(socket)}

  def handle_info({:command_result, _}, socket), do: {:noreply, socket}
  def handle_info({:command_ack, _}, socket), do: {:noreply, socket}
  def handle_info({:command_progress, _}, socket), do: {:noreply, socket}

  defp refresh_diagnostics(socket) do
    socket
    |> load_traces()
    |> load_pending_jobs()
  end

  defp load_traces(socket) do
    case MtrData.list_traces(
           target_filter: socket.assigns.filter_target,
           agent_filter: socket.assigns.filter_agent,
           limit: socket.assigns.limit
         ) do
      {:ok, traces} ->
        assign(socket, :traces, traces)

      {:error, _} ->
        assign(socket, :traces, [])
    end
  end

  defp load_pending_jobs(socket) do
    case MtrData.list_pending_jobs(
           socket.assigns.current_scope,
           target_filter: socket.assigns.filter_target,
           agent_filter: socket.assigns.filter_agent
         ) do
      {:ok, jobs} ->
        assign(socket, :pending_jobs, jobs)

      {:error, _} ->
        assign(socket, :pending_jobs, [])
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={%{enabled: false, page_path: @page_path}}>
      <div class="p-6 space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold">MTR Diagnostics</h1>
          <p class="text-sm text-base-content/60 mt-1">Network path analysis traces from agents</p>
        </div>
        <div class="flex gap-2">
          <.link navigate={~p"/diagnostics/mtr/compare"} class="btn btn-sm btn-outline">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-4 w-4"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M9 19V6l12-3v13M9 19c0 1.105-1.343 2-3 2s-3-.895-3-2 1.343-2 3-2 3 .895 3 2zm12-3c0 1.105-1.343 2-3 2s-3-.895-3-2 1.343-2 3-2 3 .895 3 2zM9 10l12-3"
              />
            </svg>
            Compare
          </.link>
          <button type="button" phx-click="open_mtr_modal" class="btn btn-sm btn-primary">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-4 w-4"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M13 10V3L4 14h7v7l9-11h-7z"
              />
            </svg>
            Run MTR
          </button>
        </div>
      </div>

      <form phx-change="filter" class="flex gap-3">
        <input
          type="text"
          name="target"
          value={@filter_target}
          placeholder="Filter by target..."
          class="input input-sm input-bordered w-48"
          phx-debounce="300"
        />
        <input
          type="text"
          name="agent"
          value={@filter_agent}
          placeholder="Filter by agent..."
          class="input input-sm input-bordered w-48"
          phx-debounce="300"
        />
      </form>

      <div class="overflow-x-auto">
        <table class="table table-sm table-zebra">
          <thead>
            <tr>
              <th>Time</th>
              <th>Target</th>
              <th>Status</th>
              <th>Hops</th>
              <th>Protocol</th>
              <th>Agent</th>
              <th>Check</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={job <- @pending_jobs} class="hover opacity-80">
              <td class="whitespace-nowrap text-xs">
                {format_time(job.inserted_at)}
              </td>
              <td>
                <div class="font-mono text-sm">{job.payload["target"] || "-"}</div>
              </td>
              <td>
                <span class={["badge badge-sm", pending_status_class(job.status)]}>
                  {job.status |> to_string() |> String.replace("_", " ") |> String.upcase()}
                </span>
              </td>
              <td class="text-center">-</td>
              <td>
                <span class="badge badge-ghost badge-sm">
                  {String.upcase((job.payload || %{})["protocol"] || "icmp")}
                </span>
              </td>
              <td class="text-xs font-mono max-w-[120px] truncate" title={job.agent_id}>
                {job.agent_id}
              </td>
              <td class="text-xs max-w-[120px] truncate" title={job.command_type}>
                pending
              </td>
              <td class="text-xs text-base-content/50">
                {job.id}
              </td>
            </tr>
            <tr :for={trace <- @traces} class="hover">
              <td class="whitespace-nowrap text-xs">
                {format_time(trace["time"])}
              </td>
              <td>
                <div class="font-mono text-sm">{trace["target"]}</div>
                <div :if={trace["target_ip"] != trace["target"]} class="text-xs text-base-content/50">
                  {trace["target_ip"]}
                </div>
              </td>
              <td>
                <span :if={trace["target_reached"]} class="badge badge-success badge-sm">
                  Reached
                </span>
                <span :if={!trace["target_reached"]} class="badge badge-error badge-sm">
                  Unreachable
                </span>
              </td>
              <td class="text-center">{trace["total_hops"]}</td>
              <td>
                <span class="badge badge-ghost badge-sm">
                  {String.upcase(trace["protocol"] || "icmp")}
                </span>
                <span :if={trace["ip_version"] == 6} class="badge badge-info badge-sm ml-1">
                  IPv6
                </span>
              </td>
              <td class="text-xs font-mono max-w-[120px] truncate" title={trace["agent_id"]}>
                {trace["agent_id"]}
              </td>
              <td class="text-xs max-w-[120px] truncate" title={trace["check_name"]}>
                {trace["check_name"] || "-"}
              </td>
              <td>
                <.link
                  navigate={~p"/diagnostics/mtr/#{trace["id"]}"}
                  class="btn btn-xs btn-ghost"
                >
                  View
                </.link>
              </td>
            </tr>
            <tr :if={@pending_jobs == [] and @traces == []}>
              <td colspan="8" class="text-center py-8 text-base-content/50">
                No MTR traces found. Traces will appear once agents run MTR checks.
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <%= if @show_mtr_modal do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg mb-4">Run MTR Trace</h3>

            <div :if={@mtr_error} class="alert alert-error mb-4">
              <span>{@mtr_error}</span>
            </div>

            <.form for={@mtr_form} phx-submit="run_mtr">
              <div class="form-control mb-3">
                <label class="label">
                  <span class="label-text">Target (hostname or IP)</span>
                </label>
                <input
                  type="text"
                  name="mtr[target]"
                  value={@mtr_form["target"].value}
                  placeholder="e.g. 8.8.8.8 or google.com"
                  class="input input-bordered"
                  required
                />
              </div>

              <div class="form-control mb-3">
                <label class="label">
                  <span class="label-text">Agent</span>
                </label>
                <select
                  name="mtr[agent_id]"
                  class="select select-bordered"
                  required
                >
                  <option value="">Select an agent...</option>
                  <%= for agent <- @mtr_agents do %>
                    <option value={agent_id(agent)}>{agent_label(agent)}</option>
                  <% end %>
                </select>
                <label :if={@mtr_agents == []} class="label">
                  <span class="label-text-alt text-warning">No agents connected</span>
                </label>
              </div>

              <div class="form-control mb-4">
                <label class="label">
                  <span class="label-text">Protocol</span>
                </label>
                <select name="mtr[protocol]" class="select select-bordered">
                  <option value="icmp" selected>ICMP</option>
                  <option value="udp">UDP</option>
                  <option value="tcp">TCP</option>
                </select>
              </div>

              <div class="modal-action">
                <button type="button" phx-click="close_mtr_modal" class="btn">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary">
                  Queue Trace
                </button>
              </div>
            </.form>
          </div>
          <div class="modal-backdrop" phx-click="close_mtr_modal"></div>
        </div>
      <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp agent_id(agent) do
    Map.get(agent, :agent_id) || Map.get(agent, "agent_id") || ""
  end

  defp agent_label(agent) do
    id = agent_id(agent)
    partition = Map.get(agent, :partition_id) || Map.get(agent, "partition_id")

    if partition && partition != "" && partition != "default" do
      "#{id} (#{partition})"
    else
      id
    end
  end

  defp format_time(nil), do: "-"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp format_time(%NaiveDateTime{} = ndt) do
    Calendar.strftime(ndt, "%Y-%m-%d %H:%M:%S")
  end

  defp format_time(_), do: "-"

  defp pending_status_class(:queued), do: "badge-ghost"
  defp pending_status_class(:sent), do: "badge-info"
  defp pending_status_class(:acknowledged), do: "badge-info"
  defp pending_status_class(:running), do: "badge-warning"
  defp pending_status_class(_), do: "badge-ghost"
end
