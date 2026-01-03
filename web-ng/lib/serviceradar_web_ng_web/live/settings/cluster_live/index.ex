defmodule ServiceRadarWebNGWeb.Settings.ClusterLive.Index do
  @moduledoc """
  LiveView for monitoring the distributed Horde cluster from the settings area.

  Provides real-time visibility into:
  - ERTS cluster topology and node status
  - Horde-managed pollers (standalone Elixir releases)
  - Horde-managed agents (standalone Elixir releases)
  - Cluster health metrics
  - Oban job queue status
  """
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Cluster.ClusterStatus
  alias ServiceRadar.GatewayRegistry
  alias ServiceRadar.AgentRegistry

  @refresh_interval :timer.seconds(10)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to cluster events (same topics used by AgentRegistry)
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "cluster:events")
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "agent:registrations")

      # Schedule periodic refresh
      schedule_refresh()
    end

    socket =
      socket
      |> assign(:page_title, "Cluster Status")
      |> assign(:cluster_status, load_cluster_status())
      |> assign(:cluster_health, load_cluster_health())
      |> assign(:gateways, load_gateways())
      |> assign(:agents, load_agents())
      |> assign(:oban_stats, load_oban_stats())
      |> assign(:events, [])

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()

    {:noreply,
     socket
     |> assign(:cluster_status, load_cluster_status())
     |> assign(:cluster_health, load_cluster_health())
     |> assign(:gateways, load_gateways())
     |> assign(:agents, load_agents())
     |> assign(:oban_stats, load_oban_stats())}
  end

  def handle_info({:node_up, node}, socket) do
    event = %{type: :node_up, node: node, timestamp: DateTime.utc_now()}

    {:noreply,
     socket
     |> assign(:cluster_status, load_cluster_status())
     |> assign(:cluster_health, load_cluster_health())
     |> update(:events, fn events -> [event | Enum.take(events, 49)] end)
     |> put_flash(:info, "Node joined: #{node}")}
  end

  def handle_info({:node_down, node}, socket) do
    event = %{type: :node_down, node: node, timestamp: DateTime.utc_now()}

    {:noreply,
     socket
     |> assign(:cluster_status, load_cluster_status())
     |> assign(:cluster_health, load_cluster_health())
     |> update(:events, fn events -> [event | Enum.take(events, 49)] end)
     |> put_flash(:error, "Node disconnected: #{node}")}
  end

  def handle_info({:agent_registered, metadata}, socket) do
    event = %{type: :agent_registered, agent_id: metadata.agent_id, timestamp: DateTime.utc_now()}

    {:noreply,
     socket
     |> assign(:agents, load_agents())
     |> update(:events, fn events -> [event | Enum.take(events, 49)] end)}
  end

  def handle_info({:agent_disconnected, agent_id}, socket) do
    event = %{type: :agent_disconnected, agent_id: agent_id, timestamp: DateTime.utc_now()}

    {:noreply,
     socket
     |> assign(:agents, load_agents())
     |> update(:events, fn events -> [event | Enum.take(events, 49)] end)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:cluster_status, load_cluster_status())
     |> assign(:cluster_health, load_cluster_health())
     |> assign(:gateways, load_gateways())
     |> assign(:agents, load_agents())
     |> assign(:oban_stats, load_oban_stats())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-7xl p-6 space-y-6">
        <.settings_nav current_path="/settings/cluster" />

        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-base-content">Cluster Status</h1>
            <p class="text-sm text-base-content/60">
              Monitor the distributed ERTS cluster, pollers, agents, and job queues.
            </p>
          </div>
          <.ui_button variant="ghost" size="sm" phx-click="refresh">
            <.icon name="hero-arrow-path" class="size-4" /> Refresh
          </.ui_button>
        </div>
        
    <!-- Health Metrics Cards -->
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-5 gap-4">
          <.health_card
            title="Cluster"
            value={if @cluster_status.enabled, do: "Active", else: "Standalone"}
            variant={if @cluster_status.enabled, do: "success", else: "info"}
            icon="hero-globe-alt"
          />
          <.health_card
            title="Nodes"
            value={@cluster_status.node_count}
            variant={if @cluster_status.node_count > 1, do: "success", else: "info"}
            icon="hero-server-stack"
          />
          <.health_card
            title="Pollers"
            value={@cluster_health.poller_count}
            variant="info"
            icon="hero-cpu-chip"
          />
          <.health_card
            title="Agents"
            value={@cluster_health.agent_count}
            variant="info"
            icon="hero-cube"
          />
          <.health_card
            title="Jobs"
            value={@oban_stats.total_executing}
            variant={oban_variant(@oban_stats)}
            icon="hero-queue-list"
          />
        </div>
        
    <!-- Cluster Nodes -->
        <.ui_panel>
          <:header>
            <div>
              <div class="text-sm font-semibold">Cluster Nodes</div>
              <p class="text-xs text-base-content/60">
                ERTS nodes connected via mTLS
              </p>
            </div>
          </:header>

          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr class="text-xs uppercase tracking-wide text-base-content/60">
                  <th>Node</th>
                  <th>Type</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                <tr class="bg-base-200/30">
                  <td class="font-mono text-sm">{to_string(@cluster_status.self)}</td>
                  <td>
                    <.ui_badge variant="info" size="xs">Self</.ui_badge>
                  </td>
                  <td>
                    <.ui_badge variant="success" size="xs">Connected</.ui_badge>
                  </td>
                </tr>
                <%= for node <- @cluster_status.connected_nodes do %>
                  <tr>
                    <td class="font-mono text-sm">{to_string(node)}</td>
                    <td>
                      <.ui_badge variant="ghost" size="xs">Remote</.ui_badge>
                    </td>
                    <td>
                      <.ui_badge variant="success" size="xs">Connected</.ui_badge>
                    </td>
                  </tr>
                <% end %>
                <tr :if={@cluster_status.connected_nodes == []}>
                  <td colspan="3" class="text-center text-base-content/60 py-4">
                    No remote nodes connected
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.ui_panel>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <!-- Poller Registry -->
          <.ui_panel>
            <:header>
              <div>
                <div class="text-sm font-semibold">Pollers</div>
                <p class="text-xs text-base-content/60">
                  {@cluster_health.poller_count} poller(s) in cluster
                </p>
              </div>
            </:header>

            <div class="overflow-x-auto">
              <%= if @gateways == [] do %>
                <div class="rounded-xl border border-dashed border-base-200 bg-base-100 p-6 text-center">
                  <div class="text-sm font-semibold text-base-content">No gateways</div>
                  <p class="mt-1 text-xs text-base-content/60">
                    Deploy gateways to join the cluster.
                  </p>
                </div>
              <% else %>
                <table class="table table-sm">
                  <thead>
                    <tr class="text-xs uppercase tracking-wide text-base-content/60">
                      <th>Partition</th>
                      <th>Node</th>
                      <th>Status</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for gateway <- @gateways do %>
                      <tr>
                        <td class="font-mono text-xs">
                          {Map.get(gateway, :partition_id, "default")}
                        </td>
                        <td class="font-mono text-xs">{format_node(Map.get(gateway, :node))}</td>
                        <td><.status_badge status={Map.get(gateway, :status)} /></td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              <% end %>
            </div>
          </.ui_panel>
          
    <!-- Agent Registry -->
          <.ui_panel>
            <:header>
              <div>
                <div class="text-sm font-semibold">Agents</div>
                <p class="text-xs text-base-content/60">
                  {@cluster_health.agent_count} agent(s) in cluster
                </p>
              </div>
            </:header>

            <div class="overflow-x-auto">
              <%= if @agents == [] do %>
                <div class="rounded-xl border border-dashed border-base-200 bg-base-100 p-6 text-center">
                  <div class="text-sm font-semibold text-base-content">No agents</div>
                  <p class="mt-1 text-xs text-base-content/60">
                    Deploy agents to join the cluster.
                  </p>
                </div>
              <% else %>
                <table class="table table-sm">
                  <thead>
                    <tr class="text-xs uppercase tracking-wide text-base-content/60">
                      <th>Agent ID</th>
                      <th>Poller</th>
                      <th>Status</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for agent <- @agents do %>
                      <tr>
                        <td class="font-mono text-xs max-w-[10rem] truncate">
                          {Map.get(agent, :agent_id, "—")}
                        </td>
                        <td class="font-mono text-xs">{format_node(Map.get(agent, :poller_node))}</td>
                        <td><.status_badge status={Map.get(agent, :status)} /></td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              <% end %>
            </div>
          </.ui_panel>
        </div>
        
    <!-- Oban Queue Status -->
        <.ui_panel>
          <:header>
            <div>
              <div class="text-sm font-semibold">Job Queues</div>
              <p class="text-xs text-base-content/60">
                Oban job queue status across the cluster
              </p>
            </div>
          </:header>

          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr class="text-xs uppercase tracking-wide text-base-content/60">
                  <th>Queue</th>
                  <th>Available</th>
                  <th>Executing</th>
                  <th>Scheduled</th>
                  <th>Retryable</th>
                </tr>
              </thead>
              <tbody>
                <%= for {queue, stats} <- @oban_stats.queues do %>
                  <tr>
                    <td class="font-medium">{queue}</td>
                    <td class="text-success">{Map.get(stats, :available, 0)}</td>
                    <td class="text-info">{Map.get(stats, :executing, 0)}</td>
                    <td class="text-base-content/70">{Map.get(stats, :scheduled, 0)}</td>
                    <td class={
                      if Map.get(stats, :retryable, 0) > 0,
                        do: "text-warning",
                        else: "text-base-content/70"
                    }>
                      {Map.get(stats, :retryable, 0)}
                    </td>
                  </tr>
                <% end %>
                <tr :if={@oban_stats.queues == %{}}>
                  <td colspan="5" class="text-center text-base-content/60 py-4">
                    No job queues configured
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.ui_panel>
        
    <!-- Recent Events -->
        <.ui_panel :if={@events != []}>
          <:header>
            <div>
              <div class="text-sm font-semibold">Recent Events</div>
              <p class="text-xs text-base-content/60">
                Last {length(@events)} cluster events
              </p>
            </div>
          </:header>

          <div class="overflow-x-auto">
            <table class="table table-xs">
              <thead>
                <tr class="text-[11px] uppercase tracking-wide text-base-content/50">
                  <th>Event</th>
                  <th>Details</th>
                  <th>Time</th>
                </tr>
              </thead>
              <tbody>
                <%= for event <- @events do %>
                  <tr>
                    <td><.event_badge type={event.type} /></td>
                    <td class="font-mono text-xs">
                      {event_details(event)}
                    </td>
                    <td class="text-xs font-mono">{format_timestamp(event.timestamp)}</td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </.ui_panel>
      </div>
    </Layouts.app>
    """
  end

  # Settings navigation component
  defp settings_nav(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-2 mb-4">
      <.link
        navigate={~p"/users/settings"}
        class={[
          "btn btn-sm",
          if(@current_path == "/users/settings", do: "btn-primary", else: "btn-ghost")
        ]}
      >
        <.icon name="hero-user" class="size-4" /> Profile
      </.link>
      <.link
        navigate={~p"/settings/cluster"}
        class={[
          "btn btn-sm",
          if(@current_path == "/settings/cluster", do: "btn-primary", else: "btn-ghost")
        ]}
      >
        <.icon name="hero-server-stack" class="size-4" /> Cluster
      </.link>
    </div>
    """
  end

  # Components

  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :variant, :string, default: "info"
  attr :icon, :string, required: true

  defp health_card(assigns) do
    bg_class =
      case assigns.variant do
        "success" -> "bg-success/10 border-success/20"
        "warning" -> "bg-warning/10 border-warning/20"
        "error" -> "bg-error/10 border-error/20"
        _ -> "bg-info/10 border-info/20"
      end

    icon_class =
      case assigns.variant do
        "success" -> "text-success"
        "warning" -> "text-warning"
        "error" -> "text-error"
        _ -> "text-info"
      end

    assigns =
      assigns
      |> assign(:bg_class, bg_class)
      |> assign(:icon_class, icon_class)

    ~H"""
    <div class={"rounded-xl border p-4 #{@bg_class}"}>
      <div class="flex items-center gap-3">
        <div class={"rounded-lg bg-base-100 p-2 #{@icon_class}"}>
          <.icon name={@icon} class="size-5" />
        </div>
        <div>
          <div class="text-xs text-base-content/60">{@title}</div>
          <div class="text-xl font-bold text-base-content">{@value}</div>
        </div>
      </div>
    </div>
    """
  end

  attr :status, :atom, default: nil

  defp status_badge(assigns) do
    {label, variant} =
      case assigns.status do
        :available -> {"Available", "success"}
        :connected -> {"Connected", "success"}
        :busy -> {"Busy", "warning"}
        :unavailable -> {"Unavailable", "error"}
        :disconnected -> {"Disconnected", "error"}
        _ -> {"Unknown", "ghost"}
      end

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  attr :type, :atom, required: true

  defp event_badge(assigns) do
    {label, variant} =
      case assigns.type do
        :node_up -> {"Node Up", "success"}
        :node_down -> {"Node Down", "error"}
        :agent_registered -> {"Agent Registered", "info"}
        :agent_disconnected -> {"Agent Disconnected", "warning"}
        _ -> {"Unknown", "ghost"}
      end

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  # Helpers

  defp load_cluster_status do
    # Use ClusterStatus which works from any node in the cluster
    # (web-ng doesn't run ClusterSupervisor/ClusterHealth - those only run on core-elx)
    status = ClusterStatus.get_status()

    %{
      enabled: status.enabled,
      self: status.self,
      connected_nodes: status.connected_nodes,
      node_count: status.node_count,
      topologies: status.topologies
    }
  rescue
    _ -> %{enabled: false, self: Node.self(), connected_nodes: [], node_count: 1, topologies: []}
  end

  defp load_cluster_health do
    # Use ClusterStatus which queries coordinator via RPC if needed
    status = ClusterStatus.get_status()

    %{
      poller_count: status.poller_count,
      agent_count: status.agent_count,
      status: status.status
    }
  rescue
    _ -> %{poller_count: 0, agent_count: 0, status: :unknown}
  end

  defp load_gateways do
    GatewayRegistry.all_gateways()
  rescue
    _ -> []
  end

  defp load_agents do
    AgentRegistry.all_agents()
  rescue
    _ -> []
  end

  defp load_oban_stats do
    import Ecto.Query

    # Query job counts by queue and state
    query =
      from j in Oban.Job,
        where: j.state in ["available", "executing", "scheduled", "retryable"],
        group_by: [j.queue, j.state],
        select: {j.queue, j.state, count(j.id)}

    results = ServiceRadar.Repo.all(query)

    # Aggregate by queue
    queues =
      results
      |> Enum.reduce(%{}, fn {queue, state, count}, acc ->
        state_atom = String.to_atom(state)

        queue_stats =
          Map.get(acc, queue, %{available: 0, executing: 0, scheduled: 0, retryable: 0})

        updated_stats = Map.put(queue_stats, state_atom, count)
        Map.put(acc, queue, updated_stats)
      end)

    total_executing =
      queues
      |> Map.values()
      |> Enum.map(&Map.get(&1, :executing, 0))
      |> Enum.sum()

    %{queues: queues, total_executing: total_executing}
  rescue
    _ -> %{queues: %{}, total_executing: 0}
  end

  defp oban_variant(%{total_executing: n}) when n > 0, do: "success"
  defp oban_variant(_), do: "info"

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end

  defp format_node(nil), do: "—"
  defp format_node(node) when is_atom(node), do: to_string(node)
  defp format_node(node), do: to_string(node)

  defp format_timestamp(nil), do: "—"

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_timestamp(_), do: "—"

  defp event_details(%{type: :node_up, node: node}), do: to_string(node)
  defp event_details(%{type: :node_down, node: node}), do: to_string(node)
  defp event_details(%{type: :agent_registered, agent_id: id}), do: id
  defp event_details(%{type: :agent_disconnected, agent_id: id}), do: id
  defp event_details(_), do: "—"
end
