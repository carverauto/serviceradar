defmodule ServiceRadarWebNGWeb.Admin.AddonFleetLive.Index do
  @moduledoc """
  Fleet-wide reporting view for native agent add-ons (issue 3425, reworked for
  4384).

  Where Admin.AddonPackageLive.Index is catalog/assignment-centric, this page is
  operations-centric: one card per agent, with one compact row per add-on showing
  the effective state — assigned version, running version, health — and drift
  rendered as an honest comparison of the two present sides. Historical or
  superseded assignments and long runtime diagnostics live in an expandable
  per-add-on detail instead of peer rows or truncated cells, and catalog-only
  inventory (imported but assigned nowhere) is a separate section rather than
  agentless fleet rows.

  Read-only; gated by `plugins.view` (same permission as the add-on catalog page).
  All data comes from the ServiceRadarWebNG.Plugins.AddonFleet context, which reads
  the ServiceRadar.Plugins.Addon* and ServiceRadar.Inventory.EndpointInventoryScan
  Ash resources with the current scope.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.Plugins.AddonFleet
  alias ServiceRadarWebNG.Plugins.AddonRollouts
  alias ServiceRadarWebNG.Plugins.AddonRolloutView
  alias ServiceRadarWebNG.Plugins.AddonRuntimePolicy
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  @base_path "/settings/agents/addons/fleet"

  @categories ~w(healthy updating action_required unavailable expected_inactive observed_only)

  @finished_rollout_page_size 10

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "plugins.view") do
      {:ok,
       socket
       |> assign(:can_manage_rollouts, RBAC.can?(scope, "plugins.assign"))
       |> load_fleet(default_filters())}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to view the add-on fleet.")
       |> redirect(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_params(_params, url, socket) do
    {:noreply, assign(socket, :current_path, URI.parse(url).path)}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter} = _params, socket) do
    {:noreply, apply_filters(socket, Map.merge(default_filters(), filter))}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, apply_filters(socket, default_filters())}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_fleet(socket, socket.assigns.filters)}
  end

  def handle_event("rollout_action", %{"id" => id, "operation" => operation}, socket) do
    result =
      case operation do
        "pause" -> AddonRollouts.pause(id, scope: socket.assigns.current_scope)
        "resume" -> AddonRollouts.resume(id, scope: socket.assigns.current_scope)
        "cancel" -> AddonRollouts.cancel(id, scope: socket.assigns.current_scope)
        "rollback" -> AddonRollouts.rollback(id, scope: socket.assigns.current_scope)
        "retry" -> AddonRollouts.retry(id, scope: socket.assigns.current_scope)
        _ -> {:error, :unsupported_operation}
      end

    socket =
      case result do
        :ok ->
          socket
          |> put_flash(:info, "Rollout #{operation} accepted.")
          |> load_fleet(socket.assigns.filters)

        {:ok, _rollout} ->
          socket
          |> put_flash(:info, "Rollout #{operation} accepted.")
          |> load_fleet(socket.assigns.filters)

        {:error, reason} ->
          put_flash(socket, :error, "Rollout action failed: #{AddonRollouts.format_error(reason)}")
      end

    {:noreply, socket}
  end

  def handle_event("toggle_finished_rollouts", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_finished_rollouts, !socket.assigns.show_finished_rollouts)
     |> assign(:finished_rollout_page, 1)}
  end

  def handle_event("finished_rollout_page", %{"page" => page}, socket) do
    finished_count =
      socket.assigns.rollouts
      |> Enum.reject(& &1.active?)
      |> length()

    page = clamp_page(page, finished_count, socket.assigns.finished_rollout_page_size)

    {:noreply, assign(socket, :finished_rollout_page, page)}
  end

  def handle_event("focus_rollout", %{"id" => id}, socket) do
    rollout = Enum.find(socket.assigns.rollouts, &(&1.id == id))

    show_finished =
      socket.assigns.show_finished_rollouts or
        (is_map(rollout) and not rollout.active?)

    finished_index =
      socket.assigns.rollouts
      |> Enum.reject(& &1.active?)
      |> Enum.find_index(&(&1.id == id))

    page =
      if is_integer(finished_index),
        do: div(finished_index, socket.assigns.finished_rollout_page_size) + 1,
        else: socket.assigns.finished_rollout_page

    {:noreply,
     socket
     |> assign(:show_finished_rollouts, show_finished)
     |> assign(:finished_rollout_page, page)
     |> assign(:expanded_rollouts, MapSet.put(socket.assigns.expanded_rollouts, id))}
  end

  def handle_event("toggle_rollout_details", %{"id" => id}, socket) do
    expanded = socket.assigns.expanded_rollouts

    expanded =
      if MapSet.member?(expanded, id),
        do: MapSet.delete(expanded, id),
        else: MapSet.put(expanded, id)

    {:noreply, assign(socket, :expanded_rollouts, expanded)}
  end

  def handle_event("toggle_details", %{"row" => key}, socket) do
    expanded = socket.assigns.expanded_rows

    expanded =
      if MapSet.member?(expanded, key),
        do: MapSet.delete(expanded, key),
        else: MapSet.put(expanded, key)

    {:noreply, assign(socket, :expanded_rows, expanded)}
  end

  defp load_fleet(socket, filters) do
    %{rows: rows, catalog_only: catalog_only} =
      AddonFleet.overview(scope: socket.assigns.current_scope)

    show_finished = Map.get(socket.assigns, :show_finished_rollouts, false)
    finished_page = Map.get(socket.assigns, :finished_rollout_page, 1)
    rollouts = AddonRollouts.list(scope: socket.assigns.current_scope)
    finished_count = Enum.count(rollouts, &(not &1.active?))
    finished_page = clamp_page(finished_page, finished_count, @finished_rollout_page_size)

    socket
    |> assign(:page_title, "Add-on Fleet")
    |> assign(:current_path, @base_path)
    |> assign(:all_rows, rows)
    |> assign(:catalog_only, catalog_only)
    |> assign(:rollouts, rollouts)
    |> assign(:show_finished_rollouts, show_finished)
    |> assign(:finished_rollout_page, finished_page)
    |> assign(:finished_rollout_page_size, @finished_rollout_page_size)
    |> assign(:expanded_rows, MapSet.new())
    |> assign(:expanded_rollouts, MapSet.new())
    |> assign(:categories, @categories)
    |> assign(:agent_options, AddonFleet.agents(rows))
    |> assign(:addon_options, AddonFleet.addon_ids(rows))
    |> apply_filters(filters)
  end

  defp apply_filters(socket, filters) do
    rows = AddonFleet.filter(socket.assigns.all_rows, filters)

    socket
    |> assign(:filters, filters)
    |> assign(:rows, rows)
    |> assign(:agent_groups, group_rows_by_agent(rows))
    |> assign(:summary, AddonFleet.summary(rows))
  end

  defp default_filters do
    %{
      "agent_uid" => "",
      "addon_id" => "",
      "category" => "",
      "attention_only" => "false"
    }
  end

  defp row_key(row), do: "#{row.agent_uid}|#{row.addon_id}"

  defp group_rows_by_agent(rows) do
    rows
    |> Enum.group_by(& &1.agent_uid)
    |> Enum.map(fn {agent_uid, agent_rows} ->
      %{
        agent_uid: agent_uid,
        agent_label: agent_rows |> List.first() |> Map.get(:agent_label, agent_uid),
        rows: Enum.sort_by(agent_rows, &{String.downcase(to_string(&1.addon_name)), &1.addon_id}),
        managed: Enum.count(agent_rows, & &1.assigned?),
        attention: Enum.count(agent_rows, & &1.attention?),
        unavailable: Enum.count(agent_rows, &(&1.category == :unavailable))
      }
    end)
    |> Enum.sort_by(&{String.downcase(to_string(&1.agent_label)), to_string(&1.agent_uid)})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.settings_chrome
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-sr-ink">Add-on Fleet</h1>
            <p class="text-sm text-sr-muted">
              Each agent is grouped once with its assigned and observed add-ons,
              versions, approval state, and runtime health.
            </p>
          </div>
          <.ui_button variant="ghost" size="sm" phx-click="refresh">
            <.icon name="hero-arrow-path" class="size-4" /> Refresh
          </.ui_button>
        </div>

        <div class="grid grid-cols-2 gap-3 md:grid-cols-4 xl:grid-cols-7">
          <.stat_card label="Managed" value={@summary.managed} />
          <.stat_card label="Healthy" value={@summary.healthy} tone="success" />
          <.stat_card label="Updating" value={@summary.updating} tone="info" />
          <.stat_card label="Needs attention" value={@summary.action_required} tone="error" />
          <.stat_card label="Unavailable" value={@summary.unavailable} tone="warning" />
          <.stat_card label="Expected idle" value={@summary.expected_inactive} />
          <.stat_card label="Observed only" value={@summary.observed_only} />
        </div>

        <.ui_panel>
          <:header>
            <div class="text-sm font-semibold">Filters</div>
          </:header>

          <form id="addon-fleet-filters" phx-change="filter" class="flex flex-wrap items-end gap-3">
            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Agent</span>
              </label>
              <select
                name="filter[agent_uid]"
                class={ui_field_class(size: "sm", class: "min-w-[16rem]")}
              >
                <option value="">All agents</option>
                <%= for {label, uid} <- @agent_options do %>
                  <option value={uid} selected={@filters["agent_uid"] == uid}>{label}</option>
                <% end %>
              </select>
            </div>

            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Health category</span>
              </label>
              <select
                name="filter[category]"
                class={ui_field_class(size: "sm", class: "min-w-[12rem]")}
              >
                <option value="">All categories</option>
                <%= for category <- @categories do %>
                  <option value={category} selected={@filters["category"] == category}>
                    {category |> String.replace("_", " ") |> String.capitalize()}
                  </option>
                <% end %>
              </select>
            </div>

            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Add-on</span>
              </label>
              <select
                name="filter[addon_id]"
                class={ui_field_class(size: "sm", class: "min-w-[12rem]")}
              >
                <option value="">All add-ons</option>
                <%= for addon_id <- @addon_options do %>
                  <option value={addon_id} selected={@filters["addon_id"] == addon_id}>
                    {addon_id}
                  </option>
                <% end %>
              </select>
            </div>

            <label class="flex cursor-pointer items-center gap-2 gap-2">
              <input
                type="checkbox"
                name="filter[attention_only]"
                value="true"
                checked={@filters["attention_only"] in [true, "true", "on"]}
                class={ui_checkbox_class()}
              />
              <span class="text-sm font-medium text-sr-ink">Needs attention only</span>
            </label>

            <.ui_button variant="ghost" size="sm" type="button" phx-click="clear_filters">
              Clear
            </.ui_button>
          </form>
        </.ui_panel>

        <.ui_panel :if={@rollouts != []}>
          <:header>
            <div class="flex w-full flex-wrap items-start justify-between gap-3">
              <div>
                <div class="text-sm font-semibold">Automatic rollouts</div>
                <p class="text-xs text-sr-muted">
                  A newer approved version starts on a canary agent. If that agent
                  does not stay healthy, we roll it back and pause so the rest of
                  the fleet stays on the last good version. These rows are
                  profile or agent assignments, not devices.
                </p>
              </div>
              <.ui_button
                :if={Enum.any?(@rollouts, &(not &1.active?))}
                variant="ghost"
                size="sm"
                type="button"
                phx-click="toggle_finished_rollouts"
              >
                {if @show_finished_rollouts,
                  do: "Hide finished",
                  else: "Show finished (#{Enum.count(@rollouts, &(not &1.active?))})"}
              </.ui_button>
            </div>
          </:header>

          <% visible_finished_rollouts =
            @rollouts
            |> visible_rollouts(@show_finished_rollouts)
            |> Enum.reject(& &1.active?) %>
          <div class="sr-ui-table-shell">
            <table class={ui_table_class(size: "sm")}>
              <thead>
                <tr class="text-xs uppercase tracking-wide text-sr-muted">
                  <th>Add-on</th>
                  <th>Who</th>
                  <th>Update</th>
                  <th>What happened</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for rollout <- paged_rollouts(@rollouts, @show_finished_rollouts, @finished_rollout_page, @finished_rollout_page_size) do %>
                  <% expanded? = MapSet.member?(@expanded_rollouts, rollout.id) %>
                  <tr
                    id={"addon-rollout-#{rollout.id}"}
                    data-role="addon-rollout-row"
                    class={rollout.attention? && "bg-warning/5"}
                  >
                    <td class="align-top">
                      <div class="font-medium">{rollout.addon_name}</div>
                      <div class="font-mono text-[11px] text-sr-muted">{rollout.addon_id}</div>
                      <div class="mt-1 text-[11px] text-sr-muted">
                        {rollout.trigger_label} update
                      </div>
                    </td>
                    <td class="align-top" data-role="addon-rollout-scope">
                      <.ui_badge size="xs" variant="ghost">
                        {if rollout.scope_kind == :profile, do: "Profile", else: "Agent"}
                      </.ui_badge>
                      <div class="mt-1 font-medium text-sr-ink">
                        <.link
                          :if={rollout.scope_href}
                          navigate={rollout.scope_href}
                          class="hover:underline"
                        >
                          {rollout.scope_label}
                        </.link>
                        <span :if={is_nil(rollout.scope_href)}>{rollout.scope_label}</span>
                      </div>
                      <div class="text-xs text-sr-muted">{rollout.scope_caption}</div>
                    </td>
                    <td class="align-top">
                      <div class="font-mono text-xs">
                        {rollout.previous_version} → {rollout.candidate_version}
                      </div>
                      <div class="mt-1 text-xs text-sr-muted">{rollout.progress_label}</div>
                    </td>
                    <td class="align-top">
                      <.ui_badge size="sm" variant={rollout_state_badge_variant(rollout.state)}>
                        {rollout.state_label}
                      </.ui_badge>
                      <p
                        data-role="addon-rollout-summary"
                        class={[
                          "mt-1 max-w-md text-xs leading-snug",
                          if(rollout.attention?, do: "text-warning", else: "text-sr-muted")
                        ]}
                      >
                        {rollout.summary}
                      </p>
                    </td>
                    <td class="align-top text-right">
                      <div class="flex flex-wrap justify-end gap-1">
                        <.ui_button
                          phx-click="toggle_rollout_details"
                          phx-value-id={rollout.id}
                          aria-expanded={to_string(expanded?)}
                          size="xs"
                          variant="ghost"
                        >
                          {if expanded?, do: "Hide details", else: "Details"}
                        </.ui_button>
                        <div :if={@can_manage_rollouts} class="flex flex-wrap justify-end gap-1">
                          <.ui_button
                            :if={rollout.state in [:pending, :running]}
                            phx-click="rollout_action"
                            phx-value-id={rollout.id}
                            phx-value-operation="pause"
                            size="xs"
                            variant="ghost"
                          >
                            Pause
                          </.ui_button>
                          <.ui_button
                            :if={rollout.state == :paused}
                            phx-click="rollout_action"
                            phx-value-id={rollout.id}
                            phx-value-operation="resume"
                            size="xs"
                            variant="ghost"
                          >
                            Resume
                          </.ui_button>
                          <.ui_button
                            :if={rollout.state in [:failed, :rolled_back]}
                            phx-click="rollout_action"
                            phx-value-id={rollout.id}
                            phx-value-operation="retry"
                            data-confirm="Start a fresh health-gated attempt for this candidate?"
                            size="xs"
                            variant="ghost"
                            class="text-info"
                          >
                            Retry
                          </.ui_button>
                          <.ui_button
                            :if={rollout.state in [:pending, :running, :paused]}
                            phx-click="rollout_action"
                            phx-value-id={rollout.id}
                            phx-value-operation="rollback"
                            data-confirm="Roll every advanced target back to the prior package?"
                            size="xs"
                            variant="ghost"
                            class="text-warning"
                          >
                            Roll back
                          </.ui_button>
                          <.ui_button
                            :if={rollout.state in [:pending, :running, :paused]}
                            phx-click="rollout_action"
                            phx-value-id={rollout.id}
                            phx-value-operation="cancel"
                            data-confirm="Cancel this rollout and restore stable desired state?"
                            size="xs"
                            variant="ghost"
                            class="text-error"
                          >
                            Cancel
                          </.ui_button>
                        </div>
                      </div>
                    </td>
                  </tr>
                  <tr :if={expanded?} data-role="addon-rollout-detail" class="bg-sr-subtle/20">
                    <td colspan="5" class="p-0">
                      <.rollout_details
                        rollout={rollout}
                        timezone={@current_scope.user.timezone || "Etc/UTC"}
                      />
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
            <.pagination_controls
              :if={length(visible_finished_rollouts) > @finished_rollout_page_size}
              id_prefix="addon-finished-rollouts"
              event="finished_rollout_page"
              page={@finished_rollout_page}
              total_items={length(visible_finished_rollouts)}
              page_size={@finished_rollout_page_size}
            />
          </div>
        </.ui_panel>

        <.ui_panel>
          <:header>
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div>
                <div class="text-sm font-semibold">Agent add-on inventory</div>
                <p class="text-xs text-sr-muted">
                  Agent identity and aggregate health appear once; expand an add-on for diagnostics.
                </p>
              </div>
              <div class="text-xs text-sr-muted">
                {length(@agent_groups)} agent(s) · {length(@rows)} add-on(s)
              </div>
            </div>
          </:header>

          <%= if @agent_groups == [] do %>
            <div class="rounded-xl border border-dashed border-sr-line bg-sr-surface p-6 text-center">
              <div class="text-sm font-semibold text-sr-ink">
                No matching add-on deployments
              </div>
              <p class="mt-1 text-xs text-sr-muted">Adjust the filters above.</p>
            </div>
          <% else %>
            <div id="addon-fleet-table" class="space-y-4">
              <article
                :for={group <- @agent_groups}
                data-role="agent-addon-card"
                data-agent-uid={group.agent_uid}
                class="overflow-hidden rounded-xl border border-sr-line bg-sr-surface"
              >
                <header class="flex flex-wrap items-center justify-between gap-3 border-b border-sr-line bg-sr-subtle/30 px-4 py-3">
                  <div class="min-w-0">
                    <h2
                      data-role="agent-card-label"
                      class="truncate text-base font-semibold text-sr-ink"
                      title={group.agent_label}
                    >
                      {group.agent_label}
                    </h2>
                    <div class="font-mono text-[11px] text-sr-muted">{group.agent_uid}</div>
                  </div>
                  <div class="flex flex-wrap items-center justify-end gap-2 text-xs">
                    <.ui_badge size="sm" variant="ghost">{length(group.rows)} add-ons</.ui_badge>
                    <.ui_badge size="sm" variant="ghost">{group.managed} managed</.ui_badge>
                    <.ui_badge :if={group.unavailable > 0} size="sm" variant="warning">
                      {group.unavailable} unavailable
                    </.ui_badge>
                    <.ui_badge :if={group.attention > 0} size="sm" variant="error">
                      {group.attention} need attention
                    </.ui_badge>
                    <.ui_badge
                      :if={group.attention == 0 and group.unavailable == 0}
                      size="sm"
                      variant="success"
                    >
                      no active alerts
                    </.ui_badge>
                  </div>
                </header>

                <div class="sr-ui-table-shell">
                  <table class={ui_table_class(size: "sm")}>
                    <thead>
                      <tr class="text-xs uppercase tracking-wide text-sr-muted">
                        <th class="w-8"></th>
                        <th>Add-on</th>
                        <th>Version</th>
                        <th>Desired</th>
                        <th>Runtime</th>
                        <th>Last observed</th>
                        <th>Health</th>
                      </tr>
                    </thead>
                    <tbody>
                      <%= for row <- group.rows do %>
                        <% expanded? = MapSet.member?(@expanded_rows, row_key(row)) %>
                        <tr
                          data-role="fleet-row"
                          class={["hover:bg-sr-subtle/30", row.attention? && "bg-error/5"]}
                        >
                          <td class="align-top">
                            <.ui_icon_button
                              type="button"
                              phx-click="toggle_details"
                              phx-value-row={row_key(row)}
                              aria-expanded={to_string(expanded?)}
                              aria-label={"Toggle details for #{row.addon_id} on #{row.agent_label}"}
                              size="xs"
                              variant="ghost"
                            >
                              <.icon
                                name={
                                  if expanded?, do: "hero-chevron-down", else: "hero-chevron-right"
                                }
                                class="size-4"
                              />
                            </.ui_icon_button>
                          </td>
                          <td class="min-w-[13rem] align-top">
                            <div class="font-medium">{row.addon_name}</div>
                            <div class="text-xs font-mono text-sr-muted">{row.addon_id}</div>
                            <.ui_badge :if={row.collector?} size="xs" variant="ghost">
                              collector
                            </.ui_badge>
                          </td>
                          <td class="min-w-[10rem] align-top"><.version_cell row={row} /></td>
                          <td class="align-top">
                            <div class="flex flex-col items-start gap-1">
                              <.ui_badge
                                size="sm"
                                variant={package_status_badge_variant(row.package_status)}
                              >
                                {package_status_label(row.package_status)}
                              </.ui_badge>
                              <.ui_badge
                                data-role={"assignment-#{row.management_mode}"}
                                size="sm"
                                variant={assigned_badge_variant(row)}
                              >
                                {assigned_label(row)}
                              </.ui_badge>
                            </div>
                          </td>
                          <td class="align-top">
                            <.ui_badge size="sm" variant={running_badge_variant(row)}>
                              {running_label(row)}
                            </.ui_badge>
                            <button
                              :if={row.degradation_reason}
                              type="button"
                              class={[
                                "mt-1 block text-left text-xs underline decoration-dotted",
                                diagnostic_link_class(row.degradation_reason)
                              ]}
                              phx-click="toggle_details"
                              phx-value-row={row_key(row)}
                            >
                              diagnostics
                            </button>
                          </td>
                          <td class="align-top text-xs text-sr-muted">
                            <div>
                              <.user_time
                                id={"admin-addon-fleet-#{dom_id_segment(row.agent_uid)}-#{dom_id_segment(row.addon_id)}-reported-at"}
                                value={row.reported_at}
                                timezone={@current_scope.user.timezone || "Etc/UTC"}
                                style={:compact}
                              />
                            </div>
                            <div
                              :if={row.collector? and row.last_scan_at}
                              class="text-sr-muted"
                            >
                              scan
                              <.user_time
                                id={"admin-addon-fleet-#{dom_id_segment(row.agent_uid)}-#{dom_id_segment(row.addon_id)}-last-scan-at"}
                                value={row.last_scan_at}
                                timezone={@current_scope.user.timezone || "Etc/UTC"}
                                style={:compact}
                              />
                            </div>
                          </td>
                          <td class="min-w-[14rem] align-top">
                            <.health_cell row={row} />
                          </td>
                        </tr>
                        <tr :if={expanded?} class="bg-sr-subtle/20">
                          <td></td>
                          <td colspan="6" class="py-3"><.row_details row={row} /></td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              </article>
            </div>
          <% end %>
        </.ui_panel>

        <.ui_panel :if={@catalog_only != []}>
          <:header>
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div>
                <div class="text-sm font-semibold">Catalog inventory</div>
                <p class="text-xs text-sr-muted">
                  Imported add-ons not assigned to and not reported by any agent.
                </p>
              </div>
              <.ui_button variant="ghost" size="sm" navigate="/settings/agents/addons">
                Open catalog
              </.ui_button>
            </div>
          </:header>

          <div class="sr-ui-table-shell">
            <table class={ui_table_class(size: "sm")}>
              <thead>
                <tr class="text-xs uppercase tracking-wide text-sr-muted">
                  <th>Add-on</th>
                  <th>Latest version</th>
                  <th>Status</th>
                  <th>Verification</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for entry <- @catalog_only do %>
                  <tr data-role="catalog-only-row" class="hover:bg-sr-subtle/30">
                    <td>
                      <div class="font-medium">{entry.addon_name}</div>
                      <div class="text-xs font-mono text-sr-muted">{entry.addon_id}</div>
                    </td>
                    <td class="text-xs font-mono">
                      {entry.version || "—"}
                      <span :if={entry.versions > 1} class="text-sr-muted">
                        (+{entry.versions - 1} older)
                      </span>
                    </td>
                    <td>
                      <.ui_badge
                        size="sm"
                        variant={package_status_badge_variant(entry.package_status)}
                      >
                        {package_status_label(entry.package_status)}
                      </.ui_badge>
                    </td>
                    <td>
                      <.ui_badge
                        size="xs"
                        variant={verification_badge_variant(entry.verification_status)}
                      >
                        {entry.verification_status || "unverified"}
                      </.ui_badge>
                    </td>
                    <td class="text-right">
                      <.ui_button
                        variant="ghost"
                        size="xs"
                        navigate={"/settings/agents/addons/" <> entry.package_id}
                      >
                        View
                      </.ui_button>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </.ui_panel>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  attr :row, :map, required: true

  # Version state rendered as an honest comparison: both sides shown for drift,
  # nothing fabricated when a side is missing (never "drift: 0.0.0").
  defp version_cell(assigns) do
    ~H"""
    <%= case @row.version_status do %>
      <% {:up_to_date, version, true} -> %>
        <div data-role="version-up-to-date">
          <.ui_badge size="sm" variant="success">up to date</.ui_badge>
          <div class="mt-1 text-xs font-mono text-sr-muted">{version}</div>
        </div>
      <% {:up_to_date, version, false} -> %>
        <div data-role="version-in-sync">
          <div class="text-xs font-mono">{version}</div>
          <div class="text-xs text-sr-muted">in sync with assignment</div>
          <div :if={@row.latest_approved_version} class="text-xs text-info">
            newer approved: {@row.latest_approved_version}
          </div>
        </div>
      <% {:drift, running, assigned} -> %>
        <div data-role="version-drift" class="text-xs text-warning">
          running <span class="font-mono">{running}</span>
          → assigned <span class="font-mono">{assigned}</span>
        </div>
      <% {:required_runtime, version} -> %>
        <div data-role="version-required-runtime" class="text-xs">
          running <span :if={version} class="font-mono">{version}</span>
          <div class="text-sr-muted">required runtime</div>
        </div>
      <% {:running_unassigned, version} -> %>
        <div data-role="version-running-unassigned" class="text-xs">
          running <span :if={version} class="font-mono">{version}</span> (unassigned)
        </div>
      <% {:not_reported, version} -> %>
        <div data-role="version-not-reported" class="text-xs text-sr-muted">
          <span :if={version}>assigned <span class="font-mono">{version}</span> ·</span> not reported
        </div>
      <% _ -> %>
        <span class="text-xs text-sr-muted">—</span>
    <% end %>
    """
  end

  attr :rollout, :map, required: true
  attr :timezone, :string, required: true

  defp rollout_details(assigns) do
    targets = Enum.sort_by(assigns.rollout.targets, &{&1.batch_index, &1.agent_uid})
    assigns = assign(assigns, :targets, targets)

    ~H"""
    <section class="p-4" aria-label={"Rollout evidence for #{@rollout.addon_name}"}>
      <.ui_alert
        variant={if @rollout.attention?, do: "warning", else: "info"}
        class="mb-4"
      >
        {@rollout.summary}
      </.ui_alert>

      <div class="flex flex-wrap items-center justify-between gap-2">
        <div>
          <div class="text-sm font-semibold">Agents in this rollout</div>
          <p class="text-xs text-sr-muted">
            After the candidate is pushed, that agent must report healthy on the
            new version before later batches start.
          </p>
        </div>
        <.ui_badge size="sm" variant="ghost">
          {length(@targets)} {if length(@targets) == 1, do: "agent", else: "agents"}
        </.ui_badge>
      </div>

      <div :if={@targets == []} class="mt-3 text-sm text-sr-muted">
        No agents were targeted. This candidate was blocked before delivery.
      </div>

      <div :if={@targets != []} class="mt-3 overflow-x-auto">
        <table class={ui_table_class(size: "xs")}>
          <thead>
            <tr class="text-xs uppercase tracking-wide text-sr-muted">
              <th>Agent</th>
              <th>Wave</th>
              <th>Eligibility</th>
              <th>State</th>
              <th>Why</th>
              <th>Latest evidence</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={target <- @targets} data-role="addon-rollout-target">
              <td data-role="addon-rollout-target-agent">
                <.link
                  :if={target.agent_href}
                  navigate={target.agent_href}
                  class="font-medium hover:underline"
                >
                  {target.agent_name}
                </.link>
                <span :if={is_nil(target.agent_href)} class="font-medium">{target.agent_name}</span>
                <div
                  :if={target.agent_uid && target.agent_uid != target.agent_name}
                  class="font-mono text-[11px] text-sr-muted"
                >
                  {target.agent_uid}
                </div>
              </td>
              <td>{target.batch_label}</td>
              <td>{target.classification_label}</td>
              <td>
                <.ui_badge size="xs" variant={rollout_target_state_badge_variant(target.state)}>
                  {target.state_label}
                </.ui_badge>
              </td>
              <td class="max-w-sm whitespace-normal">
                <div>{target.reason_label || "No reason recorded"}</div>
                <div :if={target.error} class="mt-1 text-error">{target.error}</div>
              </td>
              <td class="whitespace-nowrap text-xs text-sr-muted">
                <.user_time
                  id={"admin-addon-rollout-#{dom_id_segment(@rollout.id)}-target-#{dom_id_segment(target.agent_uid)}-evidence-at"}
                  value={target_evidence_at(target)}
                  timezone={@timezone}
                  style={:compact}
                />
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  attr :row, :map, required: true

  defp health_cell(assigns) do
    health = assigns.row.health || AddonRolloutView.fleet_health(assigns.row)
    assigns = assign(assigns, :health, health)

    ~H"""
    <div class="flex max-w-[16rem] flex-col items-start gap-1">
      <.ui_badge
        size="xs"
        variant={health_badge_variant(@row)}
        class="h-auto whitespace-normal py-0.5 text-left leading-tight"
      >
        {@health.title}
      </.ui_badge>
      <p data-role="fleet-health-detail" class="text-xs leading-snug text-sr-muted">
        {@health.detail}
      </p>
      <span :if={@row.evidence_age_seconds} class="text-[11px] text-sr-muted">
        last report {format_age(@row.evidence_age_seconds)} ago
      </span>
      <.health_action row={@row} health={@health} />
    </div>
    """
  end

  attr :row, :map, required: true
  attr :health, :map, required: true

  defp health_action(%{health: %{action: :review_rollout}, row: %{rollout_id: id}} = assigns) when is_binary(id) do
    ~H"""
    <.ui_button
      href={"#addon-rollout-#{@row.rollout_id}"}
      phx-click="focus_rollout"
      phx-value-id={@row.rollout_id}
      size="xs"
      variant="ghost"
    >
      {@health.action_label}
    </.ui_button>
    """
  end

  defp health_action(%{health: %{action: :open_package}, row: %{package_id: id}} = assigns) when is_binary(id) do
    ~H"""
    <.ui_button variant="ghost" size="xs" navigate={"/settings/agents/addons/" <> @row.package_id}>
      {@health.action_label}
    </.ui_button>
    """
  end

  defp health_action(%{health: %{action: :inspect_runtime}} = assigns) do
    ~H"""
    <.ui_button
      type="button"
      variant="ghost"
      size="xs"
      phx-click="toggle_details"
      phx-value-row={row_key(@row)}
    >
      {@health.action_label}
    </.ui_button>
    """
  end

  defp health_action(assigns) do
    ~H"""
    """
  end

  attr :row, :map, required: true

  defp row_details(assigns) do
    ~H"""
    <div class="grid gap-3 text-xs md:grid-cols-2">
      <div class="space-y-2">
        <div :if={@row.health}>
          <div class="text-sr-muted uppercase tracking-wide">What to do</div>
          <p>{@row.health.detail}</p>
          <.health_action row={@row} health={@row.health} />
        </div>
        <div>
          <div class="text-sr-muted uppercase tracking-wide">Agent UID</div>
          <div class="font-mono break-all">{@row.agent_uid || "—"}</div>
        </div>
        <div>
          <div class="text-sr-muted uppercase tracking-wide">Assigned package</div>
          <div :if={@row.content_hash} class="font-mono break-all">{@row.content_hash}</div>
          <div :if={is_nil(@row.content_hash)} class="text-sr-muted">no package</div>
          <.ui_badge
            size="xs"
            variant={verification_badge_variant(@row.verification_status)}
            class="mt-1"
          >
            {@row.verification_status || "unverified"}
          </.ui_badge>
          <.ui_button
            :if={@row.package_id}
            variant="ghost"
            size="xs"
            navigate={"/settings/agents/addons/" <> @row.package_id}
          >
            Open package
          </.ui_button>
        </div>
        <div :if={@row.stale_assignments != []}>
          <div class="text-sr-muted uppercase tracking-wide">
            Other assignments on this agent
          </div>
          <ul class="mt-1 space-y-1">
            <li :for={stale <- @row.stale_assignments} class="font-mono">
              {stale.version || "unknown version"}
              <span class="font-sans text-sr-muted">
                ({if stale.enabled, do: "enabled", else: "disabled"}{if stale.source,
                  do: ", #{stale.source}"})
              </span>
            </li>
          </ul>
        </div>
      </div>
      <div class="space-y-2">
        <div>
          <div class="text-sr-muted uppercase tracking-wide">Runtime diagnostics</div>
          <div
            :if={@row.degradation_reason}
            class={[
              "whitespace-pre-wrap break-words",
              diagnostic_text_class(@row.degradation_reason)
            ]}
          >
            {@row.degradation_reason}
          </div>
          <div :if={is_nil(@row.degradation_reason)} class="text-sr-muted">
            no diagnostics reported
          </div>
        </div>
        <div :if={@row.running_version}>
          <div class="text-sr-muted uppercase tracking-wide">Reported version</div>
          <div class="font-mono">{@row.running_version}</div>
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :tone, :string, default: "neutral"

  defp stat_card(assigns) do
    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface p-4">
      <div class="text-xs uppercase tracking-wide text-sr-muted">{@label}</div>
      <div class={["mt-1 text-2xl font-semibold", stat_tone_class(@tone, @value)]}>{@value}</div>
    </div>
    """
  end

  defp stat_tone_class("error", value) when value > 0, do: "text-error"
  defp stat_tone_class("warning", value) when value > 0, do: "text-warning"
  defp stat_tone_class("success", value) when value > 0, do: "text-success"
  defp stat_tone_class("info", value) when value > 0, do: "text-info"
  defp stat_tone_class(_tone, _value), do: "text-sr-ink"

  defp verification_badge_variant("verified"), do: "success"
  defp verification_badge_variant("seeded"), do: "warning"
  defp verification_badge_variant(nil), do: "ghost"
  defp verification_badge_variant(_other), do: "error"

  defp package_status_badge_variant(:approved), do: "success"
  defp package_status_badge_variant(:staged), do: "warning"
  defp package_status_badge_variant(nil), do: "ghost"
  defp package_status_badge_variant(_other), do: "error"

  defp package_status_label(nil), do: "no package"
  defp package_status_label(status), do: to_string(status)

  defp assigned_badge_variant(%{assigned?: true, enabled?: true}), do: "success"
  defp assigned_badge_variant(%{assigned?: true}), do: "ghost"
  defp assigned_badge_variant(%{management_mode: :required}), do: "info"
  defp assigned_badge_variant(_row), do: "outline"

  defp assigned_label(%{assigned?: true, enabled?: true}), do: "enabled"
  defp assigned_label(%{assigned?: true}), do: "disabled"
  defp assigned_label(%{management_mode: :required}), do: "required"
  defp assigned_label(_row), do: "unassigned"

  defp running_badge_variant(%{category: :healthy}), do: "success"
  defp running_badge_variant(%{category: :expected_inactive}), do: "info"
  defp running_badge_variant(%{category: :updating}), do: "info"
  defp running_badge_variant(%{category: :unavailable}), do: "warning"
  defp running_badge_variant(%{active?: true}), do: "success"
  defp running_badge_variant(%{running_state: nil}), do: "ghost"
  defp running_badge_variant(_row), do: "error"

  defp running_label(%{running_state: nil}), do: "not reported"
  defp running_label(%{running_state: state}), do: state

  defp category_badge_variant(:healthy), do: "success"
  defp category_badge_variant(:updating), do: "info"
  defp category_badge_variant(:action_required), do: "error"
  defp category_badge_variant(:unavailable), do: "warning"
  defp category_badge_variant(:expected_inactive), do: "ghost"
  defp category_badge_variant(:observed_only), do: "outline"
  defp category_badge_variant(_), do: "ghost"

  defp health_badge_variant(%{category: :action_required, reason_code: reason})
       when reason in [
              "candidate_health_timeout",
              "candidate_reported_unhealthy",
              "rollback_recovery_unverified",
              "rollout_failed",
              "rollout_target_incompatible"
            ], do: "warning"

  defp health_badge_variant(%{category: category}), do: category_badge_variant(category)

  defp visible_rollouts(rollouts, true), do: rollouts

  defp visible_rollouts(rollouts, _show_finished) do
    if Enum.any?(rollouts, & &1.active?),
      do: Enum.filter(rollouts, & &1.active?),
      else: rollouts
  end

  # Active rollouts always render in full; the finished history pages at
  # @finished_rollout_page_size so a long tail stays reachable.
  defp paged_rollouts(rollouts, show_finished, page, page_size) do
    {active, finished} =
      rollouts
      |> visible_rollouts(show_finished)
      |> Enum.split_with(& &1.active?)

    active ++ paginated_items(finished, page, page_size)
  end

  defp paginated_items(items, page, page_size) when is_list(items) do
    page = clamp_page(page, length(items), page_size)

    items
    |> Enum.drop((page - 1) * page_size)
    |> Enum.take(page_size)
  end

  defp page_count(total_items, page_size) when is_integer(total_items) and total_items > 0,
    do: max(1, ceil(total_items / page_size))

  defp page_count(_total_items, _page_size), do: 1

  defp page_range(total_items, page, page_size) when total_items > 0 do
    page = clamp_page(page, total_items, page_size)
    first_item = (page - 1) * page_size + 1
    last_item = min(page * page_size, total_items)

    {first_item, last_item}
  end

  defp page_range(_total_items, _page, _page_size), do: {0, 0}

  defp clamp_page(page, total_items, page_size) do
    page =
      case page do
        page when is_integer(page) -> page
        page when is_binary(page) -> page |> Integer.parse() |> parsed_page()
        _ -> 1
      end

    page
    |> max(1)
    |> min(page_count(total_items, page_size))
  end

  defp parsed_page({page, _rest}), do: page
  defp parsed_page(:error), do: 1

  attr(:id_prefix, :string, required: true)
  attr(:event, :string, required: true)
  attr(:page, :integer, required: true)
  attr(:total_items, :integer, required: true)
  attr(:page_size, :integer, required: true)

  defp pagination_controls(assigns) do
    page_count = page_count(assigns.total_items, assigns.page_size)
    {first_item, last_item} = page_range(assigns.total_items, assigns.page, assigns.page_size)

    assigns =
      assign(assigns,
        page_count: page_count,
        first_item: first_item,
        last_item: last_item
      )

    ~H"""
    <div
      :if={@total_items > 0}
      class="flex flex-wrap items-center justify-between gap-3 border-t border-sr-line px-4 py-3 text-xs text-sr-muted"
    >
      <span>
        Showing {@first_item}-{@last_item} of {@total_items}
      </span>
      <div class={ui_join_class()}>
        <.ui_button
          id={"#{@id_prefix}-prev-page"}
          type="button"
          phx-click={@event}
          phx-value-page={@page - 1}
          disabled={@page <= 1}
          size="xs"
          variant="neutral"
        >
          Previous
        </.ui_button>
        <.ui_button type="button" disabled size="xs" variant="ghost">
          Page {@page} of {@page_count}
        </.ui_button>
        <.ui_button
          id={"#{@id_prefix}-next-page"}
          type="button"
          phx-click={@event}
          phx-value-page={@page + 1}
          disabled={@page >= @page_count}
          size="xs"
          variant="neutral"
        >
          Next
        </.ui_button>
      </div>
    </div>
    """
  end

  defp rollout_state_badge_variant(:completed), do: "success"
  defp rollout_state_badge_variant(state) when state in [:running, :pending], do: "info"
  defp rollout_state_badge_variant(:paused), do: "warning"
  defp rollout_state_badge_variant(state) when state in [:failed, :rolled_back], do: "error"
  defp rollout_state_badge_variant(_), do: "ghost"

  defp rollout_target_state_badge_variant(state) when state in [:succeeded, :promoted], do: "success"

  defp rollout_target_state_badge_variant(state) when state in [:waiting_health, :healthy_soak], do: "info"

  defp rollout_target_state_badge_variant(state) when state in [:failed, :rollback_pending, :rolled_back], do: "error"

  defp rollout_target_state_badge_variant(:excluded), do: "warning"
  defp rollout_target_state_badge_variant(_), do: "ghost"

  defp target_evidence_at(target) do
    target.health_observed_at || target.healthy_since || target.rollback_started_at ||
      target.override_applied_at
  end

  defp diagnostic_link_class(reason) do
    if AddonRuntimePolicy.resource_limit_warning?(reason), do: "text-warning", else: "text-error"
  end

  defp diagnostic_text_class(reason) do
    if AddonRuntimePolicy.resource_limit_warning?(reason), do: "text-warning", else: "text-error"
  end

  defp dom_id_segment(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_-]/u, "-")
  end

  defp format_age(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_age(seconds) when seconds < 3_600, do: "#{div(seconds, 60)}m"
  defp format_age(seconds), do: "#{div(seconds, 3_600)}h"
end
