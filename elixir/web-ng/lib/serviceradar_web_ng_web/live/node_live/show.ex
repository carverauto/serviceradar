defmodule ServiceRadarWebNGWeb.NodeLive.Show do
  @moduledoc """
  LiveView for showing individual cluster node details.

  A generic node details page that adapts based on node type (core, gateway, agent, web).
  Shows system information, memory usage, process counts, and node-type-specific information.
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadarWebNGWeb.Settings.Shell

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Node Details")
     |> assign(:node_name, nil)
     |> assign(:node, nil)
     |> assign(:node_info, nil)
     |> assign(:node_type, :unknown)
     |> assign(:error, nil)
     |> assign(:srql, %{enabled: false, page_path: "/settings/cluster/nodes"})}
  end

  @impl true
  def handle_params(%{"node_name" => node_name}, _uri, socket) do
    # Parse node name safely — avoid creating atoms from user input
    node_atom =
      try do
        String.to_existing_atom(node_name)
      rescue
        ArgumentError -> nil
      end

    if is_nil(node_atom) do
      {:noreply,
       socket
       |> assign(:node_name, node_name)
       |> assign(:node, nil)
       |> assign(:node_type, detect_node_type(node_name))
       |> assign(:node_info, nil)
       |> assign(:is_connected, false)
       |> assign(:is_current, false)
       |> assign(:gateways, [])
       |> assign(:agents, [])
       |> assign(:error, "Unknown node: #{node_name}")
       |> assign(:srql, %{enabled: false, page_path: "/settings/cluster/nodes/#{node_name}"})}
    else
      node_type = detect_node_type(node_name)

      # Check if node is reachable
      is_connected = node_atom == Node.self() or node_atom in Node.list()

      # Get system info if connected
      node_info =
        if is_connected do
          fetch_node_info(node_atom)
        end

      # Get node-type-specific info
      {gateways, agents} =
        if is_connected do
          {
            get_node_gateways(node_atom),
            get_node_agents(node_atom)
          }
        else
          {[], []}
        end

      error = if is_connected, do: nil, else: "Node is not connected to the cluster"

      {:noreply,
       socket
       |> assign(:node_name, node_name)
       |> assign(:node, node_atom)
       |> assign(:node_type, node_type)
       |> assign(:node_info, node_info)
       |> assign(:is_connected, is_connected)
       |> assign(:is_current, node_atom == Node.self())
       |> assign(:gateways, gateways)
       |> assign(:agents, agents)
       |> assign(:error, error)
       |> assign(:srql, %{enabled: false, page_path: "/settings/cluster/nodes/#{node_name}"})}
    end
  end

  defp detect_node_type(node_name) when is_binary(node_name) do
    # Note: Go agents connect via gRPC to agent gateways, not ERTS
    cond do
      String.starts_with?(node_name, "serviceradar_core") -> :core
      String.starts_with?(node_name, "serviceradar_agent_gateway") -> :gateway
      String.starts_with?(node_name, "serviceradar_web") -> :web
      true -> :unknown
    end
  end

  defp fetch_node_info(node) when is_atom(node) do
    memory = :rpc.call(node, :erlang, :memory, [], 5000)
    {uptime_ms, _} = :rpc.call(node, :erlang, :statistics, [:wall_clock], 5000)

    %{
      process_count: :rpc.call(node, :erlang, :system_info, [:process_count], 5000),
      port_count: :rpc.call(node, :erlang, :system_info, [:port_count], 5000),
      otp_release: to_string(:rpc.call(node, :erlang, :system_info, [:otp_release], 5000)),
      schedulers: :rpc.call(node, :erlang, :system_info, [:schedulers], 5000),
      schedulers_online: :rpc.call(node, :erlang, :system_info, [:schedulers_online], 5000),
      uptime_ms: uptime_ms,
      memory_total: memory[:total],
      memory_processes: memory[:processes],
      memory_system: memory[:system],
      memory_atom: memory[:atom],
      memory_binary: memory[:binary],
      memory_code: memory[:code],
      memory_ets: memory[:ets]
    }
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp get_node_gateways(node) do
    Enum.filter(ServiceRadar.GatewayRegistry.all_gateways(), fn gateway -> Map.get(gateway, :node) == node end)
  rescue
    _ -> []
  end

  defp get_node_agents(node) do
    Enum.filter(ServiceRadar.AgentRegistry.all_agents(), fn agent -> Map.get(agent, :node) == node end)
  rescue
    _ -> []
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      srql={@srql}
      current_path={~p"/settings/cluster/nodes/#{@node_name}"}
    >
      <Shell.settings_chrome
        current_path={~p"/settings/cluster/nodes/#{@node_name}"}
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <div class="mx-auto max-w-4xl p-6">
          <.header>
            Node Details
            <:subtitle>
              <span class="font-mono text-xs">{@node_name}</span>
            </:subtitle>
            <:actions>
              <.ui_button href={~p"/settings/cluster"} variant="ghost" size="sm">
                Back to cluster
              </.ui_button>
            </:actions>
          </.header>

          <div
            :if={@error && !@is_connected}
            class="rounded-xl border border-error/30 bg-error/5 p-6 text-center"
          >
            <p class="text-sm text-error">{@error}</p>
          </div>

          <div class="space-y-4">
            <!-- Connection Status Banner -->
            <div
              :if={@is_connected}
              class="rounded-lg bg-success/10 border border-success/30 p-3 flex items-center gap-3"
            >
              <span class="size-2.5 rounded-full bg-success animate-pulse"></span>
              <span class="text-sm text-success font-medium">Connected</span>
              <.ui_badge :if={@is_current} size="sm" variant="primary">Current Node</.ui_badge>
              <span class="text-xs text-sr-muted">Node is connected to the cluster</span>
            </div>
            <div
              :if={!@is_connected}
              class="rounded-lg bg-error/10 border border-error/30 p-3 flex items-center gap-3"
            >
              <span class="size-2.5 rounded-full bg-error"></span>
              <span class="text-sm text-error font-medium">Disconnected</span>
              <span class="text-xs text-sr-muted">Node is not reachable</span>
            </div>

            <.node_summary node_name={@node_name} node_type={@node_type} is_connected={@is_connected} />
            <.node_system_info :if={@node_info} node_info={@node_info} node={@node_name} />

            <!-- Gateway-specific info -->
            <.gateways_on_node :if={@node_type == :gateway && @gateways != []} gateways={@gateways} />

            <!-- Agent-specific info -->
            <.agents_on_node :if={@node_type == :agent && @agents != []} agents={@agents} />

            <!-- Node Role Description -->
            <.node_role_card node_type={@node_type} />
          </div>
        </div>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  attr :node_name, :string, required: true
  attr :node_type, :atom, required: true
  attr :is_connected, :boolean, required: true

  defp node_summary(assigns) do
    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface p-6">
      <div class="flex flex-wrap gap-x-8 gap-y-4">
        <div class="flex flex-col gap-1">
          <span class="text-xs text-sr-muted uppercase tracking-wider">Status</span>
          <.ui_badge variant={if @is_connected, do: "success", else: "error"} size="sm">
            {if @is_connected, do: "Connected", else: "Disconnected"}
          </.ui_badge>
        </div>

        <div class="flex flex-col gap-1">
          <span class="text-xs text-sr-muted uppercase tracking-wider">Node Type</span>
          <.node_type_badge type={@node_type} />
        </div>

        <div class="flex flex-col gap-1">
          <span class="text-xs text-sr-muted uppercase tracking-wider">Full Name</span>
          <span class="text-sm font-mono">{@node_name}</span>
        </div>

        <div class="flex flex-col gap-1">
          <span class="text-xs text-sr-muted uppercase tracking-wider">Short Name</span>
          <span class="text-sm font-mono">{String.split(@node_name, "@") |> List.first()}</span>
        </div>

        <div class="flex flex-col gap-1">
          <span class="text-xs text-sr-muted uppercase tracking-wider">Host</span>
          <span class="text-sm font-mono">{String.split(@node_name, "@") |> List.last()}</span>
        </div>
      </div>
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
    <.ui_badge variant={@variant} size="sm">{@label}</.ui_badge>
    """
  end

  attr :node_info, :map, required: true
  attr :node, :string, required: true

  defp node_system_info(assigns) do
    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line flex items-center justify-between">
        <span class="text-sm font-semibold">System Information</span>
        <.ui_badge size="sm" variant="ghost" class="font-mono">{@node}</.ui_badge>
      </div>
      <div class="p-4 grid grid-cols-2 md:grid-cols-4 gap-4">
        <div class="stat bg-sr-subtle/30 rounded-lg p-3">
          <div class="sr-ui-stat-title text-xs">Uptime</div>
          <div class="sr-ui-stat-value text-lg">{format_uptime(@node_info.uptime_ms)}</div>
        </div>

        <div class="stat bg-sr-subtle/30 rounded-lg p-3">
          <div class="sr-ui-stat-title text-xs">Processes</div>
          <div class="sr-ui-stat-value text-lg">{@node_info.process_count}</div>
        </div>

        <div class="stat bg-sr-subtle/30 rounded-lg p-3">
          <div class="sr-ui-stat-title text-xs">Schedulers</div>
          <div class="sr-ui-stat-value text-lg">
            {@node_info.schedulers_online}/{@node_info.schedulers}
          </div>
        </div>

        <div class="stat bg-sr-subtle/30 rounded-lg p-3">
          <div class="sr-ui-stat-title text-xs">OTP Release</div>
          <div class="sr-ui-stat-value text-lg">OTP {@node_info.otp_release}</div>
        </div>
      </div>

      <div class="px-4 pb-4">
        <div class="text-xs text-sr-muted mb-2">Memory Usage</div>
        <div class="grid grid-cols-2 md:grid-cols-4 gap-2">
          <.memory_stat label="Total" bytes={@node_info.memory_total} />
          <.memory_stat label="Processes" bytes={@node_info.memory_processes} />
          <.memory_stat label="System" bytes={@node_info.memory_system} />
          <.memory_stat label="Code" bytes={@node_info.memory_code} />
          <.memory_stat label="ETS" bytes={@node_info.memory_ets} />
          <.memory_stat label="Binary" bytes={@node_info.memory_binary} />
          <.memory_stat label="Atom" bytes={@node_info.memory_atom} />
          <.memory_stat label="Ports" count={@node_info.port_count} />
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :bytes, :integer, default: nil
  attr :count, :integer, default: nil

  defp memory_stat(assigns) do
    ~H"""
    <div class="bg-sr-subtle/30 rounded px-2 py-1">
      <div class="text-xs text-sr-muted">{@label}</div>
      <div class="font-mono text-sm">
        <%= if @bytes do %>
          {format_bytes(@bytes)}
        <% else %>
          {@count}
        <% end %>
      </div>
    </div>
    """
  end

  attr :gateways, :list, required: true

  defp gateways_on_node(assigns) do
    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line">
        <span class="text-sm font-semibold">Gateways on this Node</span>
        <.ui_badge size="sm" variant="info" class="ml-2">{length(@gateways)}</.ui_badge>
      </div>
      <div class="divide-y divide-sr-line">
        <%= for gateway <- @gateways do %>
          <div class="px-4 py-3 flex items-center gap-4">
            <.ui_badge variant="info" size="xs">{Map.get(gateway, :status, :unknown)}</.ui_badge>
            <div class="flex-1">
              <span class="font-mono text-sm">{Map.get(gateway, :partition_id, "default")}</span>
            </div>
            <.ui_button
              navigate={~p"/gateways/#{format_gateway_id(gateway)}"}
              size="xs"
              variant="ghost"
            >
              View
            </.ui_button>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :agents, :list, required: true

  defp agents_on_node(assigns) do
    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line">
        <span class="text-sm font-semibold">Agents on this Node</span>
        <.ui_badge size="sm" variant="success" class="ml-2">{length(@agents)}</.ui_badge>
      </div>
      <div class="divide-y divide-sr-line">
        <%= for agent <- @agents do %>
          <div class="px-4 py-3 flex items-center gap-4">
            <.ui_badge variant="success" size="xs">{Map.get(agent, :status, :unknown)}</.ui_badge>
            <div class="flex-1">
              <span class="font-mono text-sm">{Map.get(agent, :agent_id, "unknown")}</span>
            </div>
            <.ui_button navigate={~p"/agents/#{Map.get(agent, :agent_id)}"} size="xs" variant="ghost">
              View
            </.ui_button>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :node_type, :atom, required: true

  defp node_role_card(assigns) do
    role_info =
      case assigns.node_type do
        :core ->
          %{
            description:
              "Core nodes coordinate the distributed cluster, manage Horde registries, and process monitoring results.",
            steps: [
              %{label: "COORDINATE", description: "Manage cluster membership"},
              %{label: "REGISTRY", description: "Host Horde registries"},
              %{label: "PROCESS", description: "Handle monitoring results"}
            ]
          }

        :gateway ->
          %{
            description:
              "Agent Gateway nodes receive status pushes from Go agents deployed in customer networks via gRPC/mTLS. They forward monitoring data to the core cluster.",
            steps: [
              %{label: "RECEIVE", description: "Accept gRPC status pushes from Go agents"},
              %{label: "PROCESS", description: "Validate and normalize status data"},
              %{label: "FORWARD", description: "Route data to core cluster for storage"}
            ]
          }

        :agent ->
          %{
            description:
              "Agent nodes host the Go agent processes that perform actual monitoring checks and connect to local checkers.",
            steps: [
              %{label: "RECEIVE", description: "Accept check requests from gateways"},
              %{label: "EXECUTE", description: "Perform ICMP, TCP, HTTP checks"},
              %{label: "REPORT", description: "Return results to gateway"}
            ]
          }

        :web ->
          %{
            description: "Web nodes serve the ServiceRadar web interface and handle user authentication.",
            steps: [
              %{label: "SERVE", description: "Host web interface"},
              %{label: "AUTH", description: "Handle authentication"},
              %{label: "API", description: "Provide REST/JSON API"}
            ]
          }

        _ ->
          %{
            description: "Unknown node type.",
            steps: []
          }
      end

    assigns = assign(assigns, :role_info, role_info)

    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line">
        <span class="text-sm font-semibold">Node Role</span>
      </div>
      <div class="p-4">
        <p class="text-sm text-sr-muted mb-3">
          {@role_info.description}
        </p>
        <div :if={@role_info.steps != []} class="grid grid-cols-1 md:grid-cols-3 gap-3">
          <%= for {step, index} <- Enum.with_index(@role_info.steps) do %>
            <div class="flex items-center gap-2 p-2 rounded-lg bg-sr-subtle/50">
              <.ui_badge size="sm" variant={step_badge_variant(index)}>{step.label}</.ui_badge>
              <span class="text-xs text-sr-muted">{step.description}</span>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp step_badge_variant(0), do: "info"
  defp step_badge_variant(1), do: "success"
  defp step_badge_variant(2), do: "primary"
  defp step_badge_variant(_), do: "ghost"

  defp format_gateway_id(gateway) do
    case Map.get(gateway, :key) do
      {_partition, node} when is_atom(node) -> Atom.to_string(node)
      key when is_atom(key) -> Atom.to_string(key)
      key when is_binary(key) -> key
      _ -> "unknown"
    end
  end

  defp format_uptime(nil), do: "—"

  defp format_uptime(ms) when is_integer(ms) do
    seconds = div(ms, 1000)
    minutes = div(seconds, 60)
    hours = div(minutes, 60)
    days = div(hours, 24)

    cond do
      days > 0 -> "#{days}d #{rem(hours, 24)}h"
      hours > 0 -> "#{hours}h #{rem(minutes, 60)}m"
      minutes > 0 -> "#{minutes}m #{rem(seconds, 60)}s"
      true -> "#{seconds}s"
    end
  end

  defp format_bytes(nil), do: "—"

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end
end
