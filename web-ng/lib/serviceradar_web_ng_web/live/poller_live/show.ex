defmodule ServiceRadarWebNGWeb.PollerLive.Show do
  @moduledoc """
  LiveView for showing individual poller details.

  Displays both live Horde registry data and rich node system information
  including memory usage, process counts, uptime, and poller role information.

  Note: Pollers do not have capabilities. They orchestrate monitoring jobs by
  receiving scheduled tasks (via AshOban) and dispatching work to available agents.
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Poller Details")
     |> assign(:poller_id, nil)
     |> assign(:poller, nil)
     |> assign(:live_poller, nil)
     |> assign(:node_info, nil)
     |> assign(:error, nil)
     |> assign(:srql, %{enabled: false, page_path: "/pollers"})}
  end

  @impl true
  def handle_params(%{"poller_id" => poller_id}, _uri, socket) do
    # First check Horde registry for live poller
    all_pollers = ServiceRadar.PollerRegistry.all_pollers()

    live_poller =
      Enum.find(all_pollers, fn poller ->
        poller_key = poller[:poller_id] || poller[:key]
        match_poller_id?(poller_key, poller_id)
      end)

    # Get node system info if live poller exists
    node_info =
      if live_poller do
        fetch_node_info(live_poller[:node])
      else
        nil
      end

    # Convert Horde data to display format
    horde_poller =
      if live_poller do
        %{
          "poller_id" => extract_poller_id(live_poller),
          "node" => format_node(live_poller[:node]),
          "status" => to_string(live_poller[:status] || :unknown),
          "partition_id" => live_poller[:partition_id],
          "domain" => live_poller[:domain],
          "registered_at" => live_poller[:registered_at],
          "last_heartbeat" => live_poller[:last_heartbeat],
          "pid" => inspect(live_poller[:pid]),
          "_source" => "horde"
        }
      else
        nil
      end

    # Fall back to SRQL database query
    db_poller =
      case srql_module().query("in:pollers poller_id:\"#{escape_value(poller_id)}\" limit:1") do
        {:ok, %{"results" => [poller | _]}} when is_map(poller) ->
          Map.put(poller, "_source", "database")

        _ ->
          nil
      end

    # Prefer Horde data over database
    {poller, error} =
      case {horde_poller, db_poller} do
        {nil, nil} -> {nil, "Poller not found"}
        {horde, nil} -> {horde, nil}
        {nil, db} -> {db, nil}
        {horde, db} -> {Map.merge(db, horde), nil}
      end

    {:noreply,
     socket
     |> assign(:poller_id, poller_id)
     |> assign(:poller, poller)
     |> assign(:live_poller, live_poller)
     |> assign(:node_info, node_info)
     |> assign(:error, error)
     |> assign(:srql, %{enabled: false, page_path: "/pollers/#{poller_id}"})}
  end

  defp match_poller_id?({_partition, node}, poller_id) when is_atom(node) do
    # Key format: {"default", :"serviceradar_poller@poller-elx"}
    String.contains?(to_string(node), poller_id) or
      to_string(node) == poller_id
  end

  defp match_poller_id?(key, poller_id) when is_binary(key), do: key == poller_id
  defp match_poller_id?(key, poller_id) when is_atom(key), do: to_string(key) == poller_id
  defp match_poller_id?(_, _), do: false

  defp extract_poller_id(%{poller_id: id}) when not is_nil(id), do: id
  defp extract_poller_id(%{key: {_partition, node}}) when is_atom(node), do: to_string(node)
  defp extract_poller_id(%{key: key}) when is_binary(key), do: key
  defp extract_poller_id(_), do: "unknown"

  defp fetch_node_info(nil), do: nil

  defp fetch_node_info(node) when is_atom(node) do
    try do
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
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-4xl p-6">
        <.header>
          Poller Details
          <:subtitle>
            <span class="font-mono text-xs">{@poller_id}</span>
          </:subtitle>
          <:actions>
            <.ui_button href={~p"/infrastructure?tab=pollers"} variant="ghost" size="sm">
              Back to infrastructure
            </.ui_button>
          </:actions>
        </.header>

        <div :if={@error} class="rounded-xl border border-error/30 bg-error/5 p-6 text-center">
          <p class="text-sm text-error">{@error}</p>
        </div>

        <div :if={is_map(@poller)} class="space-y-4">
          <!-- Live Status Banner -->
          <div :if={@live_poller} class="rounded-lg bg-success/10 border border-success/30 p-3 flex items-center gap-3">
            <span class="size-2.5 rounded-full bg-success animate-pulse"></span>
            <span class="text-sm text-success font-medium">Live Poller</span>
            <span class="text-xs text-base-content/60">Connected to cluster via Horde registry</span>
          </div>
          <div :if={!@live_poller && Map.get(@poller, "_source") == "database"} class="rounded-lg bg-warning/10 border border-warning/30 p-3 flex items-center gap-3">
            <span class="size-2.5 rounded-full bg-warning"></span>
            <span class="text-sm text-warning font-medium">Database Record</span>
            <span class="text-xs text-base-content/60">Poller not currently connected to cluster</span>
          </div>

          <.poller_summary poller={@poller} />
          <.poller_role_card />
          <.node_system_info :if={@node_info} node_info={@node_info} node={Map.get(@poller, "node")} />
          <.registration_info poller={@poller} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :poller, :map, required: true

  defp poller_summary(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-6">
      <div class="flex flex-wrap gap-x-8 gap-y-4">
        <div class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Status</span>
          <.status_badge status={Map.get(@poller, "status")} />
        </div>

        <div class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Node</span>
          <span class="text-sm font-mono">{Map.get(@poller, "node") || "—"}</span>
        </div>

        <div class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Partition</span>
          <span class="text-sm font-mono">{Map.get(@poller, "partition_id") || "default"}</span>
        </div>

        <div :if={has_value?(@poller, "domain")} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Domain</span>
          <span class="text-sm">{Map.get(@poller, "domain")}</span>
        </div>

        <div :if={has_value?(@poller, "pid")} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Process ID</span>
          <span class="text-sm font-mono text-xs">{Map.get(@poller, "pid")}</span>
        </div>
      </div>
    </div>
    """
  end

  defp poller_role_card(assigns) do
    # Derive role information from the Ash resource
    role_description = ServiceRadar.Infrastructure.Poller.role_description()
    role_steps = ServiceRadar.Infrastructure.Poller.role_steps()

    assigns =
      assigns
      |> assign(:role_description, role_description)
      |> assign(:role_steps, role_steps)

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
      <div class="px-4 py-3 border-b border-base-200">
        <span class="text-sm font-semibold">Poller Role</span>
      </div>
      <div class="p-4">
        <p class="text-sm text-base-content/70 mb-3">
          {@role_description}
        </p>
        <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
          <%= for {step, index} <- Enum.with_index(@role_steps) do %>
            <div class="flex items-center gap-2 p-2 rounded-lg bg-base-200/50">
              <span class={"badge badge-sm #{step_badge_class(index)}"}>{step.label}</span>
              <span class="text-xs text-base-content/60">{step.description}</span>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp step_badge_class(0), do: "badge-info"
  defp step_badge_class(1), do: "badge-success"
  defp step_badge_class(2), do: "badge-primary"
  defp step_badge_class(_), do: "badge-ghost"

  attr :node_info, :map, required: true
  attr :node, :string, required: true

  defp node_system_info(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
      <div class="px-4 py-3 border-b border-base-200 flex items-center justify-between">
        <span class="text-sm font-semibold">Node System Information</span>
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
          <.memory_stat label="Ports" bytes={nil} count={@node_info.port_count} />
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

  attr :poller, :map, required: true

  defp registration_info(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
      <div class="px-4 py-3 border-b border-base-200">
        <span class="text-sm font-semibold">Registration Timeline</span>
      </div>
      <div class="p-4">
        <div class="flex flex-col gap-3">
          <div :if={has_value?(@poller, "registered_at")} class="flex items-center gap-3">
            <span class="size-2 rounded-full bg-success"></span>
            <span class="text-xs text-base-content/60 w-24">Registered</span>
            <span class="font-mono text-sm">{format_timestamp(Map.get(@poller, "registered_at"))}</span>
          </div>
          <div :if={has_value?(@poller, "last_heartbeat")} class="flex items-center gap-3">
            <span class="size-2 rounded-full bg-info animate-pulse"></span>
            <span class="text-xs text-base-content/60 w-24">Last Heartbeat</span>
            <span class="font-mono text-sm">{format_timestamp(Map.get(@poller, "last_heartbeat"))}</span>
            <span class="text-xs text-base-content/40">({time_ago(Map.get(@poller, "last_heartbeat"))})</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :status, :any, default: nil

  defp status_badge(assigns) do
    {label, variant} =
      case assigns.status do
        "available" -> {"Available", "success"}
        :available -> {"Available", "success"}
        "busy" -> {"Busy", "warning"}
        :busy -> {"Busy", "warning"}
        "offline" -> {"Offline", "error"}
        :offline -> {"Offline", "error"}
        true -> {"Active", "success"}
        false -> {"Inactive", "error"}
        _ -> {"Unknown", "ghost"}
      end

    assigns = assign(assigns, :label, label) |> assign(:variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="sm">{@label}</.ui_badge>
    """
  end

  defp format_node(nil), do: nil
  defp format_node(node) when is_atom(node), do: Atom.to_string(node)
  defp format_node(node), do: to_string(node)

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
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> format_timestamp(dt)
      _ -> value
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

  defp time_ago(_), do: ""

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

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
