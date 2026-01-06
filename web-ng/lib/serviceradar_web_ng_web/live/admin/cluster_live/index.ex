defmodule ServiceRadarWebNGWeb.Admin.ClusterLive.Index do
  @moduledoc """
  LiveView for monitoring the distributed Horde cluster.

  Provides real-time visibility into:
  - ERTS cluster topology and node status
  - Horde-managed gateways (standalone Elixir releases)
  - Horde-managed agents (standalone Elixir releases)
  - Cluster health metrics

  ## Distributed Architecture

  ServiceRadar implements a "one big brain" architecture:

  1. **Mesh Network**: All nodes (web-ng, gateways, agents) connect via mesh VPN
     (Tailscale/Nebula) providing flat network connectivity with mTLS encryption.

  2. **Horde Registries**: Global process addressing with partition-based namespacing.
     Processes are registered as `{partition_id, device_id}` tuples to support
     overlapping IP space across partitions.

  3. **Standalone Releases**: Gateways and agents are separate Elixir releases that
     can be deployed to edge/bare metal/Docker/K8s. They join the ERTS cluster
     via libcluster and register their processes in Horde.

  4. **Ash Multi-tenancy**: Uses `partition_id` as the tenant attribute to enforce
     data isolation at the framework level.

  5. **Distributed Observer**: Run `:observer.start()` to visualize processes
    across all nodes, including remote edge gateways behind firewalls.
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.AdminComponents

  alias ServiceRadar.Cluster.ClusterStatus
  alias ServiceRadar.GatewayRegistry
  alias ServiceRadar.AgentRegistry

  @refresh_interval :timer.seconds(10)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to cluster events
      Phoenix.PubSub.subscribe(ServiceRadarWebNG.PubSub, "cluster:events")
      Phoenix.PubSub.subscribe(ServiceRadarWebNG.PubSub, "agent:registrations")

      # Schedule periodic refresh
      schedule_refresh()
    end

    socket =
      socket
      |> assign(:page_title, "Cluster Dashboard")
      |> assign(:cluster_status, load_cluster_status())
      |> assign(:cluster_health, load_cluster_health())
      |> assign(:gateways, load_gateways())
      |> assign(:agents, load_agents())
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
     |> assign(:agents, load_agents())}
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
     |> assign(:agents, load_agents())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-7xl p-6 space-y-6">
        <.admin_nav current_path="/admin/cluster" />

        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-base-content">Cluster Dashboard</h1>
            <p class="text-sm text-base-content/60">
              Distributed ERTS cluster with standalone Elixir gateways and agents connected via mTLS.
            </p>
          </div>
          <.ui_button variant="ghost" size="sm" phx-click="refresh">
            <.icon name="hero-arrow-path" class="size-4" /> Refresh
          </.ui_button>
        </div>
        
    <!-- Health Metrics Cards -->
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
          <.health_card
            title="Cluster Status"
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
            title="Gateways"
            value={@cluster_health.gateway_count}
            variant="info"
            icon="hero-cpu-chip"
          />
          <.health_card
            title="Agents"
            value={@cluster_health.agent_count}
            variant="info"
            icon="hero-cube"
          />
        </div>
        
    <!-- Cluster Nodes -->
        <.ui_panel>
          <:header>
            <div>
              <div class="text-sm font-semibold">Cluster Nodes</div>
              <p class="text-xs text-base-content/60">
                ERTS nodes connected via mTLS (web-ng, gateways, agents)
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
        
    <!-- Gateway Registry -->
        <.ui_panel>
          <:header>
            <div>
              <div class="text-sm font-semibold">Gateways</div>
              <p class="text-xs text-base-content/60">
                {@cluster_health.gateway_count} standalone Elixir gateway(s) in the distributed cluster
              </p>
            </div>
          </:header>

          <div class="overflow-x-auto">
            <%= if @gateways == [] do %>
              <div class="rounded-xl border border-dashed border-base-200 bg-base-100 p-8 text-center">
                <div class="text-sm font-semibold text-base-content">No gateways registered</div>
                <p class="mt-1 text-xs text-base-content/60">
                  Deploy standalone gateway releases to edge/bare metal/Docker/K8s to join the cluster.
                </p>
              </div>
            <% else %>
              <table class="table table-sm">
                <thead>
                  <tr class="text-xs uppercase tracking-wide text-base-content/60">
                    <th>Partition</th>
                    <th>Node</th>
                    <th>Capabilities</th>
                    <th>Status</th>
                    <th>Last Heartbeat</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for gateway <- @gateways do %>
                    <tr>
                      <td class="font-mono text-xs">{Map.get(gateway, :partition_id, "—")}</td>
                      <td class="font-mono text-xs">{format_node(Map.get(gateway, :node))}</td>
                      <td>
                        <div class="flex flex-wrap gap-1">
                          <%= for cap <- Map.get(gateway, :capabilities, []) do %>
                            <.ui_badge variant="ghost" size="xs">{cap}</.ui_badge>
                          <% end %>
                        </div>
                      </td>
                      <td><.status_badge status={Map.get(gateway, :status)} /></td>
                      <td class="text-xs text-base-content/70">
                        {format_timestamp(Map.get(gateway, :last_heartbeat))}
                      </td>
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
                {@cluster_health.agent_count} standalone Elixir agent(s) in the distributed cluster
              </p>
            </div>
          </:header>

          <div class="overflow-x-auto">
            <%= if @agents == [] do %>
              <div class="rounded-xl border border-dashed border-base-200 bg-base-100 p-8 text-center">
                <div class="text-sm font-semibold text-base-content">No agents registered</div>
                <p class="mt-1 text-xs text-base-content/60">
                  Deploy standalone agent releases to monitored hosts to join the cluster.
                </p>
              </div>
            <% else %>
              <table class="table table-sm">
                <thead>
                  <tr class="text-xs uppercase tracking-wide text-base-content/60">
                    <th>Agent ID</th>
                    <th>Gateway Node</th>
                    <th>Capabilities</th>
                    <th>Status</th>
                    <th>Connected At</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for agent <- @agents do %>
                    <tr>
                      <td class="font-mono text-xs max-w-[12rem] truncate">
                        {Map.get(agent, :agent_id, "—")}
                      </td>
                      <td class="font-mono text-xs">{format_node(Map.get(agent, :gateway_node))}</td>
                      <td>
                        <div class="flex flex-wrap gap-1">
                          <%= for cap <- Map.get(agent, :capabilities, []) do %>
                            <.ui_badge variant="ghost" size="xs">{cap}</.ui_badge>
                          <% end %>
                        </div>
                      </td>
                      <td><.status_badge status={Map.get(agent, :status)} /></td>
                      <td class="text-xs text-base-content/70">
                        {format_timestamp(Map.get(agent, :connected_at))}
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            <% end %>
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
      gateway_count: status.gateway_count,
      agent_count: status.agent_count,
      status: status.status
    }
  rescue
    _ -> %{gateway_count: 0, agent_count: 0, status: :unknown}
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
