defmodule ServiceRadarWebNGWeb.InfrastructureLive.Index do
  @moduledoc """
  Consolidated LiveView for pollers and agents.

  Shows both Horde-registered (live) and database-registered infrastructure
  components in a unified view.
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias Phoenix.LiveView.JS

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to cluster events for real-time updates
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "agent:registrations")
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "cluster:events")

      # Refresh every 30 seconds
      :timer.send_interval(:timer.seconds(30), self(), :refresh)
    end

    {:ok,
     socket
     |> assign(:page_title, "Infrastructure")
     |> assign(:active_tab, :overview)
     |> assign(:live_pollers, load_live_pollers())
     |> assign(:live_agents, load_live_agents())
     |> assign(:db_pollers, load_db_pollers(socket.assigns.current_scope))
     |> assign(:db_agents, load_db_agents(socket.assigns.current_scope))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = case params["tab"] do
      "pollers" -> :pollers
      "agents" -> :agents
      _ -> :overview
    end

    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply,
     socket
     |> assign(:live_pollers, load_live_pollers())
     |> assign(:live_agents, load_live_agents())}
  end

  def handle_info({:agent_registered, _metadata}, socket) do
    {:noreply, assign(socket, :live_agents, load_live_agents())}
  end

  def handle_info({:agent_disconnected, _agent_id}, socket) do
    {:noreply, assign(socket, :live_agents, load_live_agents())}
  end

  def handle_info({:node_up, _node}, socket) do
    {:noreply,
     socket
     |> assign(:live_pollers, load_live_pollers())
     |> assign(:live_agents, load_live_agents())}
  end

  def handle_info({:node_down, _node}, socket) do
    {:noreply,
     socket
     |> assign(:live_pollers, load_live_pollers())
     |> assign(:live_agents, load_live_agents())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:live_pollers, load_live_pollers())
     |> assign(:live_agents, load_live_agents())
     |> assign(:db_pollers, load_db_pollers(socket.assigns.current_scope))
     |> assign(:db_agents, load_db_agents(socket.assigns.current_scope))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-7xl p-6 space-y-6">
        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-base-content">Infrastructure</h1>
            <p class="text-sm text-base-content/60">
              Pollers and agents across the distributed cluster
            </p>
          </div>
          <.ui_button variant="ghost" size="sm" phx-click="refresh">
            <.icon name="hero-arrow-path" class="size-4" /> Refresh
          </.ui_button>
        </div>

        <!-- Summary Cards -->
        <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
          <.summary_card
            title="Live Pollers"
            value={length(@live_pollers)}
            icon="hero-cpu-chip"
            variant="info"
          />
          <.summary_card
            title="Live Agents"
            value={length(@live_agents)}
            icon="hero-cube"
            variant="success"
          />
          <.summary_card
            title="DB Pollers"
            value={length(@db_pollers)}
            icon="hero-circle-stack"
            variant="ghost"
          />
          <.summary_card
            title="DB Agents"
            value={length(@db_agents)}
            icon="hero-archive-box"
            variant="ghost"
          />
        </div>

        <!-- Tab Navigation -->
        <div class="tabs tabs-box">
          <.link
            patch={~p"/infrastructure"}
            class={["tab", @active_tab == :overview && "tab-active"]}
          >
            Overview
          </.link>
          <.link
            patch={~p"/infrastructure?tab=pollers"}
            class={["tab", @active_tab == :pollers && "tab-active"]}
          >
            Pollers
          </.link>
          <.link
            patch={~p"/infrastructure?tab=agents"}
            class={["tab", @active_tab == :agents && "tab-active"]}
          >
            Agents
          </.link>
        </div>

        <!-- Tab Content -->
        <div :if={@active_tab == :overview}>
          <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <!-- Live Pollers -->
            <.ui_panel>
              <:header>
                <div class="flex items-center gap-2">
                  <span class="text-sm font-semibold">Live Pollers</span>
                  <span class="badge badge-sm badge-info">{length(@live_pollers)}</span>
                </div>
              </:header>
              <.live_pollers_table pollers={@live_pollers} />
            </.ui_panel>

            <!-- Live Agents -->
            <.ui_panel>
              <:header>
                <div class="flex items-center gap-2">
                  <span class="text-sm font-semibold">Live Agents</span>
                  <span class="badge badge-sm badge-success">{length(@live_agents)}</span>
                </div>
              </:header>
              <.live_agents_table agents={@live_agents} />
            </.ui_panel>
          </div>
        </div>

        <div :if={@active_tab == :pollers} class="space-y-6">
          <.ui_panel>
            <:header>
              <div class="flex items-center gap-2">
                <span class="text-sm font-semibold">Live Pollers (Horde Registry)</span>
                <span class="badge badge-sm badge-info">{length(@live_pollers)}</span>
              </div>
            </:header>
            <.live_pollers_table pollers={@live_pollers} expanded={true} />
          </.ui_panel>

          <.ui_panel>
            <:header>
              <div class="flex items-center gap-2">
                <span class="text-sm font-semibold">Registered Pollers (Database)</span>
                <span class="badge badge-sm badge-ghost">{length(@db_pollers)}</span>
              </div>
            </:header>
            <.db_pollers_table pollers={@db_pollers} />
          </.ui_panel>
        </div>

        <div :if={@active_tab == :agents} class="space-y-6">
          <.ui_panel>
            <:header>
              <div class="flex items-center gap-2">
                <span class="text-sm font-semibold">Live Agents (Horde Registry)</span>
                <span class="badge badge-sm badge-success">{length(@live_agents)}</span>
              </div>
            </:header>
            <.live_agents_table agents={@live_agents} expanded={true} />
          </.ui_panel>

          <.ui_panel>
            <:header>
              <div class="flex items-center gap-2">
                <span class="text-sm font-semibold">Registered Agents (Database)</span>
                <span class="badge badge-sm badge-ghost">{length(@db_agents)}</span>
              </div>
            </:header>
            <.db_agents_table agents={@db_agents} />
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

  defp summary_card(assigns) do
    bg_class = case assigns.variant do
      "success" -> "bg-success/10 border-success/20"
      "warning" -> "bg-warning/10 border-warning/20"
      "error" -> "bg-error/10 border-error/20"
      "info" -> "bg-info/10 border-info/20"
      _ -> "bg-base-200/50 border-base-300"
    end

    icon_class = case assigns.variant do
      "success" -> "text-success"
      "warning" -> "text-warning"
      "error" -> "text-error"
      "info" -> "text-info"
      _ -> "text-base-content/50"
    end

    assigns = assign(assigns, bg_class: bg_class, icon_class: icon_class)

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

  attr :pollers, :list, required: true
  attr :expanded, :boolean, default: false

  defp live_pollers_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-sm">
        <thead>
          <tr class="text-xs uppercase tracking-wide text-base-content/60">
            <th>Status</th>
            <th>Partition</th>
            <th>Node</th>
            <th :if={@expanded}>Agents</th>
            <th :if={@expanded}>Last Heartbeat</th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@pollers == []}>
            <td colspan={if @expanded, do: 5, else: 3} class="text-center text-base-content/60 py-6">
              No live pollers connected
            </td>
          </tr>
          <%= for poller <- @pollers do %>
            <tr class="hover:bg-base-200/40">
              <td><.status_badge status={Map.get(poller, :status)} /></td>
              <td class="font-mono text-xs">{Map.get(poller, :partition_id) || "default"}</td>
              <td class="font-mono text-xs">{format_node(Map.get(poller, :node))}</td>
              <td :if={@expanded} class="text-center">{Map.get(poller, :agent_count, 0)}</td>
              <td :if={@expanded} class="font-mono text-xs">{format_time(Map.get(poller, :last_heartbeat))}</td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :agents, :list, required: true
  attr :expanded, :boolean, default: false

  defp live_agents_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-sm">
        <thead>
          <tr class="text-xs uppercase tracking-wide text-base-content/60">
            <th>Status</th>
            <th>Agent ID</th>
            <th>Partition</th>
            <th :if={@expanded}>Poller</th>
            <th :if={@expanded}>Capabilities</th>
            <th>Heartbeat</th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@agents == []}>
            <td colspan={if @expanded, do: 6, else: 4} class="text-center text-base-content/60 py-6">
              No live agents connected
            </td>
          </tr>
          <%= for agent <- @agents do %>
            <tr
              class="hover:bg-base-200/40 cursor-pointer"
              phx-click={JS.navigate(~p"/infrastructure/agents/#{agent.agent_id}")}
            >
              <td><.status_badge status={agent.status} /></td>
              <td class="font-mono text-xs max-w-[10rem] truncate">{agent.agent_id}</td>
              <td class="font-mono text-xs">{agent.partition_id || "default"}</td>
              <td :if={@expanded} class="font-mono text-xs">{format_node(agent.poller_node)}</td>
              <td :if={@expanded}>
                <div class="flex flex-wrap gap-1">
                  <%= for cap <- (agent.capabilities || []) |> Enum.take(3) do %>
                    <span class="badge badge-xs badge-outline">{cap}</span>
                  <% end %>
                  <span :if={length(agent.capabilities || []) > 3} class="badge badge-xs badge-ghost">
                    +{length(agent.capabilities) - 3}
                  </span>
                </div>
              </td>
              <td class="font-mono text-xs">{format_time(agent.last_heartbeat)}</td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :pollers, :list, required: true

  defp db_pollers_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-sm">
        <thead>
          <tr class="text-xs uppercase tracking-wide text-base-content/60">
            <th>ID</th>
            <th>Status</th>
            <th>Partition</th>
            <th>Last Seen</th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@pollers == []}>
            <td colspan="4" class="text-center text-base-content/60 py-6">
              No pollers in database
            </td>
          </tr>
          <%= for poller <- @pollers do %>
            <tr class="hover:bg-base-200/40">
              <td class="font-mono text-xs max-w-[10rem] truncate">{Map.get(poller, "id") || Map.get(poller, "poller_id")}</td>
              <td>
                <.ui_badge
                  variant={if Map.get(poller, "is_active") || Map.get(poller, "status") == "active", do: "success", else: "ghost"}
                  size="xs"
                >
                  {Map.get(poller, "status") || (if Map.get(poller, "is_active"), do: "Active", else: "Inactive")}
                </.ui_badge>
              </td>
              <td class="font-mono text-xs">{Map.get(poller, "partition") || "—"}</td>
              <td class="font-mono text-xs">{format_db_timestamp(Map.get(poller, "last_seen"))}</td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :agents, :list, required: true

  defp db_agents_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-sm">
        <thead>
          <tr class="text-xs uppercase tracking-wide text-base-content/60">
            <th>UID</th>
            <th>Name</th>
            <th>Type</th>
            <th>Poller</th>
            <th>Last Seen</th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@agents == []}>
            <td colspan="5" class="text-center text-base-content/60 py-6">
              No agents in database
            </td>
          </tr>
          <%= for agent <- @agents do %>
            <tr
              class="hover:bg-base-200/40 cursor-pointer"
              phx-click={JS.navigate(~p"/infrastructure/agents/#{Map.get(agent, "uid")}")}
            >
              <td class="font-mono text-xs max-w-[10rem] truncate">{Map.get(agent, "uid")}</td>
              <td class="text-xs">{Map.get(agent, "name") || "—"}</td>
              <td><.ui_badge variant="ghost" size="xs">{Map.get(agent, "type") || "Unknown"}</.ui_badge></td>
              <td class="font-mono text-xs">{Map.get(agent, "poller_id") || "—"}</td>
              <td class="font-mono text-xs">{format_db_timestamp(Map.get(agent, "last_seen_time"))}</td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :status, :atom, default: :unknown

  defp status_badge(assigns) do
    {label, variant} = case assigns.status do
      :available -> {"Available", "success"}
      :connected -> {"Connected", "success"}
      :busy -> {"Busy", "warning"}
      :draining -> {"Draining", "warning"}
      :unavailable -> {"Unavailable", "error"}
      :disconnected -> {"Disconnected", "error"}
      _ -> {"Unknown", "ghost"}
    end

    assigns = assign(assigns, label: label, variant: variant)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  # Data Loading

  defp load_live_pollers do
    ServiceRadar.PollerRegistry.all_pollers()
    |> Enum.map(fn poller ->
      %{
        poller_id: Map.get(poller, :poller_id) || Map.get(poller, :key),
        partition_id: Map.get(poller, :partition_id),
        node: Map.get(poller, :node),
        status: Map.get(poller, :status, :available),
        agent_count: Map.get(poller, :agent_count, 0),
        last_heartbeat: Map.get(poller, :last_heartbeat)
      }
    end)
    |> Enum.sort_by(& &1.poller_id)
  rescue
    _ -> []
  end

  defp load_live_agents do
    ServiceRadar.AgentRegistry.all_agents()
    |> Enum.map(fn agent ->
      %{
        agent_id: Map.get(agent, :agent_id) || Map.get(agent, :key),
        partition_id: Map.get(agent, :partition_id),
        poller_node: Map.get(agent, :poller_node),
        capabilities: Map.get(agent, :capabilities, []),
        status: Map.get(agent, :status, :unknown),
        connected_at: Map.get(agent, :connected_at),
        last_heartbeat: Map.get(agent, :last_heartbeat)
      }
    end)
    |> Enum.sort_by(& &1.agent_id)
  rescue
    _ -> []
  end

  defp load_db_pollers(current_scope) do
    query = "in:pollers limit:50"
    case srql_module().query(query, actor: build_actor(current_scope)) do
      {:ok, %{"results" => results}} -> results
      _ -> []
    end
  rescue
    _ -> []
  end

  defp load_db_agents(current_scope) do
    query = "in:agents limit:50"
    case srql_module().query(query, actor: build_actor(current_scope)) do
      {:ok, %{"results" => results}} -> results
      _ -> []
    end
  rescue
    _ -> []
  end

  defp build_actor(current_scope) do
    case current_scope do
      %{user: user} when not is_nil(user) ->
        %{
          id: user.id,
          tenant_id: user.tenant_id,
          role: user.role,
          email: user.email
        }
      _ -> nil
    end
  end

  # Formatters

  defp format_node(nil), do: "—"
  defp format_node(node) when is_atom(node), do: node |> Atom.to_string() |> String.split("@") |> List.first()
  defp format_node(node), do: to_string(node)

  defp format_time(nil), do: "—"
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_time(_), do: "—"

  defp format_db_timestamp(nil), do: "—"
  defp format_db_timestamp(""), do: "—"
  defp format_db_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
      _ -> ts
    end
  end
  defp format_db_timestamp(_), do: "—"

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
