defmodule ServiceRadarWebNGWeb.Settings.ClusterLive.Index do
  @moduledoc """
  LiveView for monitoring the distributed Horde cluster from the settings area.

  Provides real-time visibility into:
  - ERTS cluster topology and node status
  - Horde-managed gateways (standalone Elixir releases)
  - Horde-managed agents (standalone Elixir releases)
  - Cluster health metrics
  - Oban job queue status
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Jobs.JobCatalog
  alias ServiceRadar.Cluster.ClusterStatus
  alias ServiceRadarWebNG.RBAC

  @refresh_interval :timer.seconds(10)
  @stale_threshold_ms :timer.minutes(2)

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "settings.view") do
      if connected?(socket) do
        # Subscribe to cluster events (same topics used by AgentRegistry)
        Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "cluster:events")
        Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "agent:registrations")
        Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "agent:status")
        Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "gateway:platform")

        # Schedule periodic refresh
        schedule_refresh()
      end

      is_admin =
        case scope do
          nil -> false
          scope -> Scope.admin?(scope)
        end

      gateways_cache = load_initial_gateways_cache()
      agents_cache = load_initial_agents_cache()
      gateways = compute_gateways(gateways_cache)
      agents = compute_connected_agents(agents_cache)

      cluster_status = load_cluster_status()
      cluster_health = build_cluster_health(gateways, agents)
      job_counts = load_job_counts(scope)

      socket =
        socket
        |> assign(:page_title, "Cluster Status")
        |> assign(:cluster_status, cluster_status)
        |> assign(:cluster_health, cluster_health)
        |> assign(:gateways_cache, gateways_cache)
        |> assign(:agents_cache, agents_cache)
        |> assign(:gateways, gateways)
        |> assign(:agents, agents)
        |> assign(:is_admin, is_admin)
        |> assign(:job_counts, job_counts)
        |> assign(:oban_stats, load_oban_stats())
        |> assign(:events, [])

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "You do not have access to Settings")
       |> push_navigate(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()

    cluster_status = load_cluster_status()
    now_ms = System.system_time(:millisecond)

    pruned_gateways_cache =
      socket.assigns.gateways_cache
      |> Enum.reject(fn {_id, gw} ->
        last_ms = parse_timestamp_to_ms(Map.get(gw, :last_heartbeat))

        delta_ms =
          if is_integer(last_ms) do
            max(now_ms - last_ms, 0)
          else
            nil
          end

        not is_integer(delta_ms) or delta_ms > @stale_threshold_ms
      end)
      |> Map.new()

    refreshed_gateways_cache =
      merge_gateways_cache(pruned_gateways_cache, load_initial_gateways_cache())

    pruned_agents_cache =
      socket.assigns.agents_cache
      |> Enum.reject(fn {_id, agent} ->
        not agent_active?(agent, now_ms)
      end)
      |> Map.new()

    gateways = compute_gateways(refreshed_gateways_cache)
    agents = compute_connected_agents(pruned_agents_cache)
    cluster_health = build_cluster_health(gateways, agents)
    job_counts = load_job_counts(socket.assigns.current_scope)

    {:noreply,
     socket
     |> assign(:cluster_status, cluster_status)
     |> assign(:cluster_health, cluster_health)
     |> assign(:gateways_cache, refreshed_gateways_cache)
     |> assign(:agents_cache, pruned_agents_cache)
     |> assign(:gateways, gateways)
     |> assign(:agents, agents)
     |> assign(:job_counts, job_counts)
     |> assign(:oban_stats, load_oban_stats())}
  end

  def handle_info({:node_up, node}, socket) do
    event = %{type: :node_up, node: node, timestamp: DateTime.utc_now()}

    {:noreply,
     socket
     |> assign(:cluster_status, load_cluster_status())
     |> assign(
       :cluster_health,
       build_cluster_health(socket.assigns.gateways, socket.assigns.agents)
     )
     |> update(:events, fn events -> [event | Enum.take(events, 49)] end)
     |> put_flash(:info, "Node joined: #{node}")}
  end

  def handle_info({:node_down, node}, socket) do
    event = %{type: :node_down, node: node, timestamp: DateTime.utc_now()}

    {:noreply,
     socket
     |> assign(:cluster_status, load_cluster_status())
     |> assign(
       :cluster_health,
       build_cluster_health(socket.assigns.gateways, socket.assigns.agents)
     )
     |> update(:events, fn events -> [event | Enum.take(events, 49)] end)
     |> put_flash(:error, "Node disconnected: #{node}")}
  end

  def handle_info({:agent_registered, metadata}, socket) do
    event = %{type: :agent_registered, agent_id: metadata.agent_id, timestamp: DateTime.utc_now()}
    agents = compute_connected_agents(socket.assigns.agents_cache)

    {:noreply,
     socket
     |> assign(:agents, agents)
     |> assign(:cluster_health, build_cluster_health(socket.assigns.gateways, agents))
     |> update(:events, fn events -> [event | Enum.take(events, 49)] end)}
  end

  def handle_info({:agent_disconnected, agent_id}, socket) do
    event = %{type: :agent_disconnected, agent_id: agent_id, timestamp: DateTime.utc_now()}

    {:noreply,
     socket
     |> assign(:agents, socket.assigns.agents)
     |> update(:events, fn events -> [event | Enum.take(events, 49)] end)}
  end

  def handle_info({:gateway_registered, gateway_info}, socket) do
    gateway_id = gateway_info[:gateway_id]

    if is_nil(gateway_id) or gateway_id == "" do
      {:noreply, socket}
    else
      updated_cache =
        Map.put(socket.assigns.gateways_cache, gateway_id, %{
          gateway_id: gateway_id,
          node: gateway_info[:node] || Node.self(),
          partition: gateway_info[:partition] || "default",
          domain: gateway_info[:domain] || "default",
          status: gateway_info[:status] || :available,
          registered_at: gateway_info[:registered_at] || DateTime.utc_now(),
          last_heartbeat: gateway_info[:last_heartbeat] || DateTime.utc_now()
        })

      gateways = compute_gateways(updated_cache)
      cluster_health = build_cluster_health(gateways, socket.assigns.agents)

      {:noreply,
       socket
       |> assign(:gateways_cache, updated_cache)
       |> assign(:gateways, gateways)
       |> assign(:cluster_health, cluster_health)}
    end
  end

  def handle_info({:gateway_unregistered, gateway_id}, socket) do
    updated_cache = Map.delete(socket.assigns.gateways_cache, gateway_id)
    gateways = compute_gateways(updated_cache)
    cluster_health = build_cluster_health(gateways, socket.assigns.agents)

    {:noreply,
     socket
     |> assign(:gateways_cache, updated_cache)
     |> assign(:gateways, gateways)
     |> assign(:cluster_health, cluster_health)}
  end

  def handle_info({:agent_status, agent_info}, socket) do
    agent_id = agent_info[:agent_id]

    if is_nil(agent_id) or agent_id == "" do
      {:noreply, socket}
    else
      updated_cache =
        Map.put(socket.assigns.agents_cache, agent_id, %{
          agent_id: agent_id,
          last_seen: agent_info[:last_seen] || DateTime.utc_now(),
          last_seen_mono: System.monotonic_time(:millisecond),
          service_count: agent_info[:service_count] || 0,
          partition: agent_info[:partition],
          source_ip: agent_info[:source_ip]
        })

      agents = compute_connected_agents(updated_cache)
      cluster_health = build_cluster_health(socket.assigns.gateways, agents)

      {:noreply,
       socket
       |> assign(:agents_cache, updated_cache)
       |> assign(:agents, agents)
       |> assign(:cluster_health, cluster_health)}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh", _params, socket) do
    cluster_status = load_cluster_status()

    refreshed_gateways_cache =
      merge_gateways_cache(socket.assigns.gateways_cache, load_initial_gateways_cache())

    gateways = compute_gateways(refreshed_gateways_cache)
    agents = compute_connected_agents(socket.assigns.agents_cache)
    cluster_health = build_cluster_health(gateways, agents)
    job_counts = load_job_counts(socket.assigns.current_scope)

    {:noreply,
     socket
     |> assign(:cluster_status, cluster_status)
     |> assign(:cluster_health, cluster_health)
     |> assign(:gateways_cache, refreshed_gateways_cache)
     |> assign(:gateways, gateways)
     |> assign(:agents, agents)
     |> assign(:job_counts, job_counts)
     |> assign(:oban_stats, load_oban_stats())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path="/settings/cluster">
        <.settings_nav current_path="/settings/cluster" current_scope={@current_scope} />

        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-base-content">Cluster Status</h1>
            <p class="text-sm text-base-content/60">
              Monitor the distributed ERTS cluster, gateways, agents, and job queues.
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
            :if={@is_admin}
            title="Nodes"
            value={@cluster_status.node_count}
            variant={if @cluster_status.node_count > 1, do: "success", else: "info"}
            icon="hero-server-stack"
          />
          <.health_card
            :if={@is_admin}
            title="Gateways"
            value={length(@gateways)}
            variant="info"
            icon="hero-cpu-chip"
          />
          <.health_card
            title="Agents"
            value={length(@agents)}
            variant="info"
            icon="hero-cube"
          />
          <.health_card
            title="Jobs"
            value={@job_counts.total}
            variant={oban_variant(@oban_stats)}
            icon="hero-queue-list"
          />
        </div>
        
    <!-- Cluster Nodes -->
        <.ui_panel :if={@is_admin}>
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
                  <td class="font-mono text-sm">
                    <.link navigate={~p"/settings/cluster/nodes/#{node_param(@cluster_status.self)}"}>
                      {to_string(@cluster_status.self)}
                    </.link>
                  </td>
                  <td>
                    <.ui_badge variant="info" size="xs">Self</.ui_badge>
                  </td>
                  <td>
                    <.ui_badge variant="success" size="xs">Connected</.ui_badge>
                  </td>
                </tr>
                <%= for node <- @cluster_status.connected_nodes do %>
                  <tr>
                    <td class="font-mono text-sm">
                      <.link navigate={~p"/settings/cluster/nodes/#{node_param(node)}"}>
                        {to_string(node)}
                      </.link>
                    </td>
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
          <.ui_panel :if={@is_admin}>
            <:header>
              <div>
                <div class="text-sm font-semibold">Agent Gateways</div>
                <p class="text-xs text-base-content/60">
                  {length(@gateways)} gateway(s) in cluster
                </p>
              </div>
            </:header>

            <.gateways_table gateways={@gateways} expanded={true} />
          </.ui_panel>

          <.ui_panel>
            <:header>
              <div>
                <div class="text-sm font-semibold">Connected Agents</div>
                <p class="text-xs text-base-content/60">
                  {length(@agents)} agent(s) reporting
                </p>
              </div>
            </:header>

            <.agents_table agents={@agents} expanded={true} />
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
      </.settings_shell>
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

  attr :gateways, :list, required: true
  attr :expanded, :boolean, default: false

  defp gateways_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-sm">
        <thead>
          <tr class="text-xs uppercase tracking-wide text-base-content/60">
            <th>Status</th>
            <th>Gateway ID</th>
            <th :if={@expanded}>Partition</th>
            <th :if={@expanded}>Node</th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@gateways == []}>
            <td colspan={if @expanded, do: 4, else: 2} class="text-center text-base-content/60 py-6">
              No agent gateways registered
            </td>
          </tr>
          <%= for gateway <- @gateways do %>
            <tr class="hover:bg-base-200/40 cursor-pointer">
              <td>
                <.link
                  navigate={~p"/settings/cluster/nodes/#{node_param(gateway.node)}"}
                  class="flex items-center gap-1.5"
                >
                  <span class={"size-2 rounded-full #{if gateway.active, do: "bg-success", else: "bg-warning"}"}>
                  </span>
                  <span class="text-xs">{if gateway.active, do: "Active", else: "Stale"}</span>
                </.link>
              </td>
              <td>
                <.link
                  navigate={~p"/settings/cluster/nodes/#{node_param(gateway.node)}"}
                  class="font-mono text-xs block"
                >
                  {gateway.gateway_id}
                </.link>
              </td>
              <td :if={@expanded}>
                <.link
                  navigate={~p"/settings/cluster/nodes/#{node_param(gateway.node)}"}
                  class="font-mono text-xs block"
                >
                  {gateway.partition}
                </.link>
              </td>
              <td :if={@expanded}>
                <.link
                  navigate={~p"/settings/cluster/nodes/#{node_param(gateway.node)}"}
                  class="font-mono text-xs text-base-content/60 block"
                >
                  {gateway.short_name}
                </.link>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :agents, :list, required: true
  attr :expanded, :boolean, default: false

  defp agents_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-sm">
        <thead>
          <tr class="text-xs uppercase tracking-wide text-base-content/60">
            <th>Status</th>
            <th>Agent ID</th>
            <th :if={@expanded}>Last Seen</th>
            <th :if={@expanded}>Services</th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@agents == []}>
            <td colspan={if @expanded, do: 4, else: 2} class="text-center text-base-content/60 py-6">
              No agents have pushed status yet
            </td>
          </tr>
          <%= for agent <- @agents do %>
            <tr class="hover:bg-base-200/40 cursor-pointer">
              <td>
                <.link navigate={~p"/agents/#{agent.agent_id}"} class="flex items-center gap-1.5">
                  <span class={"size-2 rounded-full #{if agent.active, do: "bg-success", else: "bg-warning"}"}>
                  </span>
                  <span class="text-xs">{if agent.active, do: "Active", else: "Stale"}</span>
                </.link>
              </td>
              <td>
                <.link navigate={~p"/agents/#{agent.agent_id}"} class="font-mono text-xs block">
                  {agent.agent_id}
                </.link>
              </td>
              <td :if={@expanded}>
                <.link navigate={~p"/agents/#{agent.agent_id}"} class="font-mono text-xs block">
                  {format_time(agent.last_seen)}
                </.link>
              </td>
              <td :if={@expanded}>
                <.link navigate={~p"/agents/#{agent.agent_id}"} class="text-xs block">
                  {agent.service_count}
                </.link>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
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

  defp build_cluster_health(gateways, agents) do
    %{
      gateway_count: length(gateways),
      agent_count: length(agents)
    }
  end

  # In a single deployment, all jobs are visible (no filtering needed)
  defp load_job_counts(_scope) do
    total = JobCatalog.list_all_jobs() |> length()
    %{total: total}
  end

  defp load_initial_gateways_cache do
    [Node.self() | Node.list()]
    |> Task.async_stream(
      &fetch_gateways_from_node/1,
      timeout: 1_500,
      on_timeout: :kill_task,
      max_concurrency: 4
    )
    |> Enum.flat_map(&unwrap_gateway_result/1)
    |> Enum.reduce(%{}, &put_gateway_entry/2)
  end

  defp fetch_gateways_from_node(node) do
    case :rpc.call(node, ServiceRadar.GatewayTracker, :list_gateways, [], 1_000) do
      gateways when is_list(gateways) -> gateways
      _ -> []
    end
  end

  defp unwrap_gateway_result({:ok, gateways}) when is_list(gateways), do: gateways
  defp unwrap_gateway_result(_), do: []

  defp put_gateway_entry(gateway, acc) do
    case gateway_id_from(gateway) do
      nil ->
        acc

      gateway_id ->
        incoming = normalize_gateway_entry(gateway, gateway_id)

        Map.update(acc, gateway_id, incoming, fn existing ->
          prefer_gateway_entry(existing, incoming)
        end)
    end
  end

  defp gateway_id_from(gateway) do
    gateway_id = Map.get(gateway, :gateway_id) || Map.get(gateway, "gateway_id")

    if is_binary(gateway_id) and gateway_id != "", do: gateway_id, else: nil
  end

  defp normalize_gateway_entry(gateway, gateway_id) do
    %{
      gateway_id: gateway_id,
      node: fetch_gateway_field(gateway, :node, "node", Node.self()),
      partition: fetch_gateway_field(gateway, :partition, "partition", "default"),
      domain: fetch_gateway_field(gateway, :domain, "domain", "default"),
      status: fetch_gateway_field(gateway, :status, "status", :available),
      registered_at: fetch_gateway_field(gateway, :registered_at, "registered_at", nil),
      last_heartbeat: fetch_gateway_field(gateway, :last_heartbeat, "last_heartbeat", nil)
    }
  end

  defp fetch_gateway_field(gateway, atom_key, string_key, default) do
    Map.get(gateway, atom_key) || Map.get(gateway, string_key) || default
  end

  defp load_initial_agents_cache do
    all_agents =
      [Node.self() | Node.list()]
      |> Task.async_stream(
        fn node ->
          case :rpc.call(node, ServiceRadar.AgentTracker, :list_agents, [], 1_000) do
            agents when is_list(agents) -> agents
            _ -> []
          end
        end,
        timeout: 1_500,
        on_timeout: :kill_task,
        max_concurrency: 4
      )
      |> Enum.flat_map(fn
        {:ok, agents} -> agents
        _ -> []
      end)

    all_agents
    |> Enum.reduce(%{}, fn agent, acc ->
      agent_id = Map.get(agent, :agent_id) || Map.get(agent, "agent_id")

      Map.put(acc, agent_id, %{
        agent_id: agent_id,
        last_seen: Map.get(agent, :last_seen) || Map.get(agent, "last_seen"),
        last_seen_mono: Map.get(agent, :last_seen_mono) || Map.get(agent, "last_seen_mono"),
        service_count: Map.get(agent, :service_count) || Map.get(agent, "service_count") || 0,
        partition: Map.get(agent, :partition) || Map.get(agent, "partition"),
        source_ip: Map.get(agent, :source_ip) || Map.get(agent, "source_ip")
      })
    end)
  end

  defp compute_gateways(gateways_cache) do
    now_ms = System.system_time(:millisecond)

    gateways_cache
    |> Map.values()
    |> Enum.map(fn gateway ->
      last_heartbeat_ms = parse_timestamp_to_ms(Map.get(gateway, :last_heartbeat))

      delta_ms =
        if is_integer(last_heartbeat_ms), do: max(now_ms - last_heartbeat_ms, 0), else: nil

      active = is_integer(delta_ms) and delta_ms < @stale_threshold_ms
      node_str = to_string(gateway.node)

      gateway
      |> Map.put(:active, active)
      |> Map.put(:full_name, node_str)
      |> Map.put(:short_name, node_str |> String.split("@") |> List.first())
    end)
    |> Enum.sort_by(& &1.gateway_id)
  end

  defp merge_gateways_cache(existing_cache, incoming_cache) do
    Map.merge(existing_cache, incoming_cache, fn _gateway_id, existing, incoming ->
      prefer_gateway_entry(existing, incoming)
    end)
  end

  defp prefer_gateway_entry(existing, incoming) do
    existing_ms = parse_timestamp_to_ms(Map.get(existing, :last_heartbeat))
    incoming_ms = parse_timestamp_to_ms(Map.get(incoming, :last_heartbeat))

    cond do
      is_integer(incoming_ms) and is_integer(existing_ms) and incoming_ms > existing_ms ->
        Map.merge(existing, incoming)

      is_integer(incoming_ms) and not is_integer(existing_ms) ->
        Map.merge(existing, incoming)

      true ->
        Map.merge(incoming, existing)
    end
  end

  defp parse_timestamp_to_ms(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)

  defp parse_timestamp_to_ms(%NaiveDateTime{} = ndt) do
    ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)
  end

  defp parse_timestamp_to_ms(ts) when is_integer(ts) do
    cond do
      ts < 0 ->
        nil

      ts > 10_000_000_000_000_000 ->
        div(ts, 1_000_000)

      ts > 10_000_000_000_000 ->
        div(ts, 1_000)

      ts > 10_000_000_000 ->
        ts

      true ->
        ts * 1_000
    end
  end

  defp parse_timestamp_to_ms(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
  end

  defp parse_timestamp_to_ms(_), do: nil

  # In a single-deployment UI, all agents belong to this deployment (via PostgreSQL search_path)
  # so no filtering is needed - we show all agents from the cache.
  defp compute_connected_agents(agents_cache) do
    now_ms = System.system_time(:millisecond)

    agents_cache
    |> Map.values()
    |> Enum.map(fn agent ->
      Map.put(agent, :active, agent_active?(agent, now_ms))
    end)
    |> Enum.sort_by(& &1.agent_id)
  end

  defp agent_active?(agent, now_ms) do
    last_seen_ms = agent_last_seen_ms(agent)

    cond do
      is_integer(last_seen_ms) ->
        delta_ms = max(now_ms - last_seen_ms, 0)
        delta_ms < @stale_threshold_ms

      is_integer(agent[:last_seen_mono]) and is_nil(agent[:last_seen]) ->
        now_mono = System.monotonic_time(:millisecond)
        delta_ms = max(now_mono - agent[:last_seen_mono], 0)
        delta_ms < @stale_threshold_ms

      true ->
        false
    end
  end

  defp agent_last_seen_ms(agent) do
    case Map.get(agent, :last_seen) do
      %DateTime{} = dt ->
        DateTime.to_unix(dt, :millisecond)

      %NaiveDateTime{} = ndt ->
        ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)

      ts when is_binary(ts) ->
        parse_iso8601_ms(ts)

      ts when is_integer(ts) ->
        parse_timestamp_to_ms(ts)

      _ ->
        nil
    end
  end

  defp parse_iso8601_ms(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
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

  defp node_param(node), do: to_string(node)

  defp format_time(nil), do: "—"
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_time(_), do: "—"

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
