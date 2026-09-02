defmodule ServiceRadarWebNGWeb.AgentLive.Index do
  @moduledoc """
  LiveView for listing OCSF agents.

  Displays agents registered in the ocsf_agents table with filtering
  and pagination via SRQL queries, plus live registry agents.
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadar.Infrastructure.Agent, as: InfrastructureAgent
  alias ServiceRadarWebNG.AgentCapabilities
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.SRQL.Builder, as: SRQLBuilder
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  require Ash.Query

  @default_limit 20
  @max_limit 100
  @summary_limit 500
  @release_state_options [
    {"All rollout states", ""},
    {"Pending", "pending"},
    {"Dispatched", "dispatched"},
    {"Downloading", "downloading"},
    {"Verifying", "verifying"},
    {"Staged", "staged"},
    {"Restarting", "restarting"},
    {"Healthy", "healthy"},
    {"Failed", "failed"},
    {"Rolled Back", "rolled_back"},
    {"Canceled", "canceled"}
  ]

  # OCSF Agent type IDs
  @type_names %{
    0 => "Unknown",
    1 => "EDR",
    4 => "Performance",
    6 => "Log Management",
    99 => "Other"
  }

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to agent registration events
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "agent:registrations")
    end

    {:ok,
     socket
     |> assign(:page_title, "Agents")
     |> assign(:agents, [])
     |> assign(:live_agents, load_live_agents())
     |> assign(:selected_agent_ids, [])
     |> assign(:release_state_options, @release_state_options)
     |> assign(:release_filters, default_release_filters())
     |> assign(:release_filter_form, release_filter_form())
     |> assign(:version_distribution, [])
     |> assign(:rollout_distribution, [])
     |> assign(:config_unhealthy_uids, MapSet.new())
     |> assign(:limit, @default_limit)
     |> SRQLPage.init("agents", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket =
      SRQLPage.load_list(socket, params, uri, :agents,
        default_limit: @default_limit,
        max_limit: @max_limit
      )

    query = get_in(socket.assigns, [:srql, :query]) || base_agents_query(socket.assigns.limit)

    summary_agents =
      load_summary_agents(socket.assigns.current_scope, query, socket.assigns.agents)

    release_filters = release_filters_from_query(query)

    selected_agent_ids =
      selected_agent_ids_for_visible(socket.assigns.selected_agent_ids, socket.assigns.agents)

    {:noreply,
     socket
     |> assign(:selected_agent_ids, selected_agent_ids)
     |> assign(:release_filters, release_filters)
     |> assign(:release_filter_form, release_filter_form(release_filters))
     |> assign(:version_distribution, summarize_versions(summary_agents))
     |> assign(:rollout_distribution, summarize_rollout_states(summary_agents))
     |> assign(:config_unhealthy_uids, load_config_unhealthy_uids(socket.assigns.current_scope))}
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_paginate", params, socket) do
    socket =
      SRQLPage.handle_event(socket, "srql_paginate", params,
        list_assign_key: :agents,
        default_limit: @default_limit,
        max_limit: @max_limit
      )

    query = get_in(socket.assigns, [:srql, :query]) || base_agents_query(socket.assigns.limit)

    summary_agents =
      load_summary_agents(socket.assigns.current_scope, query, socket.assigns.agents)

    selected_agent_ids =
      selected_agent_ids_for_visible(socket.assigns.selected_agent_ids, socket.assigns.agents)

    {:noreply,
     socket
     |> assign(:selected_agent_ids, selected_agent_ids)
     |> assign(:version_distribution, summarize_versions(summary_agents))
     |> assign(:rollout_distribution, summarize_rollout_states(summary_agents))}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, fallback_path: "/agents")}
  end

  def handle_event("srql_reset", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_reset", params, fallback_path: "/agents")}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "agents")}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_run", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_run", %{}, fallback_path: "/agents")}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "agents")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "agents")}
  end

  def handle_event("apply_release_filters", %{"filters" => params}, socket) do
    query =
      socket.assigns.srql.query
      |> upsert_release_filter("release_rollout_state", Map.get(params, "release_rollout_state"))
      |> upsert_release_filter("desired_version", Map.get(params, "desired_version"))

    {:noreply, push_agents_patch(socket, query)}
  end

  def handle_event("clear_release_filters", _params, socket) do
    query =
      socket.assigns.srql.query
      |> upsert_release_filter("release_rollout_state", nil)
      |> upsert_release_filter("desired_version", nil)

    {:noreply, push_agents_patch(socket, query)}
  end

  def handle_event("quick_release_state_filter", %{"state" => state}, socket) do
    desired_version = socket.assigns.release_filters["desired_version"]

    query =
      socket.assigns.srql.query
      |> upsert_release_filter("release_rollout_state", state)
      |> upsert_release_filter("desired_version", desired_version)

    {:noreply, push_agents_patch(socket, query)}
  end

  def handle_event("toggle_selected_agent", %{"id" => agent_id}, socket) do
    {:noreply,
     assign(
       socket,
       :selected_agent_ids,
       toggle_selected_agent_id(socket.assigns.selected_agent_ids, agent_id)
     )}
  end

  def handle_event("select_visible_agents", _params, socket) do
    {:noreply, assign(socket, :selected_agent_ids, Enum.map(socket.assigns.agents, &agent_uid/1))}
  end

  def handle_event("clear_selected_agents", _params, socket) do
    {:noreply, assign(socket, :selected_agent_ids, [])}
  end

  # Handle PubSub events for live agent updates
  @impl true
  def handle_info({:agent_registered, _metadata}, socket) do
    {:noreply, assign(socket, :live_agents, load_live_agents())}
  end

  def handle_info({:agent_disconnected, _agent_id}, socket) do
    {:noreply, assign(socket, :live_agents, load_live_agents())}
  end

  def handle_info({:agent_status_changed, _agent_id, _status}, socket) do
    {:noreply, assign(socket, :live_agents, load_live_agents())}
  end

  # Catch-all for other PubSub messages
  def handle_info(_msg, socket), do: {:noreply, socket}

  # Load all live agents from the registry
  # Schema scoping is implicit via PostgreSQL search_path
  defp load_config_unhealthy_uids(scope) do
    InfrastructureAgent
    |> Ash.Query.filter(config_health == :unhealthy)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, agents} -> MapSet.new(agents, & &1.uid)
      {:error, _reason} -> MapSet.new()
    end
  end

  defp load_live_agents do
    normalize_live_agents(ServiceRadar.AgentRegistry.find_agents())
  end

  @doc false
  def normalize_live_agents(agents) when is_list(agents) do
    agents
    |> Enum.map(&normalize_live_agent/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(& &1.agent_id)
    |> Enum.map(fn {_agent_id, entries} -> select_live_agent_entry(entries) end)
    |> Enum.sort_by(& &1.agent_id)
  end

  def normalize_live_agents(_agents), do: []

  defp normalize_live_agent(agent) when is_map(agent) do
    case registry_agent_id(agent) do
      nil ->
        nil

      agent_id ->
        %{
          agent_id: agent_id,
          partition_id: Map.get(agent, :partition_id),
          gateway_node: Map.get(agent, :gateway_node),
          capabilities: Map.get(agent, :capabilities, []),
          status: Map.get(agent, :status, :unknown),
          connected_at: Map.get(agent, :connected_at),
          last_heartbeat: Map.get(agent, :last_heartbeat),
          spiffe_identity: Map.get(agent, :spiffe_identity)
        }
    end
  end

  defp normalize_live_agent(_agent), do: nil

  defp registry_agent_id(agent) do
    case Map.get(agent, :agent_id) || Map.get(agent, :key) do
      value when is_binary(value) and value != "" -> value
      {:agent, agent_id, _node} when is_binary(agent_id) and agent_id != "" -> agent_id
      {:agent, agent_id} when is_binary(agent_id) and agent_id != "" -> agent_id
      _ -> nil
    end
  end

  defp select_live_agent_entry([entry]), do: entry

  defp select_live_agent_entry(entries) do
    Enum.max_by(entries, fn entry ->
      {
        entry.status == :connected,
        entry.capabilities != [],
        datetime_score(entry.last_heartbeat),
        datetime_score(entry.connected_at)
      }
    end)
  end

  defp datetime_score(%DateTime{} = timestamp), do: DateTime.to_unix(timestamp, :microsecond)
  defp datetime_score(_timestamp), do: 0

  @impl true
  def render(assigns) do
    pagination = get_in(assigns, [:srql, :pagination]) || %{}
    assigns = assign(assigns, :pagination, pagination)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-[100rem] space-y-6 px-4 py-5 sm:px-6">
        <%!-- Live Connected Agents Section --%>
        <.ui_panel>
          <div class="flex flex-wrap items-start justify-between gap-2 border-b border-sr-line px-4 py-3">
            <div class="flex flex-wrap items-center gap-2">
              <span class="text-sm font-semibold">Live Agents</span>
              <.ui_badge size="sm" variant="success">
                {length(@live_agents)} connected
              </.ui_badge>
            </div>
            <span class="text-xs leading-5 text-sr-muted">Real-time gateway registry</span>
          </div>
          <.live_agents_table
            id="live-agents"
            agents={@live_agents}
            timezone={@current_scope.user.timezone || "Etc/UTC"}
          />
        </.ui_panel>

        <%!-- Database Agents Section --%>
        <.ui_panel>
          <div class="px-4 py-3 border-b border-sr-line flex flex-wrap items-center justify-between gap-3">
            <div class="flex items-center gap-2">
              <span class="text-sm font-semibold">Registered Agents</span>
              <.ui_badge size="sm" variant="ghost">{length(@agents)} visible</.ui_badge>
            </div>
            <div
              :if={RBAC.can?(@current_scope, "settings.edge.manage")}
              class="flex flex-wrap items-center gap-2"
            >
              <.ui_button
                :if={@selected_agent_ids != []}
                navigate={selected_rollout_handoff_path(@selected_agent_ids, @release_filters)}
                size="sm"
                variant="soft"
              >
                <.icon name="hero-bolt" class="size-4" /> Roll Out Selected
              </.ui_button>
              <.ui_button
                :if={@agents != []}
                navigate={visible_rollout_handoff_path(@agents, @release_filters)}
                size="sm"
                variant="primary"
              >
                <.icon name="hero-play" class="size-4" /> Roll Out Visible Cohort
              </.ui_button>
              <.ui_button
                :if={@agents != []}
                type="button"
                phx-click="select_visible_agents"
                size="sm"
                variant="ghost"
              >
                Select Visible
              </.ui_button>
              <.ui_button
                :if={@selected_agent_ids != []}
                type="button"
                phx-click="clear_selected_agents"
                size="sm"
                variant="ghost"
              >
                Clear Selected
              </.ui_button>
              <.ui_button navigate={~p"/settings/agents/releases"} size="sm" variant="outline">
                <.icon name="hero-rocket-launch" class="size-4" /> Manage Releases
              </.ui_button>
            </div>
          </div>

          <div class="px-4 py-4 border-b border-sr-line space-y-4">
            <div class="grid gap-4 xl:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)]">
              <.ui_panel class="border border-sr-line/70 bg-sr-surface shadow-none">
                <:header>
                  <div class="text-sm font-semibold">Version Distribution</div>
                </:header>
                <div class="p-4">
                  <div :if={@version_distribution == []} class="text-sm text-sr-muted">
                    No version data in the current result set.
                  </div>
                  <div :if={@version_distribution != []} class="flex flex-wrap gap-2">
                    <%= for %{version: version, count: count} <- @version_distribution do %>
                      <.ui_badge size="sm" variant="outline" class="gap-2 px-3 py-3">
                        <span class="font-mono text-[11px]">{version}</span>
                        <span class="text-sr-muted">{count}</span>
                      </.ui_badge>
                    <% end %>
                  </div>
                </div>
              </.ui_panel>

              <.ui_panel class="border border-sr-line/70 bg-sr-surface shadow-none">
                <:header>
                  <div class="text-sm font-semibold">Rollout States</div>
                </:header>
                <div class="p-4">
                  <div :if={@rollout_distribution == []} class="text-sm text-sr-muted">
                    No rollout activity in the current result set.
                  </div>
                  <div :if={@rollout_distribution != []} class="flex flex-wrap gap-2">
                    <%= for %{state: state, count: count, label: label, variant: variant} <- @rollout_distribution do %>
                      <.ui_button
                        type="button"
                        size="xs"
                        variant={rollout_filter_badge_variant(variant)}
                        phx-click="quick_release_state_filter"
                        phx-value-state={state}
                        class="gap-2 px-3 py-2"
                      >
                        <span>{label}</span>
                        <span class="opacity-80">{count}</span>
                      </.ui_button>
                    <% end %>
                  </div>
                </div>
              </.ui_panel>
            </div>

            <.form
              for={@release_filter_form}
              id="agent-release-filters-form"
              phx-submit="apply_release_filters"
              class="flex flex-wrap items-end gap-3"
            >
              <.input
                field={@release_filter_form[:release_rollout_state]}
                type="select"
                label="Rollout State"
                options={@release_state_options}
                class="min-w-52"
              />
              <.input
                field={@release_filter_form[:desired_version]}
                label="Target Version"
                placeholder="1.2.3"
                class="min-w-44"
              />
              <div class="flex gap-2">
                <.ui_button type="submit" variant="primary" size="sm">
                  Apply Filters
                </.ui_button>
                <.ui_button type="button" variant="ghost" size="sm" phx-click="clear_release_filters">
                  Clear
                </.ui_button>
              </div>
            </.form>
          </div>

          <div
            :if={MapSet.size(@config_unhealthy_uids) > 0}
            id="config-unhealthy-banner"
            class="mb-3 flex items-center gap-2 rounded-lg border border-error/30 bg-error/5 px-3 py-2"
          >
            <.icon name="hero-exclamation-triangle" class="size-4 text-error" />
            <span class="text-sm text-error">
              {MapSet.size(@config_unhealthy_uids)} agent(s) config-unhealthy — config apply wedged or failing
            </span>
          </div>

          <.agents_table
            id="agents"
            agents={@agents}
            selected_agent_ids={@selected_agent_ids}
            config_unhealthy_uids={@config_unhealthy_uids}
            allow_selection={RBAC.can?(@current_scope, "settings.edge.manage")}
            timezone={@current_scope.user.timezone || "Etc/UTC"}
          />

          <div class="mt-4 pt-4 border-t border-sr-line">
            <.ui_pagination
              prev_cursor={Map.get(@pagination, "prev_cursor")}
              next_cursor={Map.get(@pagination, "next_cursor")}
              limit={@limit}
              current_page={Map.get(assigns, :pagination_page, 1)}
              result_count={length(@agents)}
            />
          </div>
        </.ui_panel>
      </div>
    </Layouts.app>
    """
  end

  attr(:id, :string, required: true)
  attr(:agents, :list, default: [])
  attr(:timezone, :string, default: "Etc/UTC")

  defp live_agents_table(assigns) do
    ~H"""
    <div class="sr-ui-table-shell">
      <table
        id={@id}
        class={ui_table_class(size: "sm", zebra: true, fixed: true, class: "w-full min-w-[72rem]")}
      >
        <thead>
          <tr>
            <th class="w-10">Status</th>
            <th class="w-48">Agent ID</th>
            <th class="w-32">Partition</th>
            <th class="w-40">Gateway Node</th>
            <th class="w-80">Capabilities</th>
            <th class="w-20">Host Health</th>
            <th class="w-36">Connected</th>
            <th class="w-36">Last Heartbeat</th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@agents == []}>
            <td colspan="8" class="text-sm text-sr-muted py-8 text-center">
              No live agents connected. Agents will appear here when they register with the Horde cluster.
            </td>
          </tr>

          <%= for {agent, idx} <- Enum.with_index(@agents) do %>
            <tr
              id={"#{@id}-row-#{idx}"}
              class="hover:bg-sr-subtle/40 transition-colors"
            >
              <td class="whitespace-nowrap">
                <.status_indicator status={agent.status} />
              </td>
              <td
                class="whitespace-nowrap text-xs font-mono truncate max-w-[12rem]"
                title={agent.agent_id}
              >
                <.link navigate={~p"/agents/#{agent.agent_id}"} class="text-sr-brand hover:underline">
                  {agent.agent_id}
                </.link>
              </td>
              <td class="whitespace-nowrap text-xs">
                <.ui_badge :if={agent.partition_id} size="sm" variant="ghost">
                  {agent.partition_id}
                </.ui_badge>
                <span :if={!agent.partition_id} class="text-sr-muted">—</span>
              </td>
              <td
                class="whitespace-nowrap text-xs font-mono truncate max-w-[10rem]"
                title={to_string(agent.gateway_node)}
              >
                {format_node(agent.gateway_node)}
              </td>
              <td class="min-w-0 align-top text-xs">
                <.capabilities_list capabilities={agent.capabilities} />
              </td>
              <td class="text-xs">
                <.sysmon_status_badge capabilities={agent.capabilities} />
              </td>
              <td class="whitespace-nowrap text-xs font-mono">
                <.user_time
                  id={"live-agent-#{agent.agent_id}-connected-at"}
                  value={agent.connected_at}
                  timezone={@timezone}
                  style={:time}
                />
              </td>
              <td class="whitespace-nowrap text-xs font-mono">
                <.user_time
                  id={"live-agent-#{agent.agent_id}-last-heartbeat"}
                  value={agent.last_heartbeat}
                  timezone={@timezone}
                  style={:time}
                />
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr(:status, :atom, default: :unknown)

  defp status_indicator(assigns) do
    {color, label} =
      case assigns.status do
        :connected -> {"success", "Connected"}
        :disconnected -> {"error", "Disconnected"}
        :degraded -> {"warning", "Degraded"}
        :busy -> {"info", "Busy"}
        :draining -> {"warning", "Draining"}
        _ -> {"ghost", "Unknown"}
      end

    assigns = assign(assigns, color: color, label: label)

    ~H"""
    <div class="flex items-center gap-1.5" title={@label}>
      <span class={"status status-#{@color}"}></span>
    </div>
    """
  end

  defp format_node(nil), do: "—"

  defp format_node(node) when is_atom(node), do: node |> Atom.to_string() |> String.split("@") |> List.first()

  defp format_node(node), do: to_string(node)

  attr(:id, :string, required: true)
  attr(:agents, :list, default: [])
  attr(:selected_agent_ids, :list, default: [])
  attr(:config_unhealthy_uids, :any, default: nil)
  attr(:allow_selection, :boolean, default: false)
  attr(:timezone, :string, default: "Etc/UTC")

  defp agents_table(assigns) do
    ~H"""
    <div class="sr-ui-table-shell">
      <table
        id={@id}
        class={ui_table_class(size: "sm", zebra: true, fixed: true, class: "w-full min-w-[88rem]")}
      >
        <thead>
          <tr>
            <th :if={@allow_selection} class="w-16">Select</th>
            <th class="w-48">Agent ID</th>
            <th class="w-32">Name</th>
            <th class="w-24">Type</th>
            <th class="w-40">Gateway</th>
            <th class="w-36">Version</th>
            <th class="w-32">Release</th>
            <th class="w-72">Capabilities</th>
            <th class="w-20">Host Health</th>
            <th class="w-36">Last Update</th>
            <th class="w-36">Last Seen</th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@agents == []}>
            <td
              colspan={if(@allow_selection, do: 11, else: 10)}
              class="text-sm text-sr-muted py-8 text-center"
            >
              No agents found.
            </td>
          </tr>

          <%= for {agent, idx} <- Enum.with_index(@agents) do %>
            <tr
              id={"#{@id}-row-#{idx}"}
              class="hover:bg-sr-subtle/40 transition-colors"
            >
              <td :if={@allow_selection} class="whitespace-nowrap">
                <.ui_icon_button
                  id={"select-agent-#{agent_uid(agent)}"}
                  type="button"
                  size="xs"
                  variant={if(agent_uid(agent) in @selected_agent_ids, do: "primary", else: "ghost")}
                  phx-click="toggle_selected_agent"
                  phx-value-id={agent_uid(agent)}
                  aria-label={
                    if(agent_uid(agent) in @selected_agent_ids,
                      do: "Deselect agent",
                      else: "Select agent"
                    )
                  }
                >
                  <.icon
                    name={
                      if(agent_uid(agent) in @selected_agent_ids, do: "hero-check", else: "hero-plus")
                    }
                    class="size-3.5"
                  />
                </.ui_icon_button>
              </td>
              <td
                class="whitespace-nowrap text-xs font-mono truncate max-w-[12rem]"
                title={agent_uid(agent)}
              >
                <.link
                  navigate={~p"/agents/#{agent_uid(agent)}"}
                  class="text-sr-brand hover:underline"
                >
                  {agent_uid(agent)}
                </.link>
              </td>
              <td
                class="whitespace-nowrap text-xs truncate max-w-[8rem]"
                title={agent_name(agent)}
              >
                <.link navigate={~p"/agents/#{agent_uid(agent)}"} class="hover:underline">
                  {agent_name(agent)}
                </.link>
              </td>
              <td class="whitespace-nowrap text-xs">
                <.type_badge type_id={Map.get(agent, "type_id")} />
              </td>
              <td
                class="whitespace-nowrap text-xs font-mono truncate max-w-[10rem]"
                title={agent_gateway(agent)}
              >
                {agent_gateway(agent)}
              </td>
              <td class="whitespace-nowrap text-xs">
                <div class="flex flex-col gap-1">
                  <span class="font-mono">{agent_version(agent)}</span>
                  <span
                    :if={agent_desired_version(agent) not in [nil, "", agent_version(agent)]}
                    class="text-[11px] text-warning font-mono"
                  >
                    target {agent_desired_version(agent)}
                  </span>
                </div>
              </td>
              <td class="whitespace-nowrap text-xs">
                <div class="flex flex-col gap-1">
                  <.release_rollout_badge
                    state={Map.get(agent, "release_rollout_state")}
                    has_error={Map.get(agent, "last_update_error") not in [nil, ""]}
                  />
                  <.ui_badge
                    :if={agent_uid(agent) in (@config_unhealthy_uids || [])}
                    variant="error"
                    size="xs"
                  >
                    config unhealthy
                  </.ui_badge>
                </div>
              </td>
              <td class="min-w-0 align-top text-xs">
                <.capabilities_list capabilities={Map.get(agent, "capabilities", [])} />
              </td>
              <td class="text-xs">
                <.sysmon_status_badge capabilities={Map.get(agent, "capabilities", [])} />
              </td>
              <td
                class="whitespace-nowrap text-xs font-mono"
                title={Map.get(agent, "last_update_error")}
              >
                <.user_time
                  id={"agent-#{agent_uid(agent)}-last-update-at"}
                  value={release_timestamp(agent)}
                  timezone={@timezone}
                  style={:compact}
                />
              </td>
              <td class="whitespace-nowrap text-xs font-mono">
                <.user_time
                  id={"agent-#{agent_uid(agent)}-last-seen-at"}
                  value={last_seen_timestamp(agent)}
                  timezone={@timezone}
                  style={:compact}
                />
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  # Host Health status badge component
  attr(:capabilities, :list, default: [])

  defp sysmon_status_badge(assigns) do
    caps = assigns.capabilities || []

    has_sysmon =
      Enum.any?(caps, fn cap ->
        cap_lower = String.downcase(to_string(cap))
        String.contains?(cap_lower, "sysmon") or String.contains?(cap_lower, "system_monitor")
      end)

    assigns = assign(assigns, :has_sysmon, has_sysmon)

    ~H"""
    <div :if={@has_sysmon} class="flex items-center gap-1" title="Host Health metrics enabled">
      <.icon name="hero-cpu-chip" class="size-4 text-success" />
    </div>
    <span :if={not @has_sysmon} class="text-sr-muted">—</span>
    """
  end

  attr(:type_id, :integer, default: 0)

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

    assigns = assigns |> assign(:type_name, type_name) |> assign(:variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@type_name}</.ui_badge>
    """
  end

  attr(:capabilities, :list, default: [])

  defp capabilities_list(assigns) do
    summary = AgentCapabilities.summarize(assigns.capabilities)

    assigns =
      assigns
      |> assign(:available, summary.available)
      |> assign(:unavailable, summary.unavailable)
      |> assign(:total, summary.total)

    ~H"""
    <div class="min-w-0 max-w-72">
      <span :if={@total == 0} class="text-sr-muted">—</span>

      <div :if={@total > 0} class="flex min-w-0 flex-col gap-1.5">
        <div class="flex flex-wrap items-center gap-1.5">
          <.ui_badge size="xs" variant="ghost" class="whitespace-nowrap">
            {length(@available)} active
          </.ui_badge>
          <.ui_badge
            :if={@unavailable != []}
            size="xs"
            variant="warning"
            class="whitespace-nowrap"
          >
            {length(@unavailable)} unavailable
          </.ui_badge>
        </div>

        <div :if={@available != []} class="space-y-0.5">
          <code
            :for={cap <- Enum.take(@available, 2)}
            class="block max-w-full truncate text-[11px] text-sr-muted"
            title={cap}
          >
            {cap}
          </code>
        </div>

        <details class="group min-w-0">
          <summary class="flex w-fit cursor-pointer list-none items-center gap-1 text-[11px] text-sr-muted hover:text-sr-ink focus:outline-none">
            <.icon
              name="hero-chevron-right"
              class="size-3 transition-transform group-open:rotate-90"
            /> Reported details
          </summary>
          <div class="mt-2 min-w-0 space-y-2 rounded-md bg-sr-subtle/50 p-2">
            <div :if={@available != []}>
              <div class="mb-1 text-[10px] font-semibold text-sr-muted">Active</div>
              <code
                :for={cap <- @available}
                class="block break-all text-[10px] leading-4 text-sr-muted"
              >
                {cap}
              </code>
            </div>
            <div :if={@unavailable != []}>
              <div class="mb-1 text-[10px] font-semibold text-warning">Unavailable</div>
              <code
                :for={cap <- @unavailable}
                class="block break-all text-[10px] leading-4 text-sr-muted"
              >
                {cap}
              </code>
            </div>
          </div>
        </details>
      </div>
    </div>
    """
  end

  defp agent_uid(agent) do
    Enum.find([Map.get(agent, "uid"), Map.get(agent, "id")], "unknown", &(&1 not in [nil, ""]))
  end

  defp agent_name(agent) do
    Map.get(agent, "name") || "—"
  end

  defp agent_gateway(agent) do
    Map.get(agent, "gateway_id") || "—"
  end

  attr(:state, :any, default: nil)
  attr(:has_error, :boolean, default: false)

  defp release_rollout_badge(assigns) do
    {label, variant} =
      case normalize_release_state(assigns.state, assigns.has_error) do
        {:pending, _} -> {"Pending", "ghost"}
        {:dispatched, _} -> {"Dispatched", "info"}
        {:downloading, _} -> {"Downloading", "info"}
        {:verifying, _} -> {"Verifying", "info"}
        {:staged, _} -> {"Staged", "warning"}
        {:restarting, _} -> {"Restarting", "warning"}
        {:healthy, _} -> {"Healthy", "success"}
        {:failed, _} -> {"Failed", "error"}
        {:rolled_back, _} -> {"Rolled Back", "error"}
        {:canceled, _} -> {"Canceled", "ghost"}
        {:none, true} -> {"Error", "error"}
        _ -> {"—", "ghost"}
      end

    assigns = assigns |> assign(:label, label) |> assign(:variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp last_seen_timestamp(agent) do
    ts = Map.get(agent, "last_seen_time") || Map.get(agent, "last_seen")
    parsed_timestamp(ts)
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

  defp agent_version(agent) do
    Map.get(agent, "version") || "—"
  end

  defp agent_desired_version(agent) do
    Map.get(agent, "desired_version")
  end

  defp release_timestamp(agent), do: parsed_timestamp(Map.get(agent, "last_update_at"))

  defp parsed_timestamp(value) do
    case parse_timestamp(value) do
      {:ok, datetime} -> datetime
      :error -> nil
    end
  end

  defp normalize_release_state(nil, has_error), do: {:none, has_error}
  defp normalize_release_state("", has_error), do: {:none, has_error}

  defp normalize_release_state(state, has_error) when is_binary(state) do
    state
    |> String.trim()
    |> normalize_release_state_value()
    |> then(&{&1, has_error})
  end

  defp normalize_release_state(state, has_error) when is_atom(state), do: {state, has_error}
  defp normalize_release_state(_state, has_error), do: {:none, has_error}

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
  defp normalize_release_state_value(_), do: :none

  defp default_release_filters do
    %{
      "release_rollout_state" => "",
      "desired_version" => ""
    }
  end

  defp release_filter_form(params \\ %{}) do
    params = Map.merge(default_release_filters(), Map.new(params))
    to_form(params, as: :filters)
  end

  defp push_agents_patch(socket, query) do
    params = %{"q" => query}

    push_patch(socket, to: "/agents?" <> URI.encode_query(params))
  end

  defp base_agents_query(limit) do
    "agents"
    |> SRQLBuilder.default_state(limit)
    |> SRQLBuilder.build()
  end

  defp upsert_release_filter(query, field, value) do
    query
    |> base_query()
    |> strip_filter_token(field)
    |> append_filter_token(field, value)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp base_query(query) when is_binary(query) do
    trimmed = String.trim(query)
    if trimmed == "", do: base_agents_query(@default_limit), else: trimmed
  end

  defp base_query(_query), do: base_agents_query(@default_limit)

  defp strip_filter_token(query, field) do
    Regex.replace(~r/(^|\s)!?#{field}:(?:"[^"]*"|\([^)]*\)|[^\s]+)/, query, "\\1")
  end

  defp append_filter_token(query, _field, value) when value in [nil, ""], do: query

  defp append_filter_token(query, field, value) do
    query <> " " <> "#{field}:#{escape_filter_value(value)}"
  end

  defp escape_filter_value(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace(" ", "\\ ")
  end

  defp release_filters_from_query(query) do
    %{
      "release_rollout_state" => extract_filter_value(query, "release_rollout_state"),
      "desired_version" => extract_filter_value(query, "desired_version")
    }
  end

  defp extract_filter_value(query, field) when is_binary(query) do
    case Regex.run(~r/(?:^|\s)#{field}:(?:"([^"]*)"|(\([^)]*\))|([^\s]+))/, query) do
      [_, quoted, _, _] when is_binary(quoted) and quoted != "" ->
        quoted

      [_, _, list, _] when is_binary(list) and list != "" ->
        list |> String.trim_leading("(") |> String.trim_trailing(")")

      [_, _, _, scalar] when is_binary(scalar) and scalar != "" ->
        String.replace(scalar, "\\ ", " ")

      _ ->
        ""
    end
  end

  defp extract_filter_value(_query, _field), do: ""

  defp load_summary_agents(scope, query, fallback_agents) do
    summary_query =
      query
      |> base_query()
      |> then(&Regex.replace(~r/(^|\s)limit:\d+/, &1, "\\1"))
      |> String.trim()
      |> Kernel.<>(" limit:#{@summary_limit}")

    case srql_module().query(summary_query, %{scope: scope, limit: @summary_limit}) do
      {:ok, %{"results" => results}} when is_list(results) -> results
      _ -> fallback_agents
    end
  end

  defp summarize_versions(agents) do
    agents
    |> Enum.reduce(%{}, fn agent, acc ->
      Map.update(acc, agent_version(agent), 1, &(&1 + 1))
    end)
    |> Enum.reject(fn {version, _count} -> version in [nil, "", "—"] end)
    |> Enum.sort_by(fn {version, count} -> {-count, version} end)
    |> Enum.take(8)
    |> Enum.map(fn {version, count} -> %{version: version, count: count} end)
  end

  defp summarize_rollout_states(agents) do
    agents
    |> Enum.reduce(%{}, fn agent, acc ->
      state =
        normalize_release_state(
          Map.get(agent, "release_rollout_state"),
          Map.get(agent, "last_update_error") not in [nil, ""]
        )

      case state do
        {:none, _} ->
          acc

        {normalized_state, has_error} ->
          key = {normalized_state, has_error}
          Map.update(acc, key, 1, &(&1 + 1))
      end
    end)
    |> Enum.sort_by(fn {{state, _}, count} -> {-count, Atom.to_string(state)} end)
    |> Enum.map(fn {{state, has_error}, count} ->
      {label, variant} = rollout_state_metadata(state, has_error)
      %{state: Atom.to_string(state), count: count, label: label, variant: variant}
    end)
  end

  defp rollout_state_metadata(:pending, _), do: {"Pending", "ghost"}
  defp rollout_state_metadata(:dispatched, _), do: {"Dispatched", "info"}
  defp rollout_state_metadata(:downloading, _), do: {"Downloading", "info"}
  defp rollout_state_metadata(:verifying, _), do: {"Verifying", "info"}
  defp rollout_state_metadata(:staged, _), do: {"Staged", "warning"}
  defp rollout_state_metadata(:restarting, _), do: {"Restarting", "warning"}
  defp rollout_state_metadata(:healthy, _), do: {"Healthy", "success"}
  defp rollout_state_metadata(:failed, _), do: {"Failed", "error"}
  defp rollout_state_metadata(:rolled_back, _), do: {"Rolled Back", "error"}
  defp rollout_state_metadata(:canceled, _), do: {"Canceled", "ghost"}
  defp rollout_state_metadata(:none, true), do: {"Error", "error"}
  defp rollout_state_metadata(_state, _has_error), do: {"Unknown", "ghost"}

  defp rollout_filter_badge_variant("success"), do: "success"
  defp rollout_filter_badge_variant("info"), do: "info"
  defp rollout_filter_badge_variant("warning"), do: "warning"
  defp rollout_filter_badge_variant("error"), do: "danger"
  defp rollout_filter_badge_variant(_variant), do: "ghost"

  defp visible_rollout_handoff_path(agents, release_filters) do
    agent_ids =
      agents
      |> Enum.map(&agent_uid/1)
      |> Enum.reject(&(&1 in [nil, "", "unknown"]))

    params =
      maybe_put_handoff_version(
        [
          {"cohort", "custom"},
          {"agent_ids", Enum.join(agent_ids, "\n")},
          {"notes", "Imported from /agents inventory view"},
          {"source", "agents"}
        ],
        Map.get(release_filters, "desired_version")
      )

    "/settings/agents/releases?" <> URI.encode_query(params)
  end

  defp selected_rollout_handoff_path(agent_ids, release_filters) do
    params =
      maybe_put_handoff_version(
        [
          {"cohort", "custom"},
          {"agent_ids", Enum.join(agent_ids, "\n")},
          {"notes", "Imported from selected /agents rows"},
          {"source", "agents_selection"}
        ],
        Map.get(release_filters, "desired_version")
      )

    "/settings/agents/releases?" <> URI.encode_query(params)
  end

  defp maybe_put_handoff_version(params, value) when value in [nil, ""], do: params
  defp maybe_put_handoff_version(params, value), do: [{"version", value} | params]

  defp selected_agent_ids_for_visible(selected_agent_ids, agents) do
    visible_ids = MapSet.new(Enum.map(agents, &agent_uid/1))
    Enum.filter(selected_agent_ids, &MapSet.member?(visible_ids, &1))
  end

  defp toggle_selected_agent_id(selected_agent_ids, agent_id) do
    if agent_id in selected_agent_ids do
      Enum.reject(selected_agent_ids, &(&1 == agent_id))
    else
      selected_agent_ids ++ [agent_id]
    end
  end

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
