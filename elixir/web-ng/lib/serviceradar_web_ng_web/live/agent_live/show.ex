defmodule ServiceRadarWebNGWeb.AgentLive.Show do
  @moduledoc """
  LiveView for showing individual OCSF agent details.

  Displays both live Horde registry data and rich node system information
  including memory usage, process counts, uptime, and capabilities.
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadar.Edge.AgentReleaseTarget
  alias ServiceRadar.Infrastructure.Agent, as: InfrastructureAgent
  alias ServiceRadar.Monitoring.ServiceCheck
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonStatus
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.RetiredNativeAddons
  alias ServiceRadarWebNG.AgentCapabilities
  alias ServiceRadarWebNG.Plugins.AddonRuntimePolicy
  alias ServiceRadarWebNG.RBAC

  require Ash.Query
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
     |> assign(:plugin_assignments, [])
     |> assign(:addon_assignments, [])
     |> assign(:addon_reconciliation, [])
     |> assign(:release_targets, [])
     |> assign(:config_status, nil)
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

    checks = load_checks_for_agent(uid, scope)
    plugin_assignments = load_plugin_assignments_for_agent(uid, scope)
    addon_assignments = load_addon_assignments_for_agent(uid, scope)
    addon_statuses = load_addon_statuses_for_agent(uid, scope)
    release_targets = load_release_targets_for_agent(uid, scope)
    config_status = load_config_status_for_agent(uid, scope)
    agent = hydrate_agent_release_fields(agent, release_targets)
    addon_reconciliation = build_addon_reconciliation(addon_assignments, addon_statuses, agent)

    {:noreply,
     socket
     |> assign(:agent_uid, uid)
     |> assign(:agent, agent)
     |> assign(:error, error)
     |> assign(:checks, checks)
     |> assign(:plugin_assignments, plugin_assignments)
     |> assign(:addon_assignments, addon_assignments)
     |> assign(:addon_reconciliation, addon_reconciliation)
     |> assign(:release_targets, release_targets)
     |> assign(:config_status, config_status)
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

  defp load_plugin_assignments_for_agent(agent_uid, scope) do
    PluginAssignment
    # This administrative history view intentionally shows every enrollment
    # of a reused UID. Security-sensitive config delivery uses the
    # partition-scoped :by_edge_principal action in AgentConfigGenerator.
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(agent_uid == ^agent_uid)
    |> Ash.Query.load(:plugin_package)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, assignments} ->
        assignments

      {:error, reason} ->
        Logger.warning("Failed to load plugin assignments for #{agent_uid}: #{inspect(reason)}")
        []
    end
  end

  defp load_addon_assignments_for_agent(agent_uid, scope) do
    AddonAssignment
    |> Ash.Query.for_read(:by_agent, %{agent_uid: agent_uid})
    |> Ash.Query.load(:addon_package)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, assignments} ->
        Enum.reject(assignments, &RetiredNativeAddons.retired?(&1.addon_id))

      {:error, reason} ->
        Logger.warning("Failed to load addon assignments for #{agent_uid}: #{inspect(reason)}")
        []
    end
  end

  defp load_addon_statuses_for_agent(agent_uid, scope) do
    AddonStatus
    |> Ash.Query.for_read(:by_agent, %{agent_uid: agent_uid})
    |> Ash.Query.sort(reported_at: :desc)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, statuses} ->
        Enum.reject(statuses, &RetiredNativeAddons.retired?(&1.addon_id))

      {:error, reason} ->
        Logger.warning("Failed to load addon statuses for #{agent_uid}: #{inspect(reason)}")
        []
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

  defp load_config_status_for_agent(agent_uid, scope) do
    InfrastructureAgent
    |> Ash.Query.filter(uid == ^agent_uid)
    |> Ash.read_one(scope: scope)
    |> case do
      {:ok, %InfrastructureAgent{} = record} ->
        %{
          health: record.config_health,
          acked_version: record.acked_config_version,
          acked_at: record.config_acked_at,
          pushed_version: record.pushed_config_version,
          pushed_at: record.config_pushed_at,
          sections: List.wrap(record.config_section_statuses)
        }

      {:error, reason} ->
        Logger.warning("Failed to load config status for #{agent_uid}: #{inspect(reason)}")
        nil

      _ ->
        nil
    end
  end

  defp hydrate_agent_release_fields(nil, _targets), do: nil
  defp hydrate_agent_release_fields(agent, []), do: agent

  defp hydrate_agent_release_fields(agent, targets) when is_map(agent) do
    latest = preferred_release_target(agent, targets)

    agent
    |> maybe_put_release_field("release_rollout_state", latest.status)
    |> maybe_put_release_field("desired_version", latest.desired_version)
    |> put_if_blank("version", latest.current_version)
    |> maybe_put_release_field(
      "last_update_at",
      latest.updated_at || latest.completed_at || latest.dispatched_at || latest.inserted_at
    )
    |> maybe_put_release_field("last_update_error", latest.last_error)
  end

  defp preferred_release_target(agent, targets) do
    current_version = Map.get(agent, "version")

    Enum.find(targets, fn target ->
      target.status == :healthy and version_matches?(target.current_version, current_version)
    end) ||
      Enum.find(targets, fn target ->
        target.status in [:pending, :dispatched, :downloading, :verifying, :staged, :restarting]
      end) ||
      List.first(targets)
  end

  defp maybe_put_release_field(map, key, value) do
    if stale_release_field?(map, key), do: Map.put(map, key, value), else: put_if_blank(map, key, value)
  end

  defp stale_release_field?(map, _key) do
    version_matches?(Map.get(map, "version"), Map.get(map, "desired_version")) and
      Map.get(map, "release_rollout_state") in ["failed", :failed, "rolled_back", :rolled_back]
  end

  defp put_if_blank(map, _key, value) when value in [nil, ""], do: map

  defp put_if_blank(map, key, value) do
    case Map.get(map, key) do
      nil -> Map.put(map, key, value)
      "" -> Map.put(map, key, value)
      _ -> map
    end
  end

  defp version_matches?(left, right) when is_binary(left) and is_binary(right) do
    String.trim(left) != "" and String.trim(left) == String.trim(right)
  end

  defp version_matches?(_, _), do: false

  defp agent_release_handoff_path(agent) do
    uid = Map.get(agent, "uid") || Map.get(agent, "agent_id")

    params =
      maybe_put_version(
        [{"cohort", "custom"}, {"agent_ids", uid}, {"notes", "Imported from /agents/#{uid}"}, {"source", "agent_detail"}],
        Map.get(agent, "desired_version")
      )

    "/settings/agents/releases?" <> URI.encode_query(params)
  end

  defp maybe_put_version(params, value) when value in [nil, ""], do: params
  defp maybe_put_version(params, value), do: [{"version", value} | params]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-6xl px-4 py-5 sm:px-6">
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
            <span class="text-xs text-sr-muted">Connected via gateway registry</span>
          </div>
          <div
            :if={!@live_agent && Map.get(@agent, "_source") == "database"}
            class="rounded-lg bg-warning/10 border border-warning/30 p-3 flex items-center gap-3"
          >
            <span class="size-2.5 rounded-full bg-warning"></span>
            <span class="text-sm text-warning font-medium">Database Record</span>
            <span class="text-xs text-sr-muted">Agent not currently connected to cluster</span>
          </div>

          <.agent_summary agent={@agent} live_agent={@live_agent} />
          <.config_apply_card
            config_status={@config_status}
            agent_uid={@agent_uid}
            timezone={@current_scope.user.timezone || "Etc/UTC"}
          />
          <.release_management_card
            agent={@agent}
            release_targets={@release_targets}
            current_scope={@current_scope}
            timezone={@current_scope.user.timezone || "Etc/UTC"}
          />
          <.capabilities_card
            capabilities={Map.get(@agent, "capabilities", [])}
            plugin_assignments={@plugin_assignments}
          />
          <.network_visibility_card
            :if={host_visibility_capable?(@agent)}
            agent={@agent}
            timezone={@current_scope.user.timezone || "Etc/UTC"}
          />
          <.gateway_node_info
            :if={@gateway_node_info}
            node_info={@gateway_node_info}
            node={Map.get(@agent, "gateway_node")}
          />
          <.registration_info
            agent={@agent}
            timezone={@current_scope.user.timezone || "Etc/UTC"}
          />
          <.plugin_assignments_card assignments={@plugin_assignments} />
          <.addon_assignments_card rows={@addon_reconciliation} />
          <.service_checks_card checks={@checks} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :agent, :map, required: true
  attr :live_agent, :map, default: nil

  defp agent_summary(assigns) do
    type_id = Map.get(assigns.agent, "type_id") || 0
    type_name = InfrastructureAgent.type_name(type_id)
    assigns = assign(assigns, :type_name, type_name)

    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface p-6">
      <div class="flex flex-wrap gap-x-8 gap-y-4">
        <div class="flex flex-col gap-1">
          <span class="text-xs text-sr-muted uppercase tracking-wider">Status</span>
          <.status_badge status={Map.get(@agent, "status")} />
        </div>

        <div class="flex flex-col gap-1">
          <span class="text-xs text-sr-muted uppercase tracking-wider">Type</span>
          <.type_badge type_id={Map.get(@agent, "type_id")} />
        </div>

        <div class="flex flex-col gap-1">
          <span class="text-xs text-sr-muted uppercase tracking-wider">Agent UID</span>
          <span class="text-sm font-mono">
            {Map.get(@agent, "uid") || Map.get(@agent, "agent_id") || "—"}
          </span>
        </div>

        <div :if={has_value?(@agent, "name")} class="flex flex-col gap-1">
          <span class="text-xs text-sr-muted uppercase tracking-wider">Name</span>
          <span class="text-sm">{Map.get(@agent, "name")}</span>
        </div>

        <div :if={has_value?(@agent, "host")} class="flex flex-col gap-1">
          <span class="text-xs text-sr-muted uppercase tracking-wider">Host</span>
          <span class="text-sm font-mono">{Map.get(@agent, "host")}</span>
        </div>

        <div :if={has_value?(@agent, "version")} class="flex flex-col gap-1">
          <span class="text-xs text-sr-muted uppercase tracking-wider">Version</span>
          <span class="text-sm font-mono">{Map.get(@agent, "version")}</span>
        </div>

        <div :if={has_value?(@agent, "desired_version")} class="flex flex-col gap-1">
          <span class="text-xs text-sr-muted uppercase tracking-wider">Desired Version</span>
          <span class="text-sm font-mono">{Map.get(@agent, "desired_version")}</span>
        </div>

        <div :if={has_value?(@agent, "gateway_id")} class="flex flex-col gap-1">
          <span class="text-xs text-sr-muted uppercase tracking-wider">Gateway</span>
          <.link
            navigate={~p"/gateways/#{Map.get(@agent, "gateway_id")}"}
            class="text-sm font-mono text-sr-brand hover:underline"
          >
            {Map.get(@agent, "gateway_id")}
          </.link>
        </div>

        <div :if={has_value?(@agent, "gateway_node")} class="flex flex-col gap-1">
          <span class="text-xs text-sr-muted uppercase tracking-wider">Gateway Node</span>
          <span class="text-sm font-mono text-xs">{Map.get(@agent, "gateway_node")}</span>
        </div>

        <div :if={has_value?(@agent, "partition_id")} class="flex flex-col gap-1">
          <span class="text-xs text-sr-muted uppercase tracking-wider">Partition</span>
          <span class="text-sm font-mono">{Map.get(@agent, "partition_id")}</span>
        </div>

        <div :if={has_value?(@agent, "ip")} class="flex flex-col gap-1">
          <span class="text-xs text-sr-muted uppercase tracking-wider">IP Address</span>
          <span class="text-sm font-mono">{Map.get(@agent, "ip")}</span>
        </div>

        <div :if={has_value?(@agent, "pid")} class="flex flex-col gap-1">
          <span class="text-xs text-sr-muted uppercase tracking-wider">Process ID</span>
          <span class="text-sm font-mono text-xs">{Map.get(@agent, "pid")}</span>
        </div>
      </div>
    </div>
    """
  end

  attr :agent, :map, required: true
  attr :release_targets, :list, default: []
  attr :current_scope, :any, required: true
  attr :timezone, :string, default: "Etc/UTC"

  defp release_management_card(assigns) do
    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line flex items-center justify-between">
        <div class="flex items-center gap-3">
          <span class="text-sm font-semibold">Release Management</span>
          <.release_status_badge
            state={Map.get(@agent, "release_rollout_state")}
            last_error={Map.get(@agent, "last_update_error")}
          />
        </div>
        <div
          :if={RBAC.can?(@current_scope, "settings.edge.manage")}
          class="flex flex-wrap items-center gap-2"
        >
          <.ui_button navigate={agent_release_handoff_path(@agent)} size="xs" variant="primary">
            <.icon name="hero-play" class="size-3.5" /> Roll Out This Agent
          </.ui_button>
          <.ui_button navigate={~p"/settings/agents/releases"} size="xs" variant="ghost">
            Manage Releases
          </.ui_button>
        </div>
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
          <.release_time_stat
            id={"agent-#{agent_resource_id(@agent)}-last-update-at"}
            label="Last Update"
            value={Map.get(@agent, "last_update_at")}
            timezone={@timezone}
          />
          <.release_stat
            label="Latest Error"
            value={Map.get(@agent, "last_update_error") || "—"}
          />
        </div>

        <div>
          <div class="mb-2 flex items-center gap-2">
            <span class="text-xs font-semibold uppercase tracking-wider text-sr-muted">
              Recent Rollout Attempts
            </span>
            <.ui_badge size="sm" variant="ghost">{length(@release_targets)}</.ui_badge>
          </div>

          <div
            :if={@release_targets == []}
            class="rounded-lg bg-sr-subtle/40 px-4 py-6 text-sm text-sr-muted"
          >
            No rollout targets recorded for this agent yet.
          </div>

          <div :if={@release_targets != []} class="overflow-x-auto">
            <table class={ui_table_class(size: "sm", class: "w-full")}>
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
                      <.user_time
                        id={"agent-release-target-#{target.id}-updated-at"}
                        value={target.updated_at || target.inserted_at}
                        timezone={@timezone}
                        style={:compact}
                      />
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
    <div class="rounded-lg bg-sr-subtle/40 p-3">
      <div class="text-xs uppercase tracking-wider text-sr-muted">{@label}</div>
      <div class={["mt-1 text-sm", @mono && "font-mono"]}>{@value}</div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :timezone, :string, required: true

  defp release_time_stat(assigns) do
    ~H"""
    <div class="rounded-lg bg-sr-subtle/40 p-3">
      <div class="text-xs uppercase tracking-wider text-sr-muted">{@label}</div>
      <.user_time
        id={@id}
        value={timestamp_value(@value)}
        timezone={@timezone}
        style={:compact}
        class="mt-1 text-sm"
      />
    </div>
    """
  end

  attr :capabilities, :list, required: true
  attr :plugin_assignments, :list, default: []

  defp capabilities_card(assigns) do
    capability_summary = AgentCapabilities.summarize(assigns.capabilities)

    # Capability info accepts binary names and internally uses an existing-atom lookup.
    available_caps =
      Enum.map(capability_summary.available, fn cap_name ->
        {cap_name, InfrastructureAgent.capability_info(cap_name)}
      end)

    plugin_caps = plugin_capability_rows(assigns.plugin_assignments)

    assigns =
      assigns
      |> assign(:available_caps, available_caps)
      |> assign(:unavailable_caps, capability_summary.unavailable)
      |> assign(:plugin_caps, plugin_caps)
      |> assign(:capability_count, capability_summary.total + length(plugin_caps))

    ~H"""
    <div :if={@capability_count > 0} class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="flex flex-wrap items-center justify-between gap-2 border-b border-sr-line px-4 py-3">
        <div class="flex items-center gap-2">
          <span class="text-sm font-semibold">Capabilities</span>
          <.ui_badge size="sm" variant="ghost">{@capability_count}</.ui_badge>
        </div>
        <.ui_badge :if={@unavailable_caps != []} size="sm" variant="warning">
          {length(@unavailable_caps)} unavailable
        </.ui_badge>
      </div>
      <div class="p-4 space-y-4">
        <div
          :if={@available_caps != []}
          class="grid overflow-hidden rounded-lg border border-sr-line sm:grid-cols-2"
        >
          <%= for {cap, info} <- @available_caps do %>
            <div class="min-w-0 border-b border-sr-line p-3 last:border-b-0 sm:[&:nth-last-child(-n+2)]:border-b-0 sm:[&:nth-child(odd)]:border-r">
              <div class="flex min-w-0 items-start gap-2">
                <span class="status status-success status-xs mt-1.5 shrink-0" title="Available"></span>
                <code class="min-w-0 break-all text-xs font-semibold text-sr-ink">{cap}</code>
              </div>
              <p class="mt-1 pl-4 text-xs leading-5 text-sr-muted">{info.description}</p>
            </div>
          <% end %>
        </div>

        <details
          :if={@unavailable_caps != []}
          class="sr-ui-collapse sr-ui-collapse-arrow rounded-lg bg-sr-subtle/40"
        >
          <summary class="sr-ui-collapse-title min-h-0 py-3 text-sm font-medium">
            Unavailable capability markers
            <.ui_badge size="sm" variant="warning" class="ml-2">
              {length(@unavailable_caps)}
            </.ui_badge>
          </summary>
          <div class="sr-ui-collapse-content pb-3">
            <ul class="divide-y divide-sr-line/60 rounded-md bg-sr-surface px-3">
              <li :for={cap <- @unavailable_caps} class="flex min-w-0 items-start gap-2 py-2">
                <span class="status status-warning status-xs mt-1.5 shrink-0" title="Unavailable"></span>
                <code class="min-w-0 break-all text-xs text-sr-muted">{cap}</code>
              </li>
            </ul>
          </div>
        </details>

        <div :if={@plugin_caps != []}>
          <div class="mb-2 text-xs font-semibold text-sr-muted">
            Plugin-provided
          </div>
          <div class="grid overflow-hidden rounded-lg border border-sr-line md:grid-cols-2">
            <%= for cap <- @plugin_caps do %>
              <div class="min-w-0 border-b border-sr-line p-3 last:border-b-0 md:[&:nth-last-child(-n+2)]:border-b-0 md:[&:nth-child(odd)]:border-r">
                <div class="flex min-w-0 items-start gap-2">
                  <code class="min-w-0 break-all text-xs font-semibold text-sr-ink">
                    {cap.name}
                  </code>
                  <.ui_badge :if={cap.enabled == false} size="xs" variant="ghost">disabled</.ui_badge>
                </div>
                <div class="mt-1 text-xs leading-5 text-sr-muted">{cap.description}</div>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :agent, :map, required: true
  attr :timezone, :string, default: "Etc/UTC"

  def network_visibility_card(assigns) do
    status = netprobe_sidecar_status(assigns.agent)
    bpf_state = host_visibility_bpf_state(assigns.agent, status)

    assigns =
      assigns
      |> assign(:visibility_surfaces, host_visibility_surfaces(assigns.agent))
      |> assign(:netprobe_status, status)
      |> assign(:bpf_state, bpf_state)

    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line flex items-center justify-between">
        <div class="flex items-center gap-2">
          <.icon name="hero-eye" class="size-4 text-sr-brand" />
          <span class="text-sm font-semibold">Host Network Visibility</span>
          <.ui_badge size="sm" variant="primary">host-network-visibility</.ui_badge>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <.ui_badge variant={bpf_state_variant(@bpf_state)} size="sm">
            BPF {bpf_state_label(@bpf_state)}
          </.ui_badge>
          <.ui_badge variant={sidecar_status_variant(@netprobe_status["state"])} size="sm">
            {sidecar_status_label(@netprobe_status["state"])}
          </.ui_badge>
        </div>
      </div>
      <div class="p-4 space-y-4">
        <div class="grid grid-cols-2 md:grid-cols-5 gap-3">
          <div class="rounded-lg bg-sr-subtle/40 p-3">
            <div class="text-xs uppercase tracking-wide text-sr-muted">Kernel BPF</div>
            <div class={["mt-1 text-sm font-semibold", bpf_state_class(@bpf_state)]}>
              {bpf_state_label(@bpf_state)}
            </div>
          </div>
          <div :for={surface <- @visibility_surfaces} class="rounded-lg bg-sr-subtle/40 p-3">
            <div class="text-xs uppercase tracking-wide text-sr-muted">{surface.label}</div>
            <div class="mt-1 text-sm font-semibold">{surface.status}</div>
          </div>
        </div>

        <div class="rounded-lg border border-sr-line bg-sr-subtle/20 p-3">
          <div class="mb-2 text-xs font-semibold uppercase tracking-wide text-sr-muted">
            Netprobe sidecar
          </div>
          <div class="grid grid-cols-2 md:grid-cols-5 gap-3 text-sm">
            <.agent_visibility_kv label="State" value={@netprobe_status["state"] || "unavailable"} />
            <.agent_visibility_kv label="PID" value={@netprobe_status["pid"]} mono />
            <.agent_visibility_kv
              label="Restarts"
              value={@netprobe_status["restart_count"] || 0}
              mono
            />
            <.agent_visibility_time_kv
              id={"agent-#{agent_resource_id(@agent)}-netprobe-last-health-at"}
              label="Last Health"
              value={@netprobe_status["last_health_at"]}
              timezone={@timezone}
            />
            <.agent_visibility_kv label="Last Error" value={@netprobe_status["last_error"] || "—"} />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :mono, :boolean, default: false

  defp agent_visibility_kv(assigns) do
    ~H"""
    <div>
      <div class="text-xs text-sr-muted">{@label}</div>
      <div class={["mt-1 truncate", @mono && "font-mono text-xs"]}>{@value || "—"}</div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :timezone, :string, required: true

  defp agent_visibility_time_kv(assigns) do
    ~H"""
    <div>
      <div class="text-xs text-sr-muted">{@label}</div>
      <.user_time
        id={@id}
        value={timestamp_value(@value)}
        timezone={@timezone}
        style={:compact}
        class="mt-1 truncate font-mono text-xs"
      />
    </div>
    """
  end

  attr :node_info, :map, required: true
  attr :node, :string, required: true

  defp gateway_node_info(assigns) do
    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line flex items-center justify-between">
        <span class="text-sm font-semibold">Gateway Node System Information</span>
        <.ui_badge size="sm" variant="ghost" class="font-mono">{@node}</.ui_badge>
      </div>
      <div class="p-4 grid grid-cols-2 md:grid-cols-4 gap-4">
        <!-- Uptime -->
        <div class="stat bg-sr-subtle/30 rounded-lg p-3">
          <div class="sr-ui-stat-title text-xs">Uptime</div>
          <div class="sr-ui-stat-value text-lg">{format_uptime(@node_info.uptime_ms)}</div>
        </div>

        <!-- Processes -->
        <div class="stat bg-sr-subtle/30 rounded-lg p-3">
          <div class="sr-ui-stat-title text-xs">Processes</div>
          <div class="sr-ui-stat-value text-lg">{@node_info.process_count}</div>
        </div>

        <!-- Schedulers -->
        <div class="stat bg-sr-subtle/30 rounded-lg p-3">
          <div class="sr-ui-stat-title text-xs">Schedulers</div>
          <div class="sr-ui-stat-value text-lg">
            {@node_info.schedulers_online}/{@node_info.schedulers}
          </div>
        </div>

        <!-- OTP Release -->
        <div class="stat bg-sr-subtle/30 rounded-lg p-3">
          <div class="sr-ui-stat-title text-xs">OTP Release</div>
          <div class="sr-ui-stat-value text-lg">OTP {@node_info.otp_release}</div>
        </div>
      </div>

      <!-- Memory breakdown -->
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

  attr :agent, :map, required: true
  attr :timezone, :string, default: "Etc/UTC"

  defp registration_info(assigns) do
    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line">
        <span class="text-sm font-semibold">Registration Timeline</span>
      </div>
      <div class="p-4">
        <div class="flex flex-col gap-3">
          <div :if={has_value?(@agent, "registered_at")} class="flex items-center gap-3">
            <span class="size-2 rounded-full bg-success"></span>
            <span class="text-xs text-sr-muted w-24">Registered</span>
            <.agent_timeline_time
              id={"agent-#{agent_resource_id(@agent)}-registered-at"}
              value={Map.get(@agent, "registered_at")}
              timezone={@timezone}
            />
          </div>
          <div :if={has_value?(@agent, "connected_at")} class="flex items-center gap-3">
            <span class="size-2 rounded-full bg-info"></span>
            <span class="text-xs text-sr-muted w-24">Connected</span>
            <.agent_timeline_time
              id={"agent-#{agent_resource_id(@agent)}-connected-at"}
              value={Map.get(@agent, "connected_at")}
              timezone={@timezone}
            />
            <span class="text-xs text-sr-muted">
              ({time_ago(Map.get(@agent, "connected_at"))})
            </span>
          </div>
          <div :if={has_value?(@agent, "last_heartbeat")} class="flex items-center gap-3">
            <span class="size-2 rounded-full bg-info animate-pulse"></span>
            <span class="text-xs text-sr-muted w-24">Last Heartbeat</span>
            <.agent_timeline_time
              id={"agent-#{agent_resource_id(@agent)}-last-heartbeat"}
              value={Map.get(@agent, "last_heartbeat")}
              timezone={@timezone}
            />
            <span class="text-xs text-sr-muted">
              ({time_ago(Map.get(@agent, "last_heartbeat"))})
            </span>
          </div>
          <div :if={has_value?(@agent, "first_seen_time")} class="flex items-center gap-3">
            <span class="size-2 rounded-full bg-sr-muted/30"></span>
            <span class="text-xs text-sr-muted w-24">First Seen</span>
            <.agent_timeline_time
              id={"agent-#{agent_resource_id(@agent)}-first-seen-at"}
              value={Map.get(@agent, "first_seen_time")}
              timezone={@timezone}
            />
          </div>
          <div :if={has_value?(@agent, "last_seen_time")} class="flex items-center gap-3">
            <span class="size-2 rounded-full bg-sr-muted/30"></span>
            <span class="text-xs text-sr-muted w-24">Last Seen</span>
            <.agent_timeline_time
              id={"agent-#{agent_resource_id(@agent)}-last-seen-at"}
              value={Map.get(@agent, "last_seen_time")}
              timezone={@timezone}
            />
            <span class="text-xs text-sr-muted">
              ({time_ago(Map.get(@agent, "last_seen_time"))})
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :value, :any, required: true
  attr :timezone, :string, required: true

  defp agent_timeline_time(assigns) do
    ~H"""
    <.user_time
      id={@id}
      value={timestamp_value(@value)}
      timezone={@timezone}
      style={:compact}
      class="font-mono text-sm"
    />
    """
  end

  @doc """
  Config-apply status card: last acked config version, per-section apply
  statuses from the agent's sectioned config ack, and config-apply health.
  Public so it can be unit-tested with render_component/2.
  """
  attr :config_status, :map, default: nil
  attr :agent_uid, :string, default: "agent"
  attr :timezone, :string, default: "Etc/UTC"

  def config_apply_card(assigns) do
    ~H"""
    <div id="config-apply" class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line flex items-center justify-between">
        <div class="flex items-center gap-2">
          <span class="text-sm font-semibold">Config Apply</span>
          <.ui_badge
            :if={@config_status}
            variant={config_health_badge_variant(@config_status.health)}
            size="xs"
          >
            {config_health_text(@config_status.health)}
          </.ui_badge>
        </div>
      </div>

      <div :if={is_nil(@config_status)} class="p-4">
        <p class="text-sm text-sr-muted">No config acknowledgement data recorded yet.</p>
      </div>

      <div :if={@config_status} class="p-4 space-y-4">
        <div class="grid gap-4 sm:grid-cols-2">
          <div>
            <div class="text-xs uppercase tracking-wide text-sr-muted">
              Last Acked Config Version
            </div>
            <div class="mt-1 font-mono text-sm break-all">
              {@config_status.acked_version || "never"}
            </div>
            <div :if={@config_status.acked_at} class="text-xs text-sr-muted">
              <.user_time
                id={"agent-#{@agent_uid}-config-acked-at"}
                value={timestamp_value(@config_status.acked_at)}
                timezone={@timezone}
                style={:compact}
              /> ({time_ago(@config_status.acked_at)})
            </div>
          </div>
          <div :if={config_ack_pending?(@config_status)}>
            <div class="text-xs uppercase tracking-wide text-sr-muted">
              Pushed, Not Yet Acked
            </div>
            <div class="mt-1 font-mono text-sm break-all text-warning">
              {@config_status.pushed_version}
            </div>
            <div :if={@config_status.pushed_at} class="text-xs text-sr-muted">
              since
              <.user_time
                id={"agent-#{@agent_uid}-config-pushed-at"}
                value={timestamp_value(@config_status.pushed_at)}
                timezone={@timezone}
                style={:compact}
              /> ({time_ago(@config_status.pushed_at)})
            </div>
          </div>
        </div>

        <div :if={@config_status.sections != []} class="overflow-x-auto">
          <table class={ui_table_class(size: "sm")}>
            <thead>
              <tr class="text-xs uppercase tracking-wide text-sr-muted">
                <th>Section</th>
                <th>Status</th>
                <th>Error</th>
                <th>Since</th>
              </tr>
            </thead>
            <tbody>
              <%= for section <- @config_status.sections do %>
                <tr>
                  <td class="font-mono text-xs">{config_section_field(section, "section")}</td>
                  <td>
                    <.ui_badge
                      variant={
                        config_section_badge_variant(config_section_field(section, "disposition"))
                      }
                      size="xs"
                    >
                      {config_section_text(config_section_field(section, "disposition"))}
                    </.ui_badge>
                  </td>
                  <td class="max-w-md text-xs break-all">
                    {config_section_field(section, "error") || "—"}
                  </td>
                  <td class="whitespace-nowrap text-xs">
                    <.user_time
                      id={"agent-#{@agent_uid}-config-section-#{config_section_dom_id(section)}-since"}
                      value={timestamp_value(config_section_field(section, "since"))}
                      timezone={@timezone}
                      style={:compact}
                    />
                    <span :if={time_ago(config_section_field(section, "since")) != ""}>
                      ({time_ago(config_section_field(section, "since"))})
                    </span>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>

        <p :if={@config_status.sections == []} class="text-sm text-sr-muted">
          No per-section detail (legacy whole-version acks).
        </p>
      </div>
    </div>
    """
  end

  defp config_ack_pending?(%{pushed_version: pushed, acked_version: acked}) do
    is_binary(pushed) and pushed != "" and pushed != acked
  end

  defp config_health_badge_variant(:unhealthy), do: "error"
  defp config_health_badge_variant(:healthy), do: "success"
  defp config_health_badge_variant("unhealthy"), do: "error"
  defp config_health_badge_variant("healthy"), do: "success"
  defp config_health_badge_variant(_health), do: "ghost"

  defp config_health_text(:unhealthy), do: "config unhealthy"
  defp config_health_text(:healthy), do: "healthy"
  defp config_health_text("unhealthy"), do: "config unhealthy"
  defp config_health_text("healthy"), do: "healthy"
  defp config_health_text(_health), do: "unknown"

  defp config_section_badge_variant("permanent_failure"), do: "error"
  defp config_section_badge_variant("transient_failure"), do: "warning"
  defp config_section_badge_variant("success"), do: "success"
  defp config_section_badge_variant(_disposition), do: "ghost"

  defp config_section_text("permanent_failure"), do: "permanent failure"
  defp config_section_text("transient_failure"), do: "transient failure"
  defp config_section_text("success"), do: "ok"
  defp config_section_text(other) when is_binary(other) and other != "", do: other
  defp config_section_text(_disposition), do: "unknown"

  defp config_section_field(section, key) when is_map(section) do
    case Map.get(section, key) do
      nil -> Map.get(section, config_section_atom_key(key))
      "" -> nil
      value -> value
    end
  end

  defp config_section_field(_section, _key), do: nil

  defp config_section_atom_key("section"), do: :section
  defp config_section_atom_key("disposition"), do: :disposition
  defp config_section_atom_key("error"), do: :error
  defp config_section_atom_key("since"), do: :since

  defp config_section_dom_id(section) do
    section
    |> config_section_field("section")
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "unknown"
      id -> id
    end
  end

  attr :rows, :list, required: true

  defp addon_assignments_card(assigns) do
    ~H"""
    <div id="addons" class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="flex flex-wrap items-center justify-between gap-3 border-b border-sr-line px-4 py-3">
        <div>
          <div class="flex items-center gap-2">
            <span class="text-sm font-semibold">Add-on status</span>
            <.ui_badge :if={@rows != []} size="sm" variant="ghost">{length(@rows)}</.ui_badge>
          </div>
          <p class="mt-0.5 text-xs text-sr-muted">
            Desired delivery and the runtime state reported by this agent
          </p>
        </div>
        <.ui_button navigate={~p"/settings/agents/addons"} size="xs" variant="ghost">
          Manage Add-ons
        </.ui_button>
      </div>

      <div :if={@rows == []} class="p-4">
        <p class="text-sm text-sr-muted">
          No assigned or reported add-ons for this agent.
        </p>
      </div>

      <ul :if={@rows != []} class="divide-y divide-sr-line p-0">
        <%= for row <- @rows do %>
          <% package = row.package %>
          <% status = row.status %>
          <% capabilities = addon_package_capabilities(package) %>
          <li class="px-4 py-4">
            <div class="min-w-0">
              <div class="grid min-w-0 gap-4 md:grid-cols-[minmax(0,1.35fr)_minmax(8rem,0.7fr)_minmax(8rem,0.7fr)_minmax(0,1.3fr)]">
                <div class="min-w-0">
                  <div class="flex min-w-0 items-start gap-2">
                    <span
                      class={[
                        "status status-sm mt-1 shrink-0",
                        addon_status_indicator_class(row.drift_state)
                      ]}
                      title={drift_state_text(row.drift_state)}
                    ></span>
                    <div class="min-w-0">
                      <div class="break-words text-sm font-medium">{addon_row_name(row)}</div>
                      <code class="block break-all text-xs text-sr-muted">{row.addon_id}</code>
                      <code class="mt-1 block text-xs text-sr-muted">
                        {addon_row_version(package, status)}
                      </code>
                    </div>
                  </div>
                </div>

                <div class="min-w-0">
                  <div class="mb-1 text-[11px] font-semibold text-sr-muted">Delivery</div>
                  <.ui_badge variant={management_mode_variant(row.management_mode)} size="xs">
                    {management_mode_text(row.management_mode)}
                  </.ui_badge>
                </div>

                <div class="min-w-0">
                  <div class="mb-1 text-[11px] font-semibold text-sr-muted">Runtime</div>
                  <.ui_badge variant={runtime_badge_variant(status)} size="xs">
                    {runtime_state_text(status)}
                  </.ui_badge>
                </div>

                <div class="min-w-0">
                  <div class="mb-1 text-[11px] font-semibold text-sr-muted">
                    Reconciliation
                  </div>
                  <.ui_badge variant={drift_badge_variant(row.drift_state)} size="xs">
                    {drift_state_text(row.drift_state)}
                  </.ui_badge>
                  <p
                    :if={row.drift_reason}
                    class={[
                      "mt-1 break-words text-[11px] leading-4",
                      drift_reason_class(row.drift_state)
                    ]}
                  >
                    {row.drift_reason}
                  </p>
                </div>
              </div>

              <details :if={capabilities != []} class="group mt-3 min-w-0 pl-0 md:pl-6">
                <summary class="flex w-fit cursor-pointer list-none items-center gap-1 text-[11px] text-sr-muted hover:text-sr-ink focus:outline-none">
                  <.icon
                    name="hero-chevron-right"
                    class="size-3 transition-transform group-open:rotate-90"
                  /> Package capabilities ({length(capabilities)})
                </summary>
                <div class="mt-2 grid gap-1 rounded-md bg-sr-subtle/40 p-2 sm:grid-cols-2">
                  <code
                    :for={cap <- capabilities}
                    class="min-w-0 break-all text-[10px] leading-4 text-sr-muted"
                  >
                    {cap}
                  </code>
                </div>
              </details>
            </div>
          </li>
        <% end %>
      </ul>
    </div>
    """
  end

  defp addon_assignment_package(%{addon_package: %AddonPackage{} = package}), do: package
  defp addon_assignment_package(_assignment), do: nil

  defp addon_package_name(%AddonPackage{name: name}, _assignment) when is_binary(name) and name != "", do: name

  defp addon_package_name(_package, assignment), do: assignment.addon_id

  defp addon_package_version(%AddonPackage{version: version}) when is_binary(version), do: version
  defp addon_package_version(_package), do: "—"

  defp addon_package_capabilities(%AddonPackage{capabilities: caps}) when is_list(caps), do: caps
  defp addon_package_capabilities(_package), do: []

  defp build_addon_reconciliation(assignments, statuses, agent) do
    statuses_by_addon = Map.new(statuses, &{&1.addon_id, &1})
    assigned_ids = MapSet.new(assignments, & &1.addon_id)

    assignment_rows =
      Enum.map(assignments, fn assignment ->
        package = addon_assignment_package(assignment)
        status = Map.get(statuses_by_addon, assignment.addon_id)
        {drift_state, drift_reason} = addon_drift(package, assignment, status, agent)

        %{
          addon_id: assignment.addon_id,
          assignment: assignment,
          package: package,
          status: status,
          assigned?: assignment.enabled,
          management_mode: :assignment,
          drift_state: drift_state,
          drift_reason: drift_reason
        }
      end)

    observed_only_rows =
      statuses
      |> Enum.reject(&MapSet.member?(assigned_ids, &1.addon_id))
      |> Enum.map(fn status ->
        management_mode = AddonRuntimePolicy.management_mode(status.addon_id, false)

        {drift_state, drift_reason} =
          case management_mode do
            :required -> addon_drift(nil, %{enabled: true}, status, agent)
            :observed -> {:observed_unmanaged, "Reported by the agent without an assignment or required-runtime policy."}
          end

        %{
          addon_id: status.addon_id,
          assignment: nil,
          package: nil,
          status: status,
          assigned?: false,
          management_mode: management_mode,
          drift_state: drift_state,
          drift_reason: drift_reason
        }
      end)

    assignment_rows ++ observed_only_rows
  end

  defp addon_drift(_package, %{enabled: false}, _status, _agent), do: {:disabled, nil}

  defp addon_drift(package, _assignment, %AddonStatus{} = status, agent) do
    cond do
      addon_arch_unsupported?(package, status, agent) ->
        {:arch_unsupported, "No package artifact matches the reported or agent platform."}

      status.active and AddonRuntimePolicy.resource_limit_warning?(status.degradation_reason) ->
        {:runtime_warning, status.degradation_reason}

      unhealthy_addon_status?(status) ->
        {:unhealthy, status.degradation_reason || "Agent reported the add-on as unhealthy."}

      not status.active ->
        {:assigned_not_active, status.degradation_reason || "Assignment exists, but the add-on is not active."}

      true ->
        {:healthy, nil}
    end
  end

  defp addon_drift(_package, _assignment, nil, _agent) do
    {:assigned_not_installed, "Assignment exists, but the agent has not reported installed or active status."}
  end

  defp unhealthy_addon_status?(%AddonStatus{state: state, degradation_reason: reason}) do
    state = state |> to_string() |> String.downcase()
    state in ["unhealthy", "degraded", "failed", "circuit_open"] or present_text(reason) != nil
  end

  defp addon_arch_unsupported?(%AddonPackage{artifacts: artifacts}, %AddonStatus{} = status, agent)
       when is_map(artifacts) and map_size(artifacts) > 0 do
    {agent_os, agent_arch} = agent_platform(agent)
    status_arch = present_text(status.arch)

    cond do
      present_text(agent_os) != nil and present_text(agent_arch) != nil ->
        not Map.has_key?(artifacts, "#{agent_os}/#{agent_arch}")

      status_arch != nil ->
        not Enum.any?(Map.keys(artifacts), &String.ends_with?(to_string(&1), "/#{status_arch}"))

      true ->
        false
    end
  end

  defp addon_arch_unsupported?(_package, _status, _agent), do: false

  defp agent_platform(agent) when is_map(agent) do
    metadata = Map.get(agent, "metadata") || Map.get(agent, :metadata) || %{}

    {
      metadata_value(metadata, ["os", :os]),
      metadata_value(metadata, ["arch", :arch])
    }
  end

  defp agent_platform(_agent), do: {nil, nil}

  defp metadata_value(metadata, keys) when is_map(metadata) do
    Enum.find_value(keys, &Map.get(metadata, &1))
  end

  defp metadata_value(_metadata, _keys), do: nil

  defp addon_row_name(%{package: %AddonPackage{} = package, assignment: assignment}) do
    addon_package_name(package, assignment)
  end

  defp addon_row_name(%{addon_id: addon_id}), do: addon_id

  defp addon_row_version(%AddonPackage{} = package, _status), do: addon_package_version(package)
  defp addon_row_version(_package, %AddonStatus{version: version}) when is_binary(version), do: version
  defp addon_row_version(_package, _status), do: "—"

  defp management_mode_variant(:assignment), do: "success"
  defp management_mode_variant(:required), do: "info"
  defp management_mode_variant(:observed), do: "warning"
  defp management_mode_variant(_mode), do: "ghost"

  defp management_mode_text(:assignment), do: "explicit assignment"
  defp management_mode_text(:required), do: "required runtime"
  defp management_mode_text(:observed), do: "unmanaged runtime"
  defp management_mode_text(_mode), do: "unknown"

  defp runtime_badge_variant(%AddonStatus{active: true}), do: "success"

  defp runtime_badge_variant(%AddonStatus{state: state}) when state in ["unhealthy", "failed", "circuit_open"],
    do: "error"

  defp runtime_badge_variant(%AddonStatus{}), do: "warning"
  defp runtime_badge_variant(nil), do: "ghost"

  defp runtime_state_text(%AddonStatus{active: true}), do: "running"
  defp runtime_state_text(%AddonStatus{state: state}) when is_binary(state), do: state
  defp runtime_state_text(%AddonStatus{}), do: "not active"
  defp runtime_state_text(nil), do: "not reported"

  defp drift_badge_variant(:healthy), do: "success"
  defp drift_badge_variant(:disabled), do: "ghost"
  defp drift_badge_variant(:observed_unmanaged), do: "warning"
  defp drift_badge_variant(:assigned_not_installed), do: "warning"
  defp drift_badge_variant(:assigned_not_active), do: "warning"
  defp drift_badge_variant(:runtime_warning), do: "warning"
  defp drift_badge_variant(:unhealthy), do: "error"
  defp drift_badge_variant(:arch_unsupported), do: "error"
  defp drift_badge_variant(_), do: "ghost"

  defp drift_state_text(:healthy), do: "in sync"
  defp drift_state_text(:disabled), do: "disabled"
  defp drift_state_text(:observed_unmanaged), do: "unmanaged"
  defp drift_state_text(:assigned_not_installed), do: "not installed"
  defp drift_state_text(:assigned_not_active), do: "not active"
  defp drift_state_text(:runtime_warning), do: "running with warning"
  defp drift_state_text(:unhealthy), do: "unhealthy"
  defp drift_state_text(:arch_unsupported), do: "arch unsupported"
  defp drift_state_text(state), do: to_string(state)

  defp addon_status_indicator_class(:healthy), do: "status-success"
  defp addon_status_indicator_class(:disabled), do: "status-neutral"

  defp addon_status_indicator_class(state)
       when state in [:observed_unmanaged, :assigned_not_installed, :assigned_not_active, :runtime_warning],
       do: "status-warning"

  defp addon_status_indicator_class(_state), do: "status-error"

  defp drift_reason_class(:runtime_warning), do: "text-warning"
  defp drift_reason_class(state) when state in [:unhealthy, :arch_unsupported], do: "text-error"
  defp drift_reason_class(_state), do: "text-sr-muted"

  attr :assignments, :list, required: true

  defp plugin_assignments_card(assigns) do
    ~H"""
    <div id="plugins" class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line flex items-center justify-between">
        <div>
          <span class="text-sm font-semibold">Plugin Assignments</span>
          <.ui_badge :if={@assignments != []} size="sm" variant="ghost" class="ml-2">
            {length(@assignments)}
          </.ui_badge>
        </div>
        <.ui_button navigate={~p"/settings/agents/plugins"} size="xs" variant="ghost">
          Manage Plugins
        </.ui_button>
      </div>

      <div :if={@assignments == []} class="p-4">
        <p class="text-sm text-sr-muted">No plugins assigned to this agent.</p>
      </div>

      <div :if={@assignments != []} class="overflow-x-auto">
        <table class={ui_table_class(size: "sm")}>
          <thead>
            <tr class="text-xs uppercase tracking-wide text-sr-muted">
              <th>Plugin</th>
              <th>Version</th>
              <th>Source</th>
              <th>Schedule</th>
              <th>Status</th>
              <th>Capabilities</th>
            </tr>
          </thead>
          <tbody>
            <%= for assignment <- @assignments do %>
              <% package = assignment_package(assignment) %>
              <tr>
                <td>
                  <div class="font-medium">{plugin_package_name(package)}</div>
                  <div class="text-xs font-mono text-sr-muted">
                    {plugin_package_id(package)}
                  </div>
                </td>
                <td class="text-xs font-mono">{plugin_package_version(package)}</td>
                <td class="text-xs">{format_assignment_source(assignment.source)}</td>
                <td class="text-xs">
                  every {assignment.interval_seconds}s, timeout {assignment.timeout_seconds}s
                </td>
                <td>
                  <.ui_badge variant={if assignment.enabled, do: "success", else: "ghost"} size="xs">
                    {if assignment.enabled, do: "enabled", else: "disabled"}
                  </.ui_badge>
                </td>
                <td>
                  <div class="flex max-w-md flex-wrap gap-1">
                    <%= for cap <- plugin_requested_capabilities(package) do %>
                      <.ui_badge size="xs" variant="ghost" class="font-mono">{cap}</.ui_badge>
                    <% end %>
                    <span
                      :if={plugin_requested_capabilities(package) == []}
                      class="text-xs text-sr-muted"
                    >
                      —
                    </span>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :checks, :list, required: true

  defp service_checks_card(assigns) do
    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="flex items-center justify-between border-b border-sr-line px-4 py-3">
        <div>
          <div class="flex items-center gap-2">
            <span class="text-sm font-semibold">Direct service checks</span>
            <.ui_badge :if={@checks != []} size="sm" variant="ghost">{length(@checks)}</.ui_badge>
          </div>
          <p class="mt-0.5 text-xs text-sr-muted">
            Ping, TCP, HTTP, DNS, and gRPC checks assigned directly to this agent
          </p>
        </div>
      </div>
      <div :if={@checks == []} class="p-4">
        <p class="text-sm text-sr-muted">
          No direct service checks are assigned. Add-on and plugin work is reported in the sections above.
        </p>
      </div>
      <div :if={@checks != []} class="divide-y divide-sr-line">
        <%= for check <- @checks do %>
          <div class="px-4 py-3 flex items-center gap-4">
            <.check_type_badge type={check.check_type} />
            <div class="flex-1 min-w-0">
              <div class="font-medium text-sm truncate">{check.name}</div>
              <div class="text-xs text-sr-muted truncate">{check.target}</div>
            </div>
            <div class="flex items-center gap-2">
              <span class="text-xs text-sr-muted">{check.interval_seconds}s</span>
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
    {label, variant} =
      case assigns.type do
        :ping -> {"PING", "info"}
        :tcp -> {"TCP", "success"}
        :http -> {"HTTP", "warning"}
        :dns -> {"DNS", "info"}
        :grpc -> {"gRPC", "ghost"}
        _ -> {to_string(assigns.type), "ghost"}
      end

    assigns = assigns |> assign(:label, label) |> assign(:variant, variant)

    ~H"""
    <.ui_badge size="sm" variant={@variant} class="w-14 uppercase font-bold">
      {@label}
    </.ui_badge>
    """
  end

  attr :enabled, :boolean, required: true

  defp status_indicator(assigns) do
    ~H"""
    <span :if={@enabled} class="size-2 rounded-full bg-success" title="Enabled"></span>
    <span :if={!@enabled} class="size-2 rounded-full bg-sr-muted/30" title="Disabled"></span>
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
    type_name = InfrastructureAgent.type_name(type_id)

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

  defp host_visibility_capable?(agent) when is_map(agent) do
    agent
    |> Map.get("capabilities", [])
    |> Enum.map(&normalize_capability/1)
    |> Enum.any?(&(&1 == "host-network-visibility" or String.starts_with?(&1, "host-network-visibility.")))
  end

  defp host_visibility_capable?(_agent), do: false

  defp host_visibility_surfaces(agent) do
    capabilities =
      agent
      |> Map.get("capabilities", [])
      |> Enum.map(&normalize_capability/1)

    [
      %{label: "Fingerprint", status: surface_status(capabilities, "fingerprint")},
      %{label: "DPI", status: surface_status(capabilities, "dpi")},
      %{label: "Flow Attribution", status: surface_status(capabilities, "flow-attribution")},
      %{label: "Process Snapshot", status: surface_status(capabilities, "process-snapshot")}
    ]
  end

  defp host_visibility_bpf_state(agent, netprobe_status) do
    explicit_state =
      agent
      |> host_visibility_bpf_candidates()
      |> Enum.find_value(&normalize_bpf_state/1)

    explicit_state ||
      if netprobe_sidecar_running?(netprobe_status) || host_visibility_surface_enabled?(agent) do
        :available
      else
        :unavailable
      end
  end

  defp host_visibility_bpf_candidates(agent) do
    metadata = metadata_map(agent)
    payload = host_visibility_payload(agent)
    agent = stringify_keys(agent)

    [
      Map.get(payload, "bpf"),
      Map.get(payload, "bpf_state"),
      Map.get(payload, "bpf_support"),
      Map.get(payload, "kernel_bpf"),
      Map.get(payload, "kernel_bpf_state"),
      Map.get(payload, "ebpf"),
      Map.get(payload, "flow_attribution_available"),
      Map.get(payload, "process_snapshot_available"),
      Map.get(metadata, "host_network_visibility.bpf"),
      Map.get(metadata, "host_network_visibility.bpf_state"),
      Map.get(metadata, "host_network_visibility.kernel_bpf"),
      Map.get(metadata, "host_network_visibility.kernel_bpf_state"),
      Map.get(agent, "bpf_state"),
      Map.get(agent, "kernel_bpf_state")
    ]
  end

  defp host_visibility_payload(agent) do
    metadata = metadata_map(agent)
    agent = stringify_keys(agent)

    metadata
    |> Map.get("host_network_visibility", Map.get(metadata, "hostNetworkVisibility"))
    |> case do
      nil -> Map.get(agent, "host_network_visibility", Map.get(agent, "hostNetworkVisibility"))
      value -> value
    end
    |> decode_map_payload()
  end

  defp decode_map_payload(%{} = payload), do: stringify_keys(payload)

  defp decode_map_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = decoded} -> stringify_keys(decoded)
      _ -> %{}
    end
  end

  defp decode_map_payload(_payload), do: %{}

  defp host_visibility_surface_enabled?(agent) do
    agent
    |> host_visibility_surfaces()
    |> Enum.any?(&(&1.status == "enabled"))
  end

  defp netprobe_sidecar_running?(%{} = status) do
    status
    |> Map.get("state", Map.get(status, :state))
    |> normalize_capability()
    |> Kernel.in(["healthy", "running"])
  end

  defp netprobe_sidecar_running?(_status), do: false

  defp normalize_bpf_state(nil), do: nil
  defp normalize_bpf_state(true), do: :available
  defp normalize_bpf_state(false), do: :unavailable

  defp normalize_bpf_state(value) do
    case normalize_capability(value) do
      state when state in ["available", "enabled", "healthy", "ready", "running", "supported", "true"] ->
        :available

      state
      when state in [
             "degraded",
             "disabled",
             "false",
             "missing",
             "not-available",
             "not-supported",
             "too-old",
             "unavailable",
             "unsupported"
           ] ->
        :unavailable

      _ ->
        nil
    end
  end

  defp bpf_state_label(:available), do: "available"
  defp bpf_state_label(_state), do: "unavailable"

  defp bpf_state_variant(:available), do: "success"
  defp bpf_state_variant(_state), do: "error"

  defp bpf_state_class(:available), do: "text-success"
  defp bpf_state_class(_state), do: "text-error"

  defp surface_status(capabilities, surface) do
    cond do
      "host-network-visibility.#{surface}.enabled" in capabilities ->
        "enabled"

      "host-network-visibility.#{surface}.unavailable" in capabilities ->
        "unavailable"

      true ->
        "unavailable"
    end
  end

  defp normalize_capability(capability) do
    capability
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace("_", "-")
  end

  defp netprobe_sidecar_status(agent) do
    sidecars =
      agent
      |> metadata_map()
      |> Map.get("sidecars", Map.get(agent, "sidecars", []))
      |> List.wrap()

    Enum.find_value(sidecars, default_netprobe_sidecar_status(), fn
      %{} = sidecar ->
        name = Map.get(sidecar, "name", Map.get(sidecar, :name))

        if normalize_capability(name) == "netprobe" do
          stringify_keys(sidecar)
        end

      _ ->
        nil
    end)
  end

  defp default_netprobe_sidecar_status do
    %{"name" => "netprobe", "state" => "unavailable"}
  end

  defp metadata_map(agent) when is_map(agent) do
    case Map.get(agent, "metadata") || Map.get(agent, :metadata) do
      %{} = metadata -> stringify_keys(metadata)
      _ -> %{}
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp sidecar_status_label(nil), do: "Unavailable"
  defp sidecar_status_label(""), do: "Unavailable"
  defp sidecar_status_label(state), do: state |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp sidecar_status_variant(state) when state in ["healthy", "running"], do: "success"
  defp sidecar_status_variant(state) when state in ["starting", "restarting"], do: "warning"
  defp sidecar_status_variant(state) when state in ["unhealthy", "failed", "circuit_open"], do: "error"
  defp sidecar_status_variant(_state), do: "ghost"

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

  defp timestamp_value(nil), do: nil
  defp timestamp_value(%DateTime{} = datetime), do: datetime

  defp timestamp_value(value) when is_integer(value) and value > 10_000_000_000_000,
    do: DateTime.from_unix!(value, :nanosecond)

  defp timestamp_value(value) when is_integer(value) and value > 0, do: DateTime.from_unix!(value, :second)

  defp timestamp_value(value) when is_binary(value) do
    value = String.trim(value)

    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        dt

      {:error, _} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
          {:error, _} -> nil
        end
    end
  end

  defp timestamp_value(_value), do: nil

  defp agent_resource_id(agent) do
    Enum.find(
      [Map.get(agent, "uid"), Map.get(agent, "agent_id"), Map.get(agent, "id")],
      "unknown",
      &(&1 not in [nil, ""])
    )
  end

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

  defp format_progress(progress, message) when is_integer(progress) and is_binary(message),
    do: "#{progress}% · #{message}"

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

  defp plugin_capability_rows(assignments) when is_list(assignments) do
    assignments
    |> Enum.map(fn assignment ->
      package = assignment_package(assignment)
      plugin_id = plugin_package_id(package)

      if plugin_id == "unknown" do
        nil
      else
        %{
          name: "plugin:#{plugin_id}",
          description: plugin_capability_description(package),
          enabled: assignment.enabled
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(& &1.name)
  end

  defp plugin_capability_rows(_assignments), do: []

  defp plugin_capability_description(package) do
    version = plugin_package_version(package)
    name = plugin_package_name(package)

    if version == "—" do
      "#{name} plugin assignment"
    else
      "#{name} plugin assignment, version #{version}"
    end
  end

  defp assignment_package(%{plugin_package: %Ash.NotLoaded{}}), do: nil
  defp assignment_package(%{plugin_package: package}) when is_map(package), do: package
  defp assignment_package(_assignment), do: nil

  defp plugin_package_name(nil), do: "Unknown plugin"
  defp plugin_package_name(package), do: Map.get(package, :name) || Map.get(package, "name") || "Unknown plugin"

  defp plugin_package_id(nil), do: "unknown"
  defp plugin_package_id(package), do: Map.get(package, :plugin_id) || Map.get(package, "plugin_id") || "unknown"

  defp plugin_package_version(nil), do: "—"
  defp plugin_package_version(package), do: Map.get(package, :version) || Map.get(package, "version") || "—"

  defp plugin_requested_capabilities(nil), do: []

  defp plugin_requested_capabilities(package) do
    approved = Map.get(package, :approved_capabilities) || Map.get(package, "approved_capabilities") || []

    capabilities =
      if approved == [] do
        manifest = Map.get(package, :manifest) || Map.get(package, "manifest") || %{}
        Map.get(manifest, "capabilities") || Map.get(manifest, :capabilities) || []
      else
        approved
      end

    capabilities
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp format_assignment_source(nil), do: "manual"
  defp format_assignment_source(source) when is_atom(source), do: Atom.to_string(source)
  defp format_assignment_source(source), do: to_string(source)

  defp present_text(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_text(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp present_text(_value), do: nil

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
