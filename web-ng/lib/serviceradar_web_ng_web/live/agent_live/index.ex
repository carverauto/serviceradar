defmodule ServiceRadarWebNGWeb.AgentLive.Index do
  @moduledoc """
  LiveView for listing OCSF agents.

  Displays agents registered in the ocsf_agents table with filtering
  and pagination via SRQL queries, plus live Horde-registered agents.
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias Phoenix.LiveView.JS
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @default_limit 20
  @max_limit 100

  # OCSF Agent type IDs
  @type_names %{
    0 => "Unknown",
    1 => "EDR",
    4 => "Performance",
    6 => "Log Management",
    99 => "Other"
  }

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to agent registration events
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "agent:registrations")
    end

    {:ok,
     socket
     |> assign(:page_title, "Agents")
     |> assign(:agents, [])
     |> assign(:live_agents, load_live_agents())
     |> assign(:limit, @default_limit)
     |> SRQLPage.init("agents", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {:noreply,
     socket
     |> SRQLPage.load_list(params, uri, :agents,
       default_limit: @default_limit,
       max_limit: @max_limit
     )}
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, fallback_path: "/agents")}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "agents")}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_run", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_run", %{}, fallback_path: "/agents")}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "agents")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "agents")}
  end

  # Handle PubSub events for live agent updates
  @impl true
  def handle_info({:agent_registered, _metadata}, socket) do
    {:noreply, assign(socket, :live_agents, load_live_agents())}
  end

  def handle_info({:agent_disconnected, _agent_id}, socket) do
    {:noreply, assign(socket, :live_agents, load_live_agents())}
  end

  def handle_info({:agent_status_changed, _agent_id, _status}, socket) do
    {:noreply, assign(socket, :live_agents, load_live_agents())}
  end

  # Catch-all for other PubSub messages
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_live_agents do
    # Get all agents from Horde registry
    ServiceRadar.AgentRegistry.all_agents()
    |> Enum.map(fn agent ->
      %{
        agent_id: Map.get(agent, :agent_id) || Map.get(agent, :key),
        tenant_id: Map.get(agent, :tenant_id),
        partition_id: Map.get(agent, :partition_id),
        poller_node: Map.get(agent, :poller_node),
        capabilities: Map.get(agent, :capabilities, []),
        status: Map.get(agent, :status, :unknown),
        connected_at: Map.get(agent, :connected_at),
        last_heartbeat: Map.get(agent, :last_heartbeat),
        spiffe_identity: Map.get(agent, :spiffe_identity)
      }
    end)
    |> Enum.sort_by(& &1.agent_id)
  end

  @impl true
  def render(assigns) do
    pagination = get_in(assigns, [:srql, :pagination]) || %{}
    assigns = assign(assigns, :pagination, pagination)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6 space-y-6">
        <%!-- Live Connected Agents Section --%>
        <.ui_panel>
          <div class="px-4 py-3 border-b border-base-200 flex items-center justify-between">
            <div class="flex items-center gap-2">
              <span class="text-sm font-semibold">Live Agents</span>
              <span class="badge badge-sm badge-success">{length(@live_agents)} connected</span>
            </div>
            <span class="text-xs text-base-content/50">Real-time Horde registry</span>
          </div>
          <.live_agents_table id="live-agents" agents={@live_agents} />
        </.ui_panel>

        <%!-- Database Agents Section --%>
        <.ui_panel>
          <div class="px-4 py-3 border-b border-base-200">
            <span class="text-sm font-semibold">Registered Agents</span>
          </div>
          <.agents_table id="agents" agents={@agents} />

          <div class="mt-4 pt-4 border-t border-base-200">
            <.ui_pagination
              prev_cursor={Map.get(@pagination, "prev_cursor")}
              next_cursor={Map.get(@pagination, "next_cursor")}
              base_path="/agents"
              query={Map.get(@srql, :query, "")}
              limit={@limit}
              result_count={length(@agents)}
            />
          </div>
        </.ui_panel>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :agents, :list, default: []

  defp live_agents_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table id={@id} class="table table-sm table-zebra w-full">
        <thead>
          <tr>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-10">
              Status
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-48">
              Agent ID
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-32">
              Partition
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-40">
              Poller Node
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60">
              Capabilities
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-36">
              Connected
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-36">
              Last Heartbeat
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@agents == []}>
            <td colspan="7" class="text-sm text-base-content/60 py-8 text-center">
              No live agents connected. Agents will appear here when they register with the Horde cluster.
            </td>
          </tr>

          <%= for {agent, idx} <- Enum.with_index(@agents) do %>
            <tr
              id={"#{@id}-row-#{idx}"}
              class="hover:bg-base-200/40 cursor-pointer transition-colors"
              phx-click={JS.navigate(~p"/agents/#{agent.agent_id}")}
            >
              <td class="whitespace-nowrap">
                <.status_indicator status={agent.status} />
              </td>
              <td
                class="whitespace-nowrap text-xs font-mono truncate max-w-[12rem]"
                title={agent.agent_id}
              >
                {agent.agent_id}
              </td>
              <td class="whitespace-nowrap text-xs">
                <span :if={agent.partition_id} class="badge badge-sm badge-ghost">
                  {agent.partition_id}
                </span>
                <span :if={!agent.partition_id} class="text-base-content/40">—</span>
              </td>
              <td
                class="whitespace-nowrap text-xs font-mono truncate max-w-[10rem]"
                title={to_string(agent.poller_node)}
              >
                {format_node(agent.poller_node)}
              </td>
              <td class="text-xs">
                <.capabilities_list capabilities={agent.capabilities} />
              </td>
              <td class="whitespace-nowrap text-xs font-mono">
                {format_datetime(agent.connected_at)}
              </td>
              <td class="whitespace-nowrap text-xs font-mono">
                {format_datetime(agent.last_heartbeat)}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :status, :atom, default: :unknown

  defp status_indicator(assigns) do
    {color, label} =
      case assigns.status do
        :connected -> {"success", "Connected"}
        :disconnected -> {"error", "Disconnected"}
        :degraded -> {"warning", "Degraded"}
        :busy -> {"info", "Busy"}
        :draining -> {"warning", "Draining"}
        _ -> {"ghost", "Unknown"}
      end

    assigns = assign(assigns, color: color, label: label)

    ~H"""
    <div class="flex items-center gap-1.5" title={@label}>
      <span class={"status status-#{@color}"}></span>
    </div>
    """
  end

  defp format_node(nil), do: "—"

  defp format_node(node) when is_atom(node),
    do: node |> Atom.to_string() |> String.split("@") |> List.first()

  defp format_node(node), do: to_string(node)

  defp format_datetime(nil), do: "—"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_datetime(_), do: "—"

  attr :id, :string, required: true
  attr :agents, :list, default: []

  defp agents_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table id={@id} class="table table-sm table-zebra w-full">
        <thead>
          <tr>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-48">
              Agent ID
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-32">
              Name
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-24">
              Type
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-40">
              Poller
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60">
              Capabilities
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-36">
              Last Seen
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@agents == []}>
            <td colspan="6" class="text-sm text-base-content/60 py-8 text-center">
              No agents found.
            </td>
          </tr>

          <%= for {agent, idx} <- Enum.with_index(@agents) do %>
            <tr
              id={"#{@id}-row-#{idx}"}
              class="hover:bg-base-200/40 cursor-pointer transition-colors"
              phx-click={JS.navigate(~p"/agents/#{agent_uid(agent)}")}
            >
              <td
                class="whitespace-nowrap text-xs font-mono truncate max-w-[12rem]"
                title={agent_uid(agent)}
              >
                {agent_uid(agent)}
              </td>
              <td
                class="whitespace-nowrap text-xs truncate max-w-[8rem]"
                title={agent_name(agent)}
              >
                {agent_name(agent)}
              </td>
              <td class="whitespace-nowrap text-xs">
                <.type_badge type_id={Map.get(agent, "type_id")} />
              </td>
              <td
                class="whitespace-nowrap text-xs font-mono truncate max-w-[10rem]"
                title={agent_poller(agent)}
              >
                {agent_poller(agent)}
              </td>
              <td class="text-xs">
                <.capabilities_list capabilities={Map.get(agent, "capabilities", [])} />
              </td>
              <td class="whitespace-nowrap text-xs font-mono">
                {format_timestamp(agent)}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :type_id, :integer, default: 0

  defp type_badge(assigns) do
    type_id = assigns.type_id || 0
    type_name = Map.get(@type_names, type_id, "Unknown")

    variant =
      case type_id do
        1 -> "error"
        4 -> "info"
        6 -> "warning"
        99 -> "ghost"
        _ -> "ghost"
      end

    assigns = assign(assigns, :type_name, type_name) |> assign(:variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@type_name}</.ui_badge>
    """
  end

  attr :capabilities, :list, default: []

  defp capabilities_list(assigns) do
    caps = assigns.capabilities || []
    assigns = assign(assigns, :caps, caps)

    ~H"""
    <div class="flex flex-wrap gap-1">
      <%= for cap <- @caps do %>
        <span class="badge badge-xs badge-outline">{cap}</span>
      <% end %>
      <span :if={@caps == []} class="text-base-content/40">—</span>
    </div>
    """
  end

  defp agent_uid(agent) do
    Map.get(agent, "uid") || Map.get(agent, "id") || "unknown"
  end

  defp agent_name(agent) do
    Map.get(agent, "name") || "—"
  end

  defp agent_poller(agent) do
    Map.get(agent, "poller_id") || "—"
  end

  defp format_timestamp(agent) do
    ts = Map.get(agent, "last_seen_time") || Map.get(agent, "last_seen")

    case parse_timestamp(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      _ -> ts || "—"
    end
  end

  defp parse_timestamp(nil), do: :error
  defp parse_timestamp(""), do: :error

  defp parse_timestamp(value) when is_binary(value) do
    value = String.trim(value)

    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      {:error, _} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, ndt} -> {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
          {:error, _} -> :error
        end
    end
  end

  defp parse_timestamp(_), do: :error
end
