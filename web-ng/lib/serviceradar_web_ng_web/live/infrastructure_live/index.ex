defmodule ServiceRadarWebNGWeb.InfrastructureLive.Index do
  @moduledoc """
  Infrastructure LiveView showing cluster nodes and agent gateways.

  - Cluster Nodes: All ERTS nodes in the distributed cluster
  - Agent Gateways: Elixir nodes that receive status pushes from Go agents
  - Connected Agents: Go agents that have pushed status to gateways
  """
  use ServiceRadarWebNGWeb, :live_view

  require Logger

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadarWebNG.Accounts.Scope

  # Cache agents and gateways locally since trackers use node-local ETS
  # Data is synced via PubSub broadcasts from gateway nodes
  @stale_threshold_ms :timer.minutes(2)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "cluster:events")
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "agent:status")
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "gateway:platform")

      # Refresh every 30 seconds
      :timer.send_interval(:timer.seconds(30), self(), :refresh)
    end

    cluster_info = load_cluster_info()

    current_scope = socket.assigns[:current_scope]

    # Check if user is platform admin for tab visibility
    is_platform_admin =
      case current_scope do
        nil -> false
        scope -> Scope.platform_admin?(scope)
      end

    # Get tenant_id for scoping agents (only for non-platform admins)
    tenant_id = get_tenant_id(socket)

    # Load existing agents from tracker on mount (don't start with empty cache)
    initial_agents_cache = load_initial_agents_cache()

    connected_agents =
      compute_connected_agents(initial_agents_cache, is_platform_admin, tenant_id)

    {:ok,
     socket
     |> assign(:page_title, "Infrastructure")
     |> assign(:active_tab, :agents)
     |> assign(:is_platform_admin, is_platform_admin)
     |> assign(:tenant_id, tenant_id)
     |> assign(:show_debug, false)
     |> assign(:srql, %{enabled: false, page_path: "/infrastructure"})
     |> assign(:cluster_info, cluster_info)
     |> assign(:gateways_cache, %{})
     |> assign(:gateways, [])
     |> assign(:agents_cache, initial_agents_cache)
     |> assign(:connected_agents, connected_agents)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    is_platform_admin = socket.assigns.is_platform_admin

    # Non-platform admins only see agents tab (other tabs are hidden)
    # Platform admins can navigate to any tab
    tab =
      if is_platform_admin do
        case params["tab"] do
          "nodes" -> :nodes
          "gateways" -> :gateways
          "agents" -> :agents
          _ -> :overview
        end
      else
        :agents
      end

    {:noreply,
     socket
     |> assign(:active_tab, tab)
     |> assign(:srql, %{enabled: false, page_path: "/infrastructure"})}
  end

  @impl true
  def handle_info(:refresh, socket) do
    cluster_info = load_cluster_info()

    now_ms = System.system_time(:millisecond)

    pruned_gateways_cache =
      socket.assigns.gateways_cache
      |> Enum.reject(fn {_id, gw} ->
        last_ms = parse_timestamp_to_ms(Map.get(gw, :last_heartbeat))

        not is_integer(last_ms) or
          max(now_ms - last_ms, 0) > @stale_threshold_ms
      end)
      |> Map.new()

    pruned_agents_cache =
      socket.assigns.agents_cache
      |> Enum.reject(fn {_id, agent} ->
        last_ms = agent_last_seen_ms(agent)

        not is_integer(last_ms) or
          max(now_ms - last_ms, 0) > @stale_threshold_ms
      end)
      |> Map.new()

    gateways = compute_gateways(pruned_gateways_cache)

    connected_agents =
      compute_connected_agents(
        pruned_agents_cache,
        socket.assigns.is_platform_admin,
        socket.assigns.tenant_id
      )

    {:noreply,
     socket
     |> assign(:cluster_info, cluster_info)
     |> assign(:gateways_cache, pruned_gateways_cache)
     |> assign(:agents_cache, pruned_agents_cache)
     |> assign(:gateways, gateways)
     |> assign(:connected_agents, connected_agents)}
  end

  def handle_info({:node_up, _node}, socket) do
    cluster_info = load_cluster_info()
    {:noreply, assign(socket, :cluster_info, cluster_info)}
  end

  def handle_info({:node_down, _node}, socket) do
    cluster_info = load_cluster_info()
    {:noreply, assign(socket, :cluster_info, cluster_info)}
  end

  def handle_info({:gateway_registered, gateway_info}, socket) do
    # Cache gateway info from PubSub
    gateway_id = gateway_info[:gateway_id]

    if is_nil(gateway_id) or gateway_id == "" do
      {:noreply, socket}
    else
      Logger.debug("[InfrastructureLive] Received gateway_registered: #{gateway_id}")

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

      {:noreply,
       socket
       |> assign(:gateways_cache, updated_cache)
       |> assign(:gateways, gateways)}
    end
  end

  def handle_info({:gateway_unregistered, gateway_id}, socket) do
    updated_cache = Map.delete(socket.assigns.gateways_cache, gateway_id)
    gateways = compute_gateways(updated_cache)

    {:noreply,
     socket
     |> assign(:gateways_cache, updated_cache)
     |> assign(:gateways, gateways)}
  end

  def handle_info({:agent_status, agent_info}, socket) do
    # Cache agent info from PubSub (comes from gateway nodes)
    agent_id = agent_info[:agent_id]

    if is_nil(agent_id) or agent_id == "" do
      {:noreply, socket}
    else
      updated_cache =
        Map.put(socket.assigns.agents_cache, agent_id, %{
          agent_id: agent_id,
          tenant_id: agent_info[:tenant_id],
          tenant_slug: agent_info[:tenant_slug] || "default",
          last_seen: agent_info[:last_seen] || DateTime.utc_now(),
          last_seen_mono: System.monotonic_time(:millisecond),
          service_count: agent_info[:service_count] || 0,
          partition: agent_info[:partition],
          source_ip: agent_info[:source_ip]
        })

      connected_agents =
        compute_connected_agents(
          updated_cache,
          socket.assigns.is_platform_admin,
          socket.assigns.tenant_id
        )

      {:noreply,
       socket
       |> assign(:agents_cache, updated_cache)
       |> assign(:connected_agents, connected_agents)}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh", _params, socket) do
    cluster_info = load_cluster_info()
    gateways = compute_gateways(socket.assigns.gateways_cache)

    connected_agents =
      compute_connected_agents(
        socket.assigns.agents_cache,
        socket.assigns.is_platform_admin,
        socket.assigns.tenant_id
      )

    {:noreply,
     socket
     |> assign(:cluster_info, cluster_info)
     |> assign(:gateways, gateways)
     |> assign(:connected_agents, connected_agents)}
  end

  def handle_event("toggle_debug", _params, socket) do
    {:noreply, assign(socket, :show_debug, !socket.assigns.show_debug)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6 space-y-6">
        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-base-content">
              {if @is_platform_admin, do: "Infrastructure", else: "Connected Agents"}
            </h1>
            <p class="text-sm text-base-content/60">
              <%= if @is_platform_admin do %>
                Cluster nodes and agent gateways
              <% else %>
                Agents connected to your tenant
              <% end %>
            </p>
          </div>
          <div class="flex items-center gap-2">
            <.ui_button :if={@is_platform_admin} variant="ghost" size="sm" phx-click="toggle_debug">
              <.icon name="hero-bug-ant" class="size-4" /> Debug
            </.ui_button>
            <.ui_button variant="ghost" size="sm" phx-click="refresh">
              <.icon name="hero-arrow-path" class="size-4" /> Refresh
            </.ui_button>
          </div>
        </div>
        
    <!-- Debug Panel (platform admin only) -->
        <div
          :if={@is_platform_admin && @show_debug}
          class="bg-base-200 rounded-lg p-4 space-y-3 border border-base-300"
        >
          <div class="text-sm font-semibold">Cluster Debug Info</div>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4 text-xs font-mono">
            <div>
              <div class="text-base-content/60 mb-1">Current Node</div>
              <div class="bg-base-100 p-2 rounded">{@cluster_info.current_node}</div>
            </div>
            <div>
              <div class="text-base-content/60 mb-1">
                Connected Nodes ({length(@cluster_info.connected_nodes)})
              </div>
              <div class="bg-base-100 p-2 rounded max-h-20 overflow-auto">
                <%= if @cluster_info.connected_nodes == [] do %>
                  <span class="text-warning">No other nodes connected</span>
                <% else %>
                  <%= for node <- @cluster_info.connected_nodes do %>
                    <div>{node}</div>
                  <% end %>
                <% end %>
              </div>
            </div>
          </div>
        </div>
        
    <!-- Summary Cards (platform admin only) -->
        <div :if={@is_platform_admin} class="grid grid-cols-2 md:grid-cols-3 gap-4">
          <.summary_card
            title="Cluster Nodes"
            value={length(@cluster_info.connected_nodes) + 1}
            icon="hero-server-stack"
            variant="primary"
            href={~p"/infrastructure?tab=nodes"}
          />
          <.summary_card
            title="Agent Gateways"
            value={length(@gateways)}
            icon="hero-cpu-chip"
            variant="info"
            href={~p"/infrastructure?tab=gateways"}
          />
          <.summary_card
            title="Connected Agents"
            value={length(@connected_agents)}
            icon="hero-cube"
            variant="success"
            href={~p"/infrastructure?tab=agents"}
          />
        </div>
        
    <!-- Tab Navigation (platform admin sees all tabs, others see only agents) -->
        <div :if={@is_platform_admin} class="tabs tabs-box">
          <.link
            patch={~p"/infrastructure"}
            class={["tab", @active_tab == :overview && "tab-active"]}
          >
            Overview
          </.link>
          <.link
            patch={~p"/infrastructure?tab=nodes"}
            class={["tab", @active_tab == :nodes && "tab-active"]}
          >
            Nodes
          </.link>
          <.link
            patch={~p"/infrastructure?tab=gateways"}
            class={["tab", @active_tab == :gateways && "tab-active"]}
          >
            Agent Gateways
          </.link>
          <.link
            patch={~p"/infrastructure?tab=agents"}
            class={["tab", @active_tab == :agents && "tab-active"]}
          >
            Connected Agents
          </.link>
        </div>
        
    <!-- Tab Content (overview, nodes, gateways only for platform admin) -->
        <div :if={@is_platform_admin && @active_tab == :overview}>
          <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <!-- Agent Gateways -->
            <.ui_panel>
              <:header>
                <div class="flex items-center gap-2">
                  <span class="text-sm font-semibold">Agent Gateways</span>
                  <span class="badge badge-sm badge-info">{length(@gateways)}</span>
                </div>
              </:header>
              <.gateways_table gateways={@gateways} />
            </.ui_panel>
            
    <!-- Connected Agents -->
            <.ui_panel>
              <:header>
                <div class="flex items-center gap-2">
                  <span class="text-sm font-semibold">Connected Agents</span>
                  <span class="badge badge-sm badge-success">{length(@connected_agents)}</span>
                </div>
              </:header>
              <.agents_table agents={@connected_agents} />
            </.ui_panel>
          </div>
        </div>

        <div :if={@is_platform_admin && @active_tab == :nodes} class="space-y-6">
          <.ui_panel>
            <:header>
              <div class="flex items-center gap-2">
                <span class="text-sm font-semibold">Cluster Nodes</span>
                <span class="badge badge-sm badge-primary">
                  {length(@cluster_info.connected_nodes) + 1}
                </span>
              </div>
            </:header>
            <.cluster_nodes_table cluster_info={@cluster_info} />
          </.ui_panel>
        </div>

        <div :if={@is_platform_admin && @active_tab == :gateways} class="space-y-6">
          <.ui_panel>
            <:header>
              <div class="flex items-center gap-2">
                <span class="text-sm font-semibold">Agent Gateways</span>
                <span class="badge badge-sm badge-info">{length(@gateways)}</span>
              </div>
            </:header>
            <.gateways_table gateways={@gateways} expanded={true} />
          </.ui_panel>
        </div>
        
    <!-- Connected Agents tab (visible to all authenticated users) -->
        <div :if={@active_tab == :agents} class="space-y-6">
          <.ui_panel>
            <:header>
              <div class="flex items-center gap-2">
                <span class="text-sm font-semibold">Connected Agents</span>
                <span class="badge badge-sm badge-success">{length(@connected_agents)}</span>
              </div>
            </:header>
            <.agents_table agents={@connected_agents} expanded={true} />
          </.ui_panel>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Components

  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, required: true
  attr :variant, :string, default: "info"
  attr :href, :string, default: nil

  defp summary_card(assigns) do
    bg_class =
      case assigns.variant do
        "success" -> "bg-success/10 border-success/20"
        "warning" -> "bg-warning/10 border-warning/20"
        "error" -> "bg-error/10 border-error/20"
        "info" -> "bg-info/10 border-info/20"
        "primary" -> "bg-primary/10 border-primary/20"
        _ -> "bg-base-200/50 border-base-300"
      end

    icon_class =
      case assigns.variant do
        "success" -> "text-success"
        "warning" -> "text-warning"
        "error" -> "text-error"
        "info" -> "text-info"
        "primary" -> "text-primary"
        _ -> "text-base-content/50"
      end

    assigns = assign(assigns, bg_class: bg_class, icon_class: icon_class)

    ~H"""
    <.link
      :if={@href}
      navigate={@href}
      class={"rounded-xl border p-4 #{@bg_class} cursor-pointer hover:brightness-95 transition-all"}
    >
      <div class="flex items-center gap-3">
        <div class={"rounded-lg bg-base-100 p-2 #{@icon_class}"}>
          <.icon name={@icon} class="size-5" />
        </div>
        <div>
          <div class="text-xs text-base-content/60">{@title}</div>
          <div class="text-xl font-bold text-base-content">{@value}</div>
        </div>
      </div>
    </.link>
    <div :if={!@href} class={"rounded-xl border p-4 #{@bg_class}"}>
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
                  navigate={~p"/infrastructure/nodes/#{node_param(gateway.node)}"}
                  class="flex items-center gap-1.5"
                >
                  <span class={"size-2 rounded-full #{if gateway.active, do: "bg-success", else: "bg-warning"}"}>
                  </span>
                  <span class="text-xs">{if gateway.active, do: "Active", else: "Stale"}</span>
                </.link>
              </td>
              <td>
                <.link
                  navigate={~p"/infrastructure/nodes/#{node_param(gateway.node)}"}
                  class="font-mono text-xs block"
                >
                  {gateway.gateway_id}
                </.link>
              </td>
              <td :if={@expanded}>
                <.link
                  navigate={~p"/infrastructure/nodes/#{node_param(gateway.node)}"}
                  class="font-mono text-xs block"
                >
                  {gateway.partition}
                </.link>
              </td>
              <td :if={@expanded}>
                <.link
                  navigate={~p"/infrastructure/nodes/#{node_param(gateway.node)}"}
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
            <th>Tenant</th>
            <th :if={@expanded}>Last Seen</th>
            <th :if={@expanded}>Services</th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@agents == []}>
            <td colspan={if @expanded, do: 5, else: 3} class="text-center text-base-content/60 py-6">
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
              <td>
                <.link navigate={~p"/agents/#{agent.agent_id}"} class="font-mono text-xs block">
                  {agent.tenant_slug}
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

  attr :cluster_info, :map, required: true

  defp cluster_nodes_table(assigns) do
    current_node = assigns.cluster_info.current_node
    connected_nodes = assigns.cluster_info.connected_nodes

    all_nodes =
      [current_node | connected_nodes]
      |> Enum.map(fn node ->
        node_str = to_string(node)

        %{
          node: node,
          is_current: node == current_node,
          type: detect_node_type(node_str),
          short_name: node_str |> String.split("@") |> List.first()
        }
      end)
      |> Enum.sort_by(fn n -> {!n.is_current, to_string(n.node)} end)

    assigns = assign(assigns, :nodes, all_nodes)

    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-sm">
        <thead>
          <tr class="text-xs uppercase tracking-wide text-base-content/60">
            <th>Status</th>
            <th>Node Name</th>
            <th>Type</th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@nodes == []}>
            <td colspan="3" class="text-center text-base-content/60 py-6">
              No cluster nodes
            </td>
          </tr>
          <%= for node <- @nodes do %>
            <tr class={["hover:bg-base-200/40 cursor-pointer", node.is_current && "bg-primary/5"]}>
              <td>
                <.link
                  navigate={~p"/infrastructure/nodes/#{node_param(node.node)}"}
                  class="flex items-center gap-1.5"
                >
                  <span class="size-2 rounded-full bg-success"></span>
                  <span class="text-xs">Connected</span>
                </.link>
              </td>
              <td class="font-mono text-xs">
                <.link
                  navigate={~p"/infrastructure/nodes/#{node_param(node.node)}"}
                  class="flex items-center gap-2"
                >
                  <span>{node.short_name}</span>
                  <span :if={node.is_current} class="badge badge-xs badge-primary">current</span>
                </.link>
              </td>
              <td>
                <.link navigate={~p"/infrastructure/nodes/#{node_param(node.node)}"}>
                  <.node_type_badge type={node.type} />
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

  defp node_type_badge(assigns) do
    {label, variant} =
      case assigns.type do
        :core -> {"Core", "primary"}
        :gateway -> {"Gateway", "info"}
        :web -> {"Web", "warning"}
        _ -> {"Unknown", "ghost"}
      end

    assigns = assign(assigns, label: label, variant: variant)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp node_param(node) do
    to_string(node)
  end

  # Data Loading

  defp load_cluster_info do
    %{
      current_node: Node.self(),
      connected_nodes: Node.list()
    }
  end

  # Load initial agents from the AgentTracker on mount
  # This ensures we show existing agents immediately instead of waiting for PubSub
  # AgentTracker runs on gateway nodes, so we query all cluster nodes via RPC
  defp load_initial_agents_cache do
    # Query all nodes in the cluster for their agents using async_stream
    # to prevent mount delays from slow or unresponsive nodes
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

    # Convert to cache format
    all_agents
    |> Enum.reduce(%{}, fn agent, acc ->
      Map.put(acc, agent.agent_id, %{
        agent_id: agent.agent_id,
        tenant_id: Map.get(agent, :tenant_id),
        tenant_slug: Map.get(agent, :tenant_slug, "default"),
        last_seen: agent.last_seen,
        last_seen_mono: System.monotonic_time(:millisecond),
        service_count: Map.get(agent, :service_count, 0),
        partition: Map.get(agent, :partition),
        source_ip: Map.get(agent, :source_ip)
      })
    end)
  end

  # Compute gateways from local cache with activity status
  # Uses wall-clock time (system_time) for accurate distributed staleness detection
  defp compute_gateways(gateways_cache) do
    now_ms = System.system_time(:millisecond)

    gateways_cache
    |> Map.values()
    |> Enum.map(fn gateway ->
      last_heartbeat_ms = parse_timestamp_to_ms(Map.get(gateway, :last_heartbeat))

      # Clamp delta to non-negative to handle clock skew
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

  # Parse various timestamp formats to milliseconds since epoch
  defp parse_timestamp_to_ms(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)

  defp parse_timestamp_to_ms(%NaiveDateTime{} = ndt) do
    ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)
  end

  defp parse_timestamp_to_ms(ts) when is_integer(ts) do
    cond do
      ts < 0 ->
        nil

      # nanoseconds since epoch
      ts > 10_000_000_000_000_000 ->
        div(ts, 1_000_000)

      # microseconds since epoch
      ts > 10_000_000_000_000 ->
        div(ts, 1_000)

      # milliseconds since epoch
      ts > 10_000_000_000 ->
        ts

      # seconds since epoch
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

  # Get tenant info from socket assigns for scoping
  # Returns {tenant_id, tenant_slug} tuple
  defp get_tenant_id(socket) do
    case socket.assigns[:current_scope] do
      %{active_tenant: %{id: id, slug: slug}} when not is_nil(id) ->
        {id, to_string(slug)}

      %{user: %{tenant_id: id, tenant: %{slug: slug}}} when not is_nil(id) ->
        {id, to_string(slug)}

      %{user: %{tenant_id: id}} when not is_nil(id) ->
        {id, nil}

      _ ->
        {nil, nil}
    end
  end

  # Compute connected agents from local cache with activity status
  # Platform admins see all agents, regular users see only their tenant's agents
  defp compute_connected_agents(agents_cache, is_platform_admin, tenant_info) do
    {tenant_id, tenant_slug} =
      case tenant_info do
        {id, slug} -> {id, slug}
        id when is_binary(id) -> {id, nil}
        _ -> {nil, nil}
      end

    # Use wall-clock time (system_time) for accurate distributed staleness detection
    now_ms = System.system_time(:millisecond)

    agents_cache
    |> Map.values()
    |> Enum.filter(&agent_visible?(&1, is_platform_admin, tenant_id, tenant_slug))
    |> Enum.map(fn agent ->
      Map.put(agent, :active, agent_active?(agent, now_ms))
    end)
    |> Enum.sort_by(& &1.agent_id)
  end

  defp agent_active?(agent, now_ms) do
    last_seen_ms = agent_last_seen_ms(agent)

    cond do
      is_integer(last_seen_ms) ->
        max(now_ms - last_seen_ms, 0) < @stale_threshold_ms

      is_integer(agent[:last_seen_mono]) ->
        now_mono = System.monotonic_time(:millisecond)
        max(now_mono - agent[:last_seen_mono], 0) < @stale_threshold_ms

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

  defp agent_visible?(_agent, true, _tenant_id, _tenant_slug), do: true

  defp agent_visible?(agent, false, tenant_id, tenant_slug) do
    # Match by tenant_id OR tenant_slug (agents may have one or both)
    agent_tenant_id = Map.get(agent, :tenant_id)
    agent_tenant_slug = Map.get(agent, :tenant_slug)

    cond do
      # Match by tenant_id if both have it
      tenant_id != nil and agent_tenant_id != nil ->
        to_string(agent_tenant_id) == to_string(tenant_id)

      # Match by tenant_slug if both have it
      tenant_slug != nil and agent_tenant_slug != nil ->
        to_string(agent_tenant_slug) == to_string(tenant_slug)

      # No match possible
      true ->
        false
    end
  end

  # Detect node type based on node name prefix
  defp detect_node_type(node_str) when is_binary(node_str) do
    cond do
      String.starts_with?(node_str, "serviceradar_core") -> :core
      String.starts_with?(node_str, "serviceradar_agent_gateway") -> :gateway
      String.starts_with?(node_str, "serviceradar_web") -> :web
      true -> :unknown
    end
  end

  defp format_time(nil), do: "—"
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_time(_), do: "—"
end
