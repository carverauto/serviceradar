defmodule ServiceRadarWebNGWeb.AgentLive.Show do
  @moduledoc """
  LiveView for showing individual OCSF agent details.

  Displays both live Horde registry data and rich node system information
  including memory usage, process counts, uptime, and capabilities.
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadar.Edge.AgentReleaseTarget
  alias ServiceRadar.Monitoring.ServiceCheck

  require Logger

  # Check types available for configuration
  @check_types [
    {"Ping (ICMP)", :ping},
    {"TCP Port", :tcp},
    {"HTTP/HTTPS", :http},
    {"DNS", :dns},
    {"gRPC", :grpc}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Agent Details")
     |> assign(:agent_uid, nil)
     |> assign(:agent, nil)
     |> assign(:error, nil)
     |> assign(:srql, %{enabled: false, page_path: "/agents"})
     |> assign(:checks, [])
     |> assign(:release_targets, [])
     |> assign(:live_agent, nil)
     |> assign(:node_info, nil)
     |> assign(:gateway_node_info, nil)
     |> assign(:show_check_modal, false)
     |> assign(:check_form, nil)
     |> assign(:check_types, @check_types)}
  end

  @impl true
  def handle_params(%{"uid" => uid}, _uri, socket) do
    scope = socket.assigns.current_scope

    # Load database record
    db_agent =
      case srql_module().query("in:agents uid:\"#{escape_value(uid)}\" limit:1", %{scope: scope}) do
        {:ok, %{"results" => [agent | _]}} when is_map(agent) ->
          Map.put(agent, "_source", "database")

        _ ->
          nil
      end

    live_agent = lookup_registry_agent(uid)

    Logger.debug("[AgentShow] Looking up agent uid=#{inspect(uid)}, live_agent=#{inspect(live_agent != nil)}")

    # Get gateway node system info if live agent exists
    gateway_node_info =
      if live_agent && Map.get(live_agent, :node) do
        fetch_node_info(Map.get(live_agent, :node))
      end

    # Convert registry data to agent map format (string keys for consistency)
    horde_agent =
      if live_agent do
        base = %{
          "uid" => uid,
          "agent_id" => Map.get(live_agent, :agent_id, uid),
          "status" => to_string(Map.get(live_agent, :status, :connected)),
          "capabilities" => Map.get(live_agent, :capabilities, []),
          "gateway_id" => Map.get(live_agent, :gateway_id),
          "gateway_node" => format_node(Map.get(live_agent, :node)),
          "partition_id" => Map.get(live_agent, :partition_id),
          "registered_at" => Map.get(live_agent, :registered_at),
          "last_heartbeat" => Map.get(live_agent, :last_heartbeat),
          "connected_at" => Map.get(live_agent, :connected_at),
          "spiffe_identity" => Map.get(live_agent, :spiffe_identity),
          "_source" => "registry"
        }

        case Map.get(live_agent, :pid) do
          pid when is_pid(pid) -> Map.put(base, "pid", inspect(pid))
          _ -> base
        end
      end

    # Prefer registry data (live) over database (may be stale)
    # Merge if both exist to get the most complete picture
    {agent, error} =
      case {horde_agent, db_agent} do
        {nil, nil} ->
          {nil, "Agent not found"}

        {horde, nil} ->
          {horde, nil}

        {nil, db} ->
          {db, nil}

        {horde, db} ->
          # Merge: DB provides more details, Horde provides live status
          {Map.merge(db, horde), nil}
      end

    # Load service checks for this agent
    checks = load_checks_for_agent(uid, scope)
    release_targets = load_release_targets_for_agent(uid, scope)

    {:noreply,
     socket
     |> assign(:agent_uid, uid)
     |> assign(:agent, agent)
     |> assign(:error, error)
     |> assign(:checks, checks)
     |> assign(:release_targets, release_targets)
     |> assign(:live_agent, live_agent)
     |> assign(:gateway_node_info, gateway_node_info)
     |> assign(:srql, %{enabled: false, page_path: "/agents/#{uid}"})}
  end

  defp lookup_registry_agent(uid) do
    case ServiceRadar.AgentRegistry.lookup(uid) do
      [{pid, metadata} | _] ->
        metadata
        |> Map.put(:pid, pid)
        |> Map.put(:agent_id, uid)

      [] ->
        nil
    end
  end

  defp format_node(nil), do: nil
  defp format_node(node) when is_atom(node), do: Atom.to_string(node)
  defp format_node(node), do: to_string(node)

  defp fetch_node_info(nil), do: nil

  # Parallelize RPC calls to prevent blocking LiveView if node is unresponsive
  defp fetch_node_info(node) when is_atom(node) do
    tasks = [
      Task.async(fn -> {:memory, :rpc.call(node, :erlang, :memory, [], 5000)} end),
      Task.async(fn ->
        {:wall_clock, :rpc.call(node, :erlang, :statistics, [:wall_clock], 5000)}
      end),
      Task.async(fn ->
        {:process_count, :rpc.call(node, :erlang, :system_info, [:process_count], 5000)}
      end),
      Task.async(fn ->
        {:port_count, :rpc.call(node, :erlang, :system_info, [:port_count], 5000)}
      end),
      Task.async(fn ->
        {:otp_release, :rpc.call(node, :erlang, :system_info, [:otp_release], 5000)}
      end),
      Task.async(fn ->
        {:schedulers, :rpc.call(node, :erlang, :system_info, [:schedulers], 5000)}
      end),
      Task.async(fn ->
        {:schedulers_online, :rpc.call(node, :erlang, :system_info, [:schedulers_online], 5000)}
      end)
    ]

    results = tasks |> Task.await_many(6000) |> Map.new()
    memory = results[:memory]
    {uptime_ms, _} = results[:wall_clock]

    %{
      process_count: results[:process_count],
      port_count: results[:port_count],
      otp_release: to_string(results[:otp_release]),
      schedulers: results[:schedulers],
      schedulers_online: results[:schedulers_online],
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

  defp load_checks_for_agent(agent_uid, scope) do
    case ServiceCheck
         |> Ash.Query.for_read(:by_agent, %{agent_uid: agent_uid})
         |> Ash.read(scope: scope) do
      {:ok, checks} -> checks
      {:error, _} -> []
    end
  end

  defp load_release_targets_for_agent(agent_uid, scope) do
    AgentReleaseTarget
    |> Ash.Query.for_read(:by_agent, %{agent_id: agent_uid})
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(5)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, targets} -> targets
      {:error, _} -> []
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-4xl p-6">
        <.header>
          Agent Details
          <:subtitle>
            <span class="font-mono text-xs">{@agent_uid}</span>
          </:subtitle>
          <:actions>
            <.ui_button href={~p"/agents"} variant="ghost" size="sm">
              Back to agents
            </.ui_button>
          </:actions>
        </.header>

        <div :if={@error} class="rounded-xl border border-error/30 bg-error/5 p-6 text-center">
          <p class="text-sm text-error">{@error}</p>
        </div>

        <div :if={is_map(@agent)} class="space-y-4">
          <!-- Live Status Banner -->
          <div
            :if={@live_agent}
            class="rounded-lg bg-success/10 border border-success/30 p-3 flex items-center gap-3"
          >
            <span class="size-2.5 rounded-full bg-success animate-pulse"></span>
            <span class="text-sm text-success font-medium">Live Agent</span>
            <span class="text-xs text-base-content/60">Connected via gateway registry</span>
          </div>
          <div
            :if={!@live_agent && Map.get(@agent, "_source") == "database"}
            class="rounded-lg bg-warning/10 border border-warning/30 p-3 flex items-center gap-3"
          >
            <span class="size-2.5 rounded-full bg-warning"></span>
            <span class="text-sm text-warning font-medium">Database Record</span>
            <span class="text-xs text-base-content/60">Agent not currently connected to cluster</span>
          </div>

          <.agent_summary agent={@agent} live_agent={@live_agent} />
          <.release_management_card agent={@agent} release_targets={@release_targets} />
          <.capabilities_card capabilities={Map.get(@agent, "capabilities", [])} />
          <.gateway_node_info
            :if={@gateway_node_info}
            node_info={@gateway_node_info}
            node={Map.get(@agent, "gateway_node")}
          />
          <.registration_info agent={@agent} />
          <.service_checks_card checks={@checks} agent_uid={@agent_uid} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :agent, :map, required: true
  attr :live_agent, :map, default: nil

  defp agent_summary(assigns) do
    type_id = Map.get(assigns.agent, "type_id") || 0
    type_name = ServiceRadar.Infrastructure.Agent.type_name(type_id)
    assigns = assign(assigns, :type_name, type_name)

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 p-6">
      <div class="flex flex-wrap gap-x-8 gap-y-4">
        <div class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Status</span>
          <.status_badge status={Map.get(@agent, "status")} />
        </div>

        <div class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Type</span>
          <.type_badge type_id={Map.get(@agent, "type_id")} />
        </div>

        <div class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Agent UID</span>
          <span class="text-sm font-mono">
            {Map.get(@agent, "uid") || Map.get(@agent, "agent_id") || "—"}
          </span>
        </div>

        <div :if={has_value?(@agent, "name")} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Name</span>
          <span class="text-sm">{Map.get(@agent, "name")}</span>
        </div>

        <div :if={has_value?(@agent, "version")} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Version</span>
          <span class="text-sm font-mono">{Map.get(@agent, "version")}</span>
        </div>

        <div :if={has_value?(@agent, "desired_version")} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Desired Version</span>
          <span class="text-sm font-mono">{Map.get(@agent, "desired_version")}</span>
        </div>

        <div :if={has_value?(@agent, "gateway_id")} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Gateway</span>
          <.link
            navigate={~p"/gateways/#{Map.get(@agent, "gateway_id")}"}
            class="text-sm font-mono link link-primary"
          >
            {Map.get(@agent, "gateway_id")}
          </.link>
        </div>

        <div :if={has_value?(@agent, "gateway_node")} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Gateway Node</span>
          <span class="text-sm font-mono text-xs">{Map.get(@agent, "gateway_node")}</span>
        </div>

        <div :if={has_value?(@agent, "partition_id")} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Partition</span>
          <span class="text-sm font-mono">{Map.get(@agent, "partition_id")}</span>
        </div>

        <div :if={has_value?(@agent, "ip")} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">IP Address</span>
          <span class="text-sm font-mono">{Map.get(@agent, "ip")}</span>
        </div>

        <div :if={has_value?(@agent, "pid")} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Process ID</span>
          <span class="text-sm font-mono text-xs">{Map.get(@agent, "pid")}</span>
        </div>
      </div>
    </div>
    """
  end

  attr :agent, :map, required: true
  attr :release_targets, :list, default: []

  defp release_management_card(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100">
      <div class="px-4 py-3 border-b border-base-200 flex items-center justify-between">
        <span class="text-sm font-semibold">Release Management</span>
        <.release_status_badge
          state={Map.get(@agent, "release_rollout_state")}
          last_error={Map.get(@agent, "last_update_error")}
        />
      </div>
      <div class="p-4 space-y-4">
        <div class="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-4">
          <.release_stat
            label="Current Version"
            value={Map.get(@agent, "version") || "—"}
            mono
          />
          <.release_stat
            label="Desired Version"
            value={Map.get(@agent, "desired_version") || "—"}
            mono
          />
          <.release_stat
            label="Last Update"
            value={format_timestamp(Map.get(@agent, "last_update_at"))}
          />
          <.release_stat
            label="Latest Error"
            value={Map.get(@agent, "last_update_error") || "—"}
          />
        </div>

        <div>
          <div class="mb-2 flex items-center gap-2">
            <span class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
              Recent Rollout Attempts
            </span>
            <span class="badge badge-ghost badge-sm">{length(@release_targets)}</span>
          </div>

          <div :if={@release_targets == []} class="rounded-lg bg-base-200/40 px-4 py-6 text-sm text-base-content/60">
            No rollout targets recorded for this agent yet.
          </div>

          <div :if={@release_targets != []} class="overflow-x-auto">
            <table class="table table-sm w-full">
              <thead>
                <tr>
                  <th>Desired</th>
                  <th>Status</th>
                  <th>Progress</th>
                  <th>Updated</th>
                  <th>Error</th>
                </tr>
              </thead>
              <tbody>
                <%= for target <- @release_targets do %>
                  <tr>
                    <td class="font-mono text-xs">{target.desired_version}</td>
                    <td>
                      <.release_status_badge state={target.status} last_error={target.last_error} />
                    </td>
                    <td class="text-xs">
                      {format_progress(target.progress_percent, target.last_status_message)}
                    </td>
                    <td class="font-mono text-xs">
                      {format_timestamp(target.updated_at || target.inserted_at)}
                    </td>
                    <td class="max-w-xs truncate text-xs" title={target.last_error || "—"}>
                      {target.last_error || "—"}
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :mono, :boolean, default: false

  defp release_stat(assigns) do
    ~H"""
    <div class="rounded-lg bg-base-200/40 p-3">
      <div class="text-xs uppercase tracking-wider text-base-content/50">{@label}</div>
      <div class={["mt-1 text-sm", @mono && "font-mono"]}>{@value}</div>
    </div>
    """
  end

  attr :capabilities, :list, required: true

  defp capabilities_card(assigns) do
    # Capability info accepts binary names and internally uses an existing-atom lookup.
    caps_with_info =
      Enum.map(assigns.capabilities || [], fn cap ->
        cap_name = if is_atom(cap), do: Atom.to_string(cap), else: to_string(cap)
        info = ServiceRadar.Infrastructure.Agent.capability_info(cap_name)
        {cap_name, info}
      end)

    assigns = assign(assigns, :caps_with_info, caps_with_info)

    ~H"""
    <div :if={@capabilities != []} class="rounded-xl border border-base-200 bg-base-100">
      <div class="px-4 py-3 border-b border-base-200">
        <span class="text-sm font-semibold">Capabilities</span>
        <span class="ml-2 badge badge-ghost badge-sm">{length(@capabilities)}</span>
      </div>
      <div class="p-4">
        <div class="grid grid-cols-2 md:grid-cols-3 gap-3">
          <%= for {cap, info} <- @caps_with_info do %>
            <div class="flex items-center gap-2 p-2 rounded-lg bg-base-200/50">
              <span class={"badge badge-#{info.color} badge-sm gap-1"}>
                <span class="uppercase font-bold">{cap}</span>
              </span>
              <span class="text-xs text-base-content/60">{info.description}</span>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :node_info, :map, required: true
  attr :node, :string, required: true

  defp gateway_node_info(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100">
      <div class="px-4 py-3 border-b border-base-200 flex items-center justify-between">
        <span class="text-sm font-semibold">Gateway Node System Information</span>
        <span class="badge badge-ghost badge-sm font-mono">{@node}</span>
      </div>
      <div class="p-4 grid grid-cols-2 md:grid-cols-4 gap-4">
        <!-- Uptime -->
        <div class="stat bg-base-200/30 rounded-lg p-3">
          <div class="stat-title text-xs">Uptime</div>
          <div class="stat-value text-lg">{format_uptime(@node_info.uptime_ms)}</div>
        </div>
        
    <!-- Processes -->
        <div class="stat bg-base-200/30 rounded-lg p-3">
          <div class="stat-title text-xs">Processes</div>
          <div class="stat-value text-lg">{@node_info.process_count}</div>
        </div>
        
    <!-- Schedulers -->
        <div class="stat bg-base-200/30 rounded-lg p-3">
          <div class="stat-title text-xs">Schedulers</div>
          <div class="stat-value text-lg">{@node_info.schedulers_online}/{@node_info.schedulers}</div>
        </div>
        
    <!-- OTP Release -->
        <div class="stat bg-base-200/30 rounded-lg p-3">
          <div class="stat-title text-xs">OTP Release</div>
          <div class="stat-value text-lg">OTP {@node_info.otp_release}</div>
        </div>
      </div>
      
    <!-- Memory breakdown -->
      <div class="px-4 pb-4">
        <div class="text-xs text-base-content/60 mb-2">Memory Usage</div>
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
    <div class="bg-base-200/30 rounded px-2 py-1">
      <div class="text-xs text-base-content/50">{@label}</div>
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

  attr :agent, :map, required: true

  defp registration_info(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100">
      <div class="px-4 py-3 border-b border-base-200">
        <span class="text-sm font-semibold">Registration Timeline</span>
      </div>
      <div class="p-4">
        <div class="flex flex-col gap-3">
          <div :if={has_value?(@agent, "registered_at")} class="flex items-center gap-3">
            <span class="size-2 rounded-full bg-success"></span>
            <span class="text-xs text-base-content/60 w-24">Registered</span>
            <span class="font-mono text-sm">
              {format_timestamp(Map.get(@agent, "registered_at"))}
            </span>
          </div>
          <div :if={has_value?(@agent, "connected_at")} class="flex items-center gap-3">
            <span class="size-2 rounded-full bg-info"></span>
            <span class="text-xs text-base-content/60 w-24">Connected</span>
            <span class="font-mono text-sm">{format_timestamp(Map.get(@agent, "connected_at"))}</span>
            <span class="text-xs text-base-content/40">
              ({time_ago(Map.get(@agent, "connected_at"))})
            </span>
          </div>
          <div :if={has_value?(@agent, "last_heartbeat")} class="flex items-center gap-3">
            <span class="size-2 rounded-full bg-info animate-pulse"></span>
            <span class="text-xs text-base-content/60 w-24">Last Heartbeat</span>
            <span class="font-mono text-sm">
              {format_timestamp(Map.get(@agent, "last_heartbeat"))}
            </span>
            <span class="text-xs text-base-content/40">
              ({time_ago(Map.get(@agent, "last_heartbeat"))})
            </span>
          </div>
          <div :if={has_value?(@agent, "first_seen_time")} class="flex items-center gap-3">
            <span class="size-2 rounded-full bg-base-content/30"></span>
            <span class="text-xs text-base-content/60 w-24">First Seen</span>
            <span class="font-mono text-sm">
              {format_timestamp(Map.get(@agent, "first_seen_time"))}
            </span>
          </div>
          <div :if={has_value?(@agent, "last_seen_time")} class="flex items-center gap-3">
            <span class="size-2 rounded-full bg-base-content/30"></span>
            <span class="text-xs text-base-content/60 w-24">Last Seen</span>
            <span class="font-mono text-sm">
              {format_timestamp(Map.get(@agent, "last_seen_time"))}
            </span>
            <span class="text-xs text-base-content/40">
              ({time_ago(Map.get(@agent, "last_seen_time"))})
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :checks, :list, required: true
  attr :agent_uid, :string, required: true

  defp service_checks_card(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100">
      <div class="px-4 py-3 border-b border-base-200 flex items-center justify-between">
        <div>
          <span class="text-sm font-semibold">Service Checks</span>
          <span :if={@checks != []} class="ml-2 badge badge-ghost badge-sm">{length(@checks)}</span>
        </div>
      </div>
      <div :if={@checks == []} class="p-4">
        <p class="text-sm text-base-content/60">No service checks configured for this agent.</p>
      </div>
      <div :if={@checks != []} class="divide-y divide-base-200">
        <%= for check <- @checks do %>
          <div class="px-4 py-3 flex items-center gap-4">
            <.check_type_badge type={check.check_type} />
            <div class="flex-1 min-w-0">
              <div class="font-medium text-sm truncate">{check.name}</div>
              <div class="text-xs text-base-content/60 truncate">{check.target}</div>
            </div>
            <div class="flex items-center gap-2">
              <span class="text-xs text-base-content/50">{check.interval_seconds}s</span>
              <.status_indicator enabled={check.enabled} />
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :type, :atom, required: true

  defp check_type_badge(assigns) do
    {label, color} =
      case assigns.type do
        :ping -> {"PING", "info"}
        :tcp -> {"TCP", "success"}
        :http -> {"HTTP", "warning"}
        :dns -> {"DNS", "info"}
        :grpc -> {"gRPC", "secondary"}
        _ -> {to_string(assigns.type), "ghost"}
      end

    assigns = assigns |> assign(:label, label) |> assign(:color, color)

    ~H"""
    <span class={"badge badge-#{@color} badge-sm uppercase font-bold w-14 justify-center"}>
      {@label}
    </span>
    """
  end

  attr :enabled, :boolean, required: true

  defp status_indicator(assigns) do
    ~H"""
    <span :if={@enabled} class="size-2 rounded-full bg-success" title="Enabled"></span>
    <span :if={!@enabled} class="size-2 rounded-full bg-base-content/30" title="Disabled"></span>
    """
  end

  attr :status, :any, default: nil

  defp status_badge(assigns) do
    {label, variant} =
      case assigns.status do
        "connected" -> {"Connected", "success"}
        :connected -> {"Connected", "success"}
        "disconnected" -> {"Disconnected", "error"}
        :disconnected -> {"Disconnected", "error"}
        "available" -> {"Available", "success"}
        :available -> {"Available", "success"}
        "busy" -> {"Busy", "warning"}
        :busy -> {"Busy", "warning"}
        true -> {"Active", "success"}
        false -> {"Inactive", "error"}
        _ -> {"Unknown", "ghost"}
      end

    assigns = assigns |> assign(:label, label) |> assign(:variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="sm">{@label}</.ui_badge>
    """
  end

  attr :state, :any, required: true
  attr :last_error, :string, default: nil

  defp release_status_badge(assigns) do
    {label, variant} =
      case normalize_release_state(assigns.state, assigns.last_error) do
        :pending -> {"Pending", "ghost"}
        :dispatched -> {"Dispatched", "info"}
        :downloading -> {"Downloading", "info"}
        :verifying -> {"Verifying", "info"}
        :staged -> {"Staged", "warning"}
        :restarting -> {"Restarting", "warning"}
        :healthy -> {"Healthy", "success"}
        :failed -> {"Failed", "error"}
        :rolled_back -> {"Rolled Back", "error"}
        :canceled -> {"Canceled", "ghost"}
        :error -> {"Error", "error"}
        _ -> {"Unknown", "ghost"}
      end

    assigns = assigns |> assign(:label, label) |> assign(:variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="sm">{@label}</.ui_badge>
    """
  end

  attr :type_id, :integer, default: 0

  defp type_badge(assigns) do
    type_id = assigns.type_id || 0
    type_name = ServiceRadar.Infrastructure.Agent.type_name(type_id)

    variant =
      case type_id do
        1 -> "error"
        4 -> "info"
        6 -> "warning"
        99 -> "ghost"
        _ -> "ghost"
      end

    assigns = assigns |> assign(:type_name, type_name) |> assign(:variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="sm">{@type_name}</.ui_badge>
    """
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

  defp format_timestamp(nil), do: "—"
  defp format_timestamp(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")

  defp format_timestamp(value) when is_binary(value) do
    value = String.trim(value)

    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        format_timestamp(dt)

      {:error, _} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, ndt} -> format_timestamp(DateTime.from_naive!(ndt, "Etc/UTC"))
          {:error, _} -> value
        end
    end
  end

  defp format_timestamp(value), do: inspect(value)

  defp time_ago(nil), do: ""

  defp time_ago(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  defp time_ago(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, dt, _} -> time_ago(dt)
      _ -> ""
    end
  end

  defp time_ago(_), do: ""

  defp format_progress(nil, nil), do: "—"
  defp format_progress(progress, nil) when is_integer(progress), do: "#{progress}%"
  defp format_progress(nil, message) when is_binary(message), do: message
  defp format_progress(progress, message) when is_integer(progress) and is_binary(message), do: "#{progress}% · #{message}"
  defp format_progress(_progress, message), do: message || "—"

  defp has_value?(map, key) do
    case Map.get(map, key) do
      nil -> false
      "" -> false
      [] -> false
      _ -> true
    end
  end

  defp escape_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp escape_value(other), do: escape_value(to_string(other))

  defp normalize_release_state(nil, last_error) when is_binary(last_error) and last_error != "", do: :error
  defp normalize_release_state(nil, _last_error), do: :unknown
  defp normalize_release_state("", last_error), do: normalize_release_state(nil, last_error)

  defp normalize_release_state(state, _last_error) when is_binary(state) do
    state
    |> String.trim()
    |> normalize_release_state_value()
  end

  defp normalize_release_state(state, _last_error) when is_atom(state), do: state
  defp normalize_release_state(_state, _last_error), do: :unknown

  defp normalize_release_state_value(""), do: :unknown
  defp normalize_release_state_value("pending"), do: :pending
  defp normalize_release_state_value("dispatched"), do: :dispatched
  defp normalize_release_state_value("downloading"), do: :downloading
  defp normalize_release_state_value("verifying"), do: :verifying
  defp normalize_release_state_value("staged"), do: :staged
  defp normalize_release_state_value("restarting"), do: :restarting
  defp normalize_release_state_value("healthy"), do: :healthy
  defp normalize_release_state_value("failed"), do: :failed
  defp normalize_release_state_value("rolled_back"), do: :rolled_back
  defp normalize_release_state_value("canceled"), do: :canceled
  defp normalize_release_state_value(_), do: :unknown

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
