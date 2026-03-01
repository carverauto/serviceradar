defmodule ServiceRadarWebNGWeb.DiagnosticsLive.Mtr do
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.AgentRegistry
  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrData
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage
  alias ServiceRadar.Observability.MtrPubSub

  @default_limit 25
  @max_limit 200

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
     |> assign(:last_params, %{})
     |> assign(:last_uri, "/diagnostics/mtr")
     |> assign(:traces, [])
     |> assign(:pending_jobs, [])
     |> assign(:limit, @default_limit)
     |> assign(:current_page, 1)
     |> assign(:total_count, 0)
     |> assign(:filter_target, "")
     |> assign(:filter_agent, "")
     # On-demand MTR modal state
     |> assign(:show_mtr_modal, false)
     |> assign(:mtr_agents, [])
     |> assign(
       :mtr_form,
       to_form(%{"target" => "", "agent_id" => "", "protocol" => "icmp"}, as: :mtr)
     )
     |> assign(:mtr_running, false)
     |> assign(:mtr_error, nil)
     |> assign(:mtr_command_id, nil)
     |> assign(:refresh_timer, nil)
     |> SRQLPage.init("mtr_traces", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket =
      socket
      |> assign(:last_params, params)
      |> assign(:last_uri, uri)
      |> assign(:filter_target, normalize_text(Map.get(params, "target")))
      |> assign(:filter_agent, normalize_text(Map.get(params, "agent")))
      |> assign(:current_page, parse_page(Map.get(params, "page")))
      |> assign(:limit, parse_limit(Map.get(params, "limit"), @default_limit))
      |> sync_srql_state(params, uri)

    {:noreply, refresh_diagnostics(socket)}
  end

  @impl true
  def handle_event("filter", %{"target" => target, "agent" => agent}, socket) do
    params =
      socket.assigns
      |> Map.get(:last_params, %{})
      |> Map.merge(%{
        "target" => normalize_text(target),
        "agent" => normalize_text(agent),
        "page" => 1
      })
      |> Map.put("limit", socket.assigns.limit)
      |> maybe_put_query(socket.assigns.srql[:query] || "")

    {:noreply, push_patch(socket, to: patch_path(params))}
  end

  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    opts = [fallback_path: "/diagnostics/mtr", extra_params: extra_query_params(socket)]
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, opts)}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "mtr_traces")}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_run", _params, socket) do
    opts = [fallback_path: "/diagnostics/mtr", extra_params: extra_query_params(socket)]
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_run", %{}, opts)}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "mtr_traces")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "mtr_traces")}
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
             |> assign(:mtr_running, true)
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

  def handle_event("run_again", %{"target" => target, "agent_id" => agent_id} = params, socket) do
    protocol = Map.get(params, "protocol", "icmp")
    payload = %{"target" => target, "protocol" => protocol}

    case AgentCommandBus.dispatch(agent_id, "mtr.run", payload) do
      {:ok, command_id} ->
        {:noreply,
         socket
         |> assign(:mtr_command_id, command_id)
         |> put_flash(:info, "MTR trace queued")
         |> refresh_diagnostics()}

      {:error, {:agent_offline, _}} ->
        {:noreply, put_flash(socket, :error, "Agent is offline")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to dispatch: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:command_result, %{command_type: "mtr.run"} = msg}, socket) do
    command_id = Map.get(msg, :command_id) || Map.get(msg, "command_id")

    if active_mtr_command?(socket, command_id) do
      {:noreply,
       socket
       |> assign(:mtr_running, false)
       |> schedule_refresh()}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:mtr_trace_ingested, _event}, socket) do
    {:noreply, schedule_refresh(socket)}
  end

  def handle_info({:command_ack, %{command_type: "mtr.run"}}, socket),
    do: {:noreply, schedule_refresh(socket)}

  def handle_info({:command_progress, %{command_type: "mtr.run"}}, socket),
    do: {:noreply, schedule_refresh(socket)}

  def handle_info(:refresh_diagnostics, socket) do
    {:noreply,
     socket
     |> assign(:refresh_timer, nil)
     |> refresh_diagnostics()}
  end

  def handle_info({:command_result, _}, socket), do: {:noreply, socket}
  def handle_info({:command_ack, _}, socket), do: {:noreply, socket}
  def handle_info({:command_progress, _}, socket), do: {:noreply, socket}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp active_mtr_command?(socket, command_id)
       when is_binary(command_id) and command_id != "" do
    current_command_id = socket.assigns[:mtr_command_id]
    is_binary(current_command_id) and current_command_id == command_id
  end

  defp active_mtr_command?(_socket, _command_id), do: false

  defp refresh_diagnostics(socket) do
    socket
    |> load_traces()
    |> load_pending_jobs()
  end

  defp schedule_refresh(socket) do
    case socket.assigns[:refresh_timer] do
      nil ->
        ref = Process.send_after(self(), :refresh_diagnostics, 250)
        assign(socket, :refresh_timer, ref)

      _ref ->
        socket
    end
  end

  defp load_traces(socket) do
    srql_query = Map.get(socket.assigns.srql || %{}, :query, "")

    case MtrData.list_traces_paginated(
           target_filter: socket.assigns.filter_target,
           agent_filter: socket.assigns.filter_agent,
           srql_query: srql_query,
           limit: socket.assigns.limit,
           page: socket.assigns.current_page
         ) do
      {:ok, %{rows: traces, total_count: total_count, page: page, per_page: limit}} ->
        socket
        |> assign(:traces, traces)
        |> assign(:total_count, total_count)
        |> assign(:current_page, page)
        |> assign(:limit, limit)

      {:error, _} ->
        socket
        |> assign(:traces, [])
        |> assign(:total_count, 0)
    end
  end

  defp load_pending_jobs(socket) do
    case MtrData.list_pending_jobs(
           socket.assigns.current_scope,
           target_filter: socket.assigns.filter_target,
           agent_filter: socket.assigns.filter_agent
         ) do
      {:ok, jobs} ->
        assign(
          socket,
          :pending_jobs,
          MtrData.suppress_completed_pending_jobs(jobs, socket.assigns.traces)
        )

      {:error, _} ->
        assign(socket, :pending_jobs, [])
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
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
                  <span class={[
                    "badge badge-sm w-28 justify-center",
                    pending_status_class(job.status)
                  ]}>
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
                  <div
                    :if={trace["target_ip"] != trace["target"]}
                    class="text-xs text-base-content/50"
                  >
                    {trace["target_ip"]}
                  </div>
                </td>
                <td>
                  <span
                    :if={trace["target_reached"]}
                    class="badge badge-success badge-sm w-28 justify-center"
                  >
                    Reached
                  </span>
                  <span
                    :if={!trace["target_reached"]}
                    class="badge badge-error badge-sm w-28 justify-center"
                  >
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
                <td class="flex items-center gap-1">
                  <button
                    type="button"
                    class="btn btn-xs btn-ghost"
                    phx-click="run_again"
                    phx-value-target={trace["target"] || ""}
                    phx-value-agent_id={trace["agent_id"] || ""}
                    phx-value-protocol={trace["protocol"] || "icmp"}
                    title="Run again"
                    aria-label="Run MTR trace again"
                  >
                    <svg
                      xmlns="http://www.w3.org/2000/svg"
                      class="h-3.5 w-3.5"
                      fill="none"
                      viewBox="0 0 24 24"
                      stroke="currentColor"
                    >
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M4 4v6h6M20 20v-6h-6M20 9A8 8 0 006.34 5.34L4 8m16 8l-2.34 2.66A8 8 0 013.99 15"
                      />
                    </svg>
                  </button>
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
        <div class="pt-1">
          <.mtr_pagination
            page={@current_page}
            limit={@limit}
            total_count={@total_count}
            query={Map.get(@srql || %{}, :query, "")}
            filter_target={@filter_target}
            filter_agent={@filter_agent}
          />
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

  attr :page, :integer, required: true
  attr :limit, :integer, required: true
  attr :total_count, :integer, required: true
  attr :query, :string, default: ""
  attr :filter_target, :string, default: ""
  attr :filter_agent, :string, default: ""

  defp mtr_pagination(assigns) do
    total_pages = max(1, ceil(assigns.total_count / max(assigns.limit, 1)))
    has_prev = assigns.page > 1
    has_next = assigns.page < total_pages

    prev_params =
      pagination_params(
        assigns.query,
        max(assigns.page - 1, 1),
        assigns.limit,
        assigns.filter_target,
        assigns.filter_agent
      )

    next_params =
      pagination_params(
        assigns.query,
        min(assigns.page + 1, total_pages),
        assigns.limit,
        assigns.filter_target,
        assigns.filter_agent
      )

    assigns =
      assigns
      |> assign(:total_pages, total_pages)
      |> assign(:has_prev, has_prev)
      |> assign(:has_next, has_next)
      |> assign(:prev_path, patch_path(prev_params))
      |> assign(:next_path, patch_path(next_params))

    ~H"""
    <div class="flex items-center justify-between gap-3 border-t border-base-200 pt-4">
      <div class="text-sm text-base-content/60">
        {if @total_count > 0,
          do: "Showing page #{@page} of #{@total_pages} (#{@total_count} total)",
          else: "No results"}
      </div>
      <div class="join">
        <.link :if={@has_prev} patch={@prev_path} class="join-item btn btn-sm btn-outline">
          <.icon name="hero-chevron-left" class="size-4" /> Prev
        </.link>
        <button :if={!@has_prev} class="join-item btn btn-sm btn-outline" disabled>
          <.icon name="hero-chevron-left" class="size-4" /> Prev
        </button>
        <span class="join-item btn btn-sm btn-ghost pointer-events-none">
          {@page} / {@total_pages}
        </span>
        <.link :if={@has_next} patch={@next_path} class="join-item btn btn-sm btn-outline">
          Next <.icon name="hero-chevron-right" class="size-4" />
        </.link>
        <button :if={!@has_next} class="join-item btn btn-sm btn-outline" disabled>
          Next <.icon name="hero-chevron-right" class="size-4" />
        </button>
      </div>
    </div>
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

  defp parse_page(nil), do: 1

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {value, ""} when value > 0 -> value
      _ -> 1
    end
  end

  defp parse_page(page) when is_integer(page) and page > 0, do: page
  defp parse_page(_), do: 1

  defp parse_limit(nil, default), do: default

  defp parse_limit(limit, default) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, ""} -> parse_limit(value, default)
      _ -> default
    end
  end

  defp parse_limit(limit, _default) when is_integer(limit) do
    limit |> max(1) |> min(@max_limit)
  end

  defp parse_limit(_limit, default), do: default

  defp sync_srql_state(socket, params, uri) do
    query = normalize_text(Map.get(params, "q"))

    srql =
      (socket.assigns[:srql] || %{})
      |> Map.put(:enabled, true)
      |> Map.put(:entity, "mtr_traces")
      |> Map.put(:page_path, uri_path(uri, "/diagnostics/mtr"))
      |> Map.put(:query, default_query(query, socket.assigns.limit))
      |> Map.put(:draft, default_query(query, socket.assigns.limit))

    assign(socket, :srql, srql)
  end

  defp uri_path(uri, fallback) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{path: path} when is_binary(path) and path != "" -> path
      _ -> fallback
    end
  end

  defp uri_path(_uri, fallback), do: fallback

  defp default_query("", limit), do: "in:mtr_traces sort:time:desc limit:#{limit}"
  defp default_query(query, _limit), do: query

  defp patch_path(params) do
    cleaned =
      params
      |> Map.reject(fn {_k, v} -> is_nil(v) or v == "" end)

    "/diagnostics/mtr?" <> URI.encode_query(cleaned)
  end

  defp pagination_params(query, page, limit, target, agent) do
    %{
      "q" => query,
      "page" => page,
      "limit" => limit,
      "target" => target,
      "agent" => agent
    }
  end

  defp extra_query_params(socket) do
    %{
      "target" => socket.assigns.filter_target,
      "agent" => socket.assigns.filter_agent,
      "page" => 1
    }
  end

  defp maybe_put_query(params, ""), do: Map.delete(params, "q")
  defp maybe_put_query(params, query), do: Map.put(params, "q", query)

  defp normalize_text(nil), do: ""
  defp normalize_text(value) when is_binary(value), do: String.trim(value)
  defp normalize_text(value), do: value |> to_string() |> String.trim()
end
