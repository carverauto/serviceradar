defmodule ServiceRadarWebNGWeb.AgentLive.Show do
  @moduledoc """
  LiveView for showing individual OCSF agent details.

  Includes ServiceCheck configuration for scheduling ping, TCP, and other
  monitoring checks executed by this agent.
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadar.Monitoring.ServiceCheck

  # OCSF Agent type IDs
  @type_names %{
    0 => "Unknown",
    1 => "EDR",
    4 => "Performance",
    6 => "Log Management",
    99 => "Other"
  }

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
     |> assign(:srql, %{enabled: false})
     |> assign(:checks, [])
     |> assign(:live_agent, nil)
     |> assign(:show_check_modal, false)
     |> assign(:check_form, nil)
     |> assign(:check_types, @check_types)}
  end

  require Logger

  @impl true
  def handle_params(%{"uid" => uid}, _uri, socket) do
    # First check Horde registry for live agent
    # Use all_agents + filter instead of lookup because lookup uses local ETS cache
    # which may not be synced yet in a distributed cluster
    all_agents = ServiceRadar.AgentRegistry.all_agents()
    Logger.debug("[AgentShow] All agents in Horde: #{inspect(Enum.map(all_agents, & &1[:agent_id] || &1[:key]))}")

    live_agent = Enum.find(all_agents, fn agent ->
      (agent[:agent_id] || agent[:key]) == uid
    end)
    Logger.debug("[AgentShow] Looking up agent uid=#{inspect(uid)}, live_agent=#{inspect(live_agent != nil)}")

    # Convert Horde data to agent map format (string keys for consistency)
    horde_agent =
      if live_agent do
        %{
          "uid" => uid,
          "agent_id" => Map.get(live_agent, :agent_id, uid),
          "status" => to_string(Map.get(live_agent, :status, :connected)),
          "capabilities" => Map.get(live_agent, :capabilities, []),
          "poller_node" => format_poller_node(Map.get(live_agent, :poller_node)),
          "connected_at" => Map.get(live_agent, :connected_at),
          "last_seen_time" => Map.get(live_agent, :last_heartbeat),
          "spiffe_identity" => Map.get(live_agent, :spiffe_identity),
          "_source" => "horde"
        }
      else
        nil
      end

    # Fall back to SRQL database query
    db_agent =
      case srql_module().query("in:agents uid:\"#{escape_value(uid)}\" limit:1") do
        {:ok, %{"results" => [agent | _]}} when is_map(agent) ->
          Map.put(agent, "_source", "database")

        _ ->
          nil
      end

    # Prefer Horde data (live) over database (may be stale)
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
    checks = load_checks_for_agent(uid, socket.assigns.current_scope)

    {:noreply,
     socket
     |> assign(:agent_uid, uid)
     |> assign(:agent, agent)
     |> assign(:error, error)
     |> assign(:checks, checks)
     |> assign(:live_agent, live_agent)}
  end

  defp format_poller_node(nil), do: nil
  defp format_poller_node(node) when is_atom(node), do: Atom.to_string(node)
  defp format_poller_node(node), do: to_string(node)

  defp load_checks_for_agent(agent_uid, current_scope) do
    tenant_id =
      case current_scope do
        %{user: %{tenant_id: tid}} when not is_nil(tid) -> tid
        _ -> nil
      end

    case ServiceCheck
         |> Ash.Query.for_read(:by_agent, %{agent_uid: agent_uid})
         |> Ash.read(tenant: tenant_id, authorize?: false) do
      {:ok, checks} -> checks
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
          <div :if={@live_agent} class="rounded-lg bg-success/10 border border-success/30 p-3 flex items-center gap-3">
            <span class="size-2.5 rounded-full bg-success animate-pulse"></span>
            <span class="text-sm text-success font-medium">Live Agent</span>
            <span class="text-xs text-base-content/60">Connected to cluster via Horde registry</span>
          </div>
          <div :if={!@live_agent && Map.get(@agent, "_source") == "database"} class="rounded-lg bg-warning/10 border border-warning/30 p-3 flex items-center gap-3">
            <span class="size-2.5 rounded-full bg-warning"></span>
            <span class="text-sm text-warning font-medium">Database Record</span>
            <span class="text-xs text-base-content/60">Agent not currently connected to cluster</span>
          </div>

          <.agent_summary agent={@agent} live_agent={@live_agent} />
          <.agent_capabilities agent={@agent} />
          <.agent_details agent={@agent} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :agent, :map, required: true
  attr :live_agent, :map, default: nil

  defp agent_summary(assigns) do
    type_id = Map.get(assigns.agent, "type_id") || 0
    type_name = Map.get(@type_names, type_id, "Unknown")
    assigns = assign(assigns, :type_name, type_name)

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-6">
      <div class="flex flex-wrap gap-x-8 gap-y-4">
        <div class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Type</span>
          <.type_badge type_id={Map.get(@agent, "type_id")} />
        </div>

        <div class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Agent UID</span>
          <span class="text-sm font-mono">{Map.get(@agent, "uid") || "—"}</span>
        </div>

        <div :if={has_value?(@agent, "name")} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Name</span>
          <span class="text-sm">{Map.get(@agent, "name")}</span>
        </div>

        <div :if={has_value?(@agent, "version")} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Version</span>
          <span class="text-sm font-mono">{Map.get(@agent, "version")}</span>
        </div>

        <div :if={has_value?(@agent, "vendor_name")} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Vendor</span>
          <span class="text-sm">{Map.get(@agent, "vendor_name")}</span>
        </div>

        <div :if={has_value?(@agent, "poller_id")} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Poller</span>
          <.link
            navigate={~p"/pollers/#{Map.get(@agent, "poller_id")}"}
            class="text-sm font-mono link link-primary"
          >
            {Map.get(@agent, "poller_id")}
          </.link>
        </div>

        <div :if={has_value?(@agent, "ip")} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">IP Address</span>
          <span class="text-sm font-mono">{Map.get(@agent, "ip")}</span>
        </div>

        <div :if={has_value?(@agent, "first_seen_time")} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">First Seen</span>
          <span class="text-sm font-mono">{format_timestamp(@agent, "first_seen_time")}</span>
        </div>

        <div :if={has_value?(@agent, "last_seen_time")} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Last Seen</span>
          <span class="text-sm font-mono">{format_timestamp(@agent, "last_seen_time")}</span>
        </div>
      </div>
    </div>
    """
  end

  attr :agent, :map, required: true

  defp agent_capabilities(assigns) do
    capabilities = Map.get(assigns.agent, "capabilities", []) || []
    assigns = assign(assigns, :capabilities, capabilities)

    ~H"""
    <div :if={@capabilities != []} class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
      <div class="px-4 py-3 border-b border-base-200">
        <span class="text-sm font-semibold">Capabilities</span>
      </div>
      <div class="p-4">
        <div class="flex flex-wrap gap-2">
          <%= for cap <- @capabilities do %>
            <span class="badge badge-outline badge-lg">{cap}</span>
          <% end %>
        </div>
      </div>
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
    <.ui_badge variant={@variant} size="sm">{@type_name}</.ui_badge>
    """
  end

  attr :agent, :map, required: true

  defp agent_details(assigns) do
    # Fields shown in summary (exclude from details)
    summary_fields = ~w(uid name type_id type version vendor_name poller_id ip
                        capabilities first_seen_time last_seen_time first_seen last_seen
                        created_time modified_time)

    # Get remaining fields, excluding empty maps
    detail_fields =
      assigns.agent
      |> Map.keys()
      |> Enum.reject(fn key ->
        value = Map.get(assigns.agent, key)
        key in summary_fields or (is_map(value) and map_size(value) == 0)
      end)
      |> Enum.sort()

    assigns = assign(assigns, :detail_fields, detail_fields)

    ~H"""
    <div :if={@detail_fields != []} class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
      <div class="px-4 py-3 border-b border-base-200">
        <span class="text-sm font-semibold">Additional Details</span>
      </div>

      <div class="divide-y divide-base-200">
        <%= for field <- @detail_fields do %>
          <div class="px-4 py-3 flex items-start gap-4">
            <span class="text-xs text-base-content/50 w-36 shrink-0 pt-0.5">
              {humanize_field(field)}
            </span>
            <span class="text-sm flex-1 break-all">
              <.format_value value={Map.get(@agent, field)} />
            </span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :value, :any, default: nil

  defp format_value(%{value: nil} = assigns) do
    ~H|<span class="text-base-content/40">—</span>|
  end

  defp format_value(%{value: ""} = assigns) do
    ~H|<span class="text-base-content/40">—</span>|
  end

  defp format_value(%{value: value} = assigns) when is_boolean(value) do
    ~H"""
    <.ui_badge variant={if @value, do: "success", else: "error"} size="xs">
      {to_string(@value)}
    </.ui_badge>
    """
  end

  defp format_value(%{value: value} = assigns) when is_map(value) and map_size(value) == 0 do
    ~H|<span class="text-base-content/40">—</span>|
  end

  defp format_value(%{value: value} = assigns) when is_map(value) or is_list(value) do
    formatted = Jason.encode!(value, pretty: true)
    assigns = assign(assigns, :formatted, formatted)

    ~H"""
    <pre class="text-xs font-mono bg-base-200/30 p-2 rounded overflow-x-auto max-h-48">{@formatted}</pre>
    """
  end

  defp format_value(%{value: value} = assigns) when is_binary(value) do
    # Check if it looks like JSON
    if String.starts_with?(value, "{") or String.starts_with?(value, "[") do
      case Jason.decode(value) do
        {:ok, decoded} ->
          formatted = Jason.encode!(decoded, pretty: true)
          assigns = assign(assigns, :formatted, formatted)

          ~H"""
          <pre class="text-xs font-mono bg-base-200/30 p-2 rounded overflow-x-auto max-h-48">{@formatted}</pre>
          """

        {:error, _} ->
          ~H"""
          <span class="font-mono text-xs">{@value}</span>
          """
      end
    else
      ~H"""
      <span>{@value}</span>
      """
    end
  end

  defp format_value(assigns) do
    ~H"""
    <span>{to_string(@value)}</span>
    """
  end

  defp format_timestamp(agent, field) do
    ts = Map.get(agent, field)

    case parse_timestamp(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
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

  defp has_value?(map, key) do
    case Map.get(map, key) do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  defp humanize_field(field) when is_binary(field) do
    field
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp humanize_field(field), do: to_string(field)

  defp escape_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp escape_value(other), do: escape_value(to_string(other))

  defp format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  defp format_error(%ArgumentError{} = err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
