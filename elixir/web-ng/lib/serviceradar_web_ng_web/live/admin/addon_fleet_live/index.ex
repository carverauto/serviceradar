defmodule ServiceRadarWebNGWeb.Admin.AddonFleetLive.Index do
  @moduledoc """
  Fleet-wide reporting view for native agent add-ons (issue 3425, reworked for
  4384).

  Where Admin.AddonPackageLive.Index is catalog/assignment-centric, this page is
  operations-centric: one row per (agent, add-on) showing the effective state —
  assigned version, running version, health — with drift rendered as an honest
  comparison of the two present sides. Historical/superseded assignments and long
  runtime diagnostics live in an expandable per-row detail instead of peer rows
  or truncated cells, and catalog-only inventory (imported but assigned nowhere)
  is a separate section rather than agentless fleet rows.

  Read-only; gated by `plugins.view` (same permission as the add-on catalog page).
  All data comes from the ServiceRadarWebNG.Plugins.AddonFleet context, which reads
  the ServiceRadar.Plugins.Addon* and ServiceRadar.Inventory.EndpointInventoryScan
  Ash resources with the current scope.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.Plugins.AddonFleet
  alias ServiceRadarWebNG.Plugins.AddonRollouts
  alias ServiceRadarWebNG.Plugins.AddonRuntimePolicy
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  @base_path "/settings/agents/addons/fleet"

  @attention_labels %{
    "runtime_reported_unhealthy" => "runtime reported unhealthy",
    "desired_package_not_approved" => "desired package is not approved",
    "desired_state_not_converged" => "desired state did not converge",
    "candidate_health_timeout" => "candidate health timed out",
    "rollback_recovery_unverified" => "rollback recovery is unverified"
  }

  @categories ~w(healthy updating action_required unavailable expected_inactive observed_only)

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
        _ -> {:error, :unsupported_operation}
      end

    socket =
      case result do
        :ok ->
          socket
          |> put_flash(:info, "Rollout #{operation} accepted.")
          |> load_fleet(socket.assigns.filters)

        {:error, reason} ->
          put_flash(socket, :error, "Rollout action failed: #{inspect(reason)}")
      end

    {:noreply, socket}
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

    socket
    |> assign(:page_title, "Add-on Fleet")
    |> assign(:current_path, @base_path)
    |> assign(:all_rows, rows)
    |> assign(:catalog_only, catalog_only)
    |> assign(:rollouts, AddonRollouts.list(scope: socket.assigns.current_scope))
    |> assign(:expanded_rows, MapSet.new())
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
            <h1 class="text-2xl font-semibold text-base-content">Add-on Fleet</h1>
            <p class="text-sm text-base-content/60">
              One row per agent and add-on: assigned version vs. what is actually
              running, approval, and runtime health across the fleet.
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
              <label class="label"><span class="label-text">Agent</span></label>
              <select name="filter[agent_uid]" class="select select-bordered select-sm min-w-[16rem]">
                <option value="">All agents</option>
                <%= for {label, uid} <- @agent_options do %>
                  <option value={uid} selected={@filters["agent_uid"] == uid}>{label}</option>
                <% end %>
              </select>
            </div>

            <div>
              <label class="label"><span class="label-text">Health category</span></label>
              <select name="filter[category]" class="select select-bordered select-sm min-w-[12rem]">
                <option value="">All categories</option>
                <%= for category <- @categories do %>
                  <option value={category} selected={@filters["category"] == category}>
                    {category |> String.replace("_", " ") |> String.capitalize()}
                  </option>
                <% end %>
              </select>
            </div>

            <div>
              <label class="label"><span class="label-text">Add-on</span></label>
              <select name="filter[addon_id]" class="select select-bordered select-sm min-w-[12rem]">
                <option value="">All add-ons</option>
                <%= for addon_id <- @addon_options do %>
                  <option value={addon_id} selected={@filters["addon_id"] == addon_id}>
                    {addon_id}
                  </option>
                <% end %>
              </select>
            </div>

            <label class="label cursor-pointer gap-2">
              <input
                type="checkbox"
                name="filter[attention_only]"
                value="true"
                checked={@filters["attention_only"] in [true, "true", "on"]}
                class="checkbox checkbox-sm"
              />
              <span class="label-text">Needs attention only</span>
            </label>

            <.ui_button variant="ghost" size="sm" type="button" phx-click="clear_filters">
              Clear
            </.ui_button>
          </form>
        </.ui_panel>

        <.ui_panel :if={@rollouts != []}>
          <:header>
            <div>
              <div class="text-sm font-semibold">Automatic rollouts</div>
              <p class="text-xs text-base-content/60">
                Signed and approved updates advance through canaries and health-gated batches.
              </p>
            </div>
          </:header>

          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr class="text-xs uppercase tracking-wide text-base-content/60">
                  <th>Add-on</th>
                  <th>Version</th>
                  <th>Progress</th>
                  <th>State</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={rollout <- @rollouts} data-role="addon-rollout-row">
                  <td>
                    <div class="font-medium">{rollout.addon_id}</div>
                    <div class="font-mono text-[11px] text-base-content/50">
                      {rollout.source_type} · {rollout.source_id}
                    </div>
                  </td>
                  <td class="font-mono text-xs">
                    {rollout.previous_package.version} → {rollout.candidate_package.version}
                  </td>
                  <td class="text-xs">{rollout_progress(rollout.targets)}</td>
                  <td>
                    <span class={["badge badge-sm", rollout_state_badge(rollout.state)]}>
                      {rollout.state}
                    </span>
                    <div :if={rollout.blocked_reason} class="mt-1 text-xs text-error">
                      {rollout.blocked_reason}
                    </div>
                  </td>
                  <td class="text-right">
                    <div :if={@can_manage_rollouts} class="flex justify-end gap-1">
                      <button
                        :if={rollout.state in [:pending, :running]}
                        class="btn btn-ghost btn-xs"
                        phx-click="rollout_action"
                        phx-value-id={rollout.id}
                        phx-value-operation="pause"
                      >
                        Pause
                      </button>
                      <button
                        :if={rollout.state == :paused}
                        class="btn btn-ghost btn-xs"
                        phx-click="rollout_action"
                        phx-value-id={rollout.id}
                        phx-value-operation="resume"
                      >
                        Resume
                      </button>
                      <button
                        :if={rollout.state in [:pending, :running, :paused]}
                        class="btn btn-ghost btn-xs text-warning"
                        phx-click="rollout_action"
                        phx-value-id={rollout.id}
                        phx-value-operation="rollback"
                        data-confirm="Roll every advanced target back to the prior package?"
                      >
                        Roll back
                      </button>
                      <button
                        :if={rollout.state in [:pending, :running, :paused]}
                        class="btn btn-ghost btn-xs text-error"
                        phx-click="rollout_action"
                        phx-value-id={rollout.id}
                        phx-value-operation="cancel"
                        data-confirm="Cancel this rollout and restore stable desired state?"
                      >
                        Cancel
                      </button>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.ui_panel>

        <.ui_panel>
          <:header>
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div class="text-sm font-semibold">Fleet matrix</div>
              <div class="text-xs text-base-content/60">{length(@rows)} row(s)</div>
            </div>
          </:header>

          <%= if @rows == [] do %>
            <div class="rounded-xl border border-dashed border-base-200 bg-base-100 p-6 text-center">
              <div class="text-sm font-semibold text-base-content">
                No matching add-on deployments
              </div>
              <p class="mt-1 text-xs text-base-content/60">Adjust the filters above.</p>
            </div>
          <% else %>
            <div id="addon-fleet-table" class="overflow-x-auto">
              <table class="table table-sm table-pin-rows">
                <thead>
                  <tr class="text-xs uppercase tracking-wide text-base-content/60">
                    <th class="w-8"></th>
                    <th>Agent</th>
                    <th>Add-on</th>
                    <th>Version</th>
                    <th>Status</th>
                    <th>Runtime</th>
                    <th>Last seen</th>
                    <th>Health</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for row <- @rows do %>
                    <% expanded? = MapSet.member?(@expanded_rows, row_key(row)) %>
                    <tr
                      data-role="fleet-row"
                      class={["hover:bg-base-200/30", row.attention? && "bg-error/5"]}
                    >
                      <td class="align-top">
                        <button
                          type="button"
                          class="btn btn-ghost btn-xs btn-square"
                          phx-click="toggle_details"
                          phx-value-row={row_key(row)}
                          aria-expanded={to_string(expanded?)}
                          aria-label={"Toggle details for #{row.addon_id} on #{row.agent_label}"}
                        >
                          <.icon
                            name={if expanded?, do: "hero-chevron-down", else: "hero-chevron-right"}
                            class="size-4"
                          />
                        </button>
                      </td>
                      <td class="max-w-[16rem] align-top">
                        <div class="truncate font-medium" title={row.agent_label}>
                          {row.agent_label}
                        </div>
                      </td>
                      <td class="align-top">
                        <div class="font-medium">{row.addon_name}</div>
                        <div class="text-xs font-mono text-base-content/60">{row.addon_id}</div>
                        <span :if={row.collector?} class="badge badge-ghost badge-xs">collector</span>
                      </td>
                      <td class="align-top">
                        <.version_cell row={row} />
                      </td>
                      <td class="align-top">
                        <div class="flex flex-col items-start gap-1">
                          <span class={["badge badge-sm", package_status_badge(row.package_status)]}>
                            {package_status_label(row.package_status)}
                          </span>
                          <span
                            data-role={"assignment-#{row.management_mode}"}
                            class={["badge badge-sm", assigned_badge(row)]}
                          >
                            {assigned_label(row)}
                          </span>
                        </div>
                      </td>
                      <td class="align-top">
                        <span class={["badge badge-sm", running_badge(row)]}>
                          {running_label(row)}
                        </span>
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
                      <td class="align-top text-xs text-base-content/70">
                        <div>{format_time(row.reported_at)}</div>
                        <div :if={row.collector? and row.last_scan_at} class="text-base-content/50">
                          scan {format_time(row.last_scan_at)}
                        </div>
                      </td>
                      <td class="align-top">
                        <div class="flex max-w-[14rem] flex-wrap gap-1">
                          <span class={[
                            "badge badge-xs h-auto whitespace-normal py-0.5 text-left leading-tight",
                            category_badge(row.category)
                          ]}>
                            {category_label(row.category)}
                          </span>
                          <span class="basis-full text-xs text-base-content/50">
                            {reason_label(row.reason_code)}
                            <span :if={row.evidence_age_seconds}>
                              · evidence {format_age(row.evidence_age_seconds)} old
                            </span>
                          </span>
                        </div>
                      </td>
                    </tr>
                    <tr :if={expanded?} class="bg-base-200/20">
                      <td></td>
                      <td colspan="7" class="py-3">
                        <.row_details row={row} />
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </.ui_panel>

        <.ui_panel :if={@catalog_only != []}>
          <:header>
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div>
                <div class="text-sm font-semibold">Catalog inventory</div>
                <p class="text-xs text-base-content/60">
                  Imported add-ons not assigned to and not reported by any agent.
                </p>
              </div>
              <.ui_button variant="ghost" size="sm" navigate="/settings/agents/addons">
                Open catalog
              </.ui_button>
            </div>
          </:header>

          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr class="text-xs uppercase tracking-wide text-base-content/60">
                  <th>Add-on</th>
                  <th>Latest version</th>
                  <th>Status</th>
                  <th>Verification</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for entry <- @catalog_only do %>
                  <tr data-role="catalog-only-row" class="hover:bg-base-200/30">
                    <td>
                      <div class="font-medium">{entry.addon_name}</div>
                      <div class="text-xs font-mono text-base-content/60">{entry.addon_id}</div>
                    </td>
                    <td class="text-xs font-mono">
                      {entry.version || "—"}
                      <span :if={entry.versions > 1} class="text-base-content/50">
                        (+{entry.versions - 1} older)
                      </span>
                    </td>
                    <td>
                      <span class={["badge badge-sm", package_status_badge(entry.package_status)]}>
                        {package_status_label(entry.package_status)}
                      </span>
                    </td>
                    <td>
                      <span class={["badge badge-xs", verification_badge(entry.verification_status)]}>
                        {entry.verification_status || "unverified"}
                      </span>
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
          <span class="badge badge-success badge-soft badge-sm">up to date</span>
          <div class="mt-1 text-xs font-mono text-base-content/70">{version}</div>
        </div>
      <% {:up_to_date, version, false} -> %>
        <div data-role="version-in-sync">
          <div class="text-xs font-mono">{version}</div>
          <div class="text-xs text-base-content/60">in sync with assignment</div>
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
          <div class="text-base-content/60">required runtime</div>
        </div>
      <% {:running_unassigned, version} -> %>
        <div data-role="version-running-unassigned" class="text-xs">
          running <span :if={version} class="font-mono">{version}</span> (unassigned)
        </div>
      <% {:not_reported, version} -> %>
        <div data-role="version-not-reported" class="text-xs text-base-content/60">
          <span :if={version}>assigned <span class="font-mono">{version}</span> ·</span> not reported
        </div>
      <% _ -> %>
        <span class="text-xs text-base-content/40">—</span>
    <% end %>
    """
  end

  attr :row, :map, required: true

  defp row_details(assigns) do
    ~H"""
    <div class="grid gap-3 text-xs md:grid-cols-2">
      <div class="space-y-2">
        <div>
          <div class="text-base-content/50 uppercase tracking-wide">Agent UID</div>
          <div class="font-mono break-all">{@row.agent_uid || "—"}</div>
        </div>
        <div>
          <div class="text-base-content/50 uppercase tracking-wide">Assigned package</div>
          <div :if={@row.content_hash} class="font-mono break-all">{@row.content_hash}</div>
          <div :if={is_nil(@row.content_hash)} class="text-base-content/50">no package</div>
          <span class={["badge badge-xs mt-1", verification_badge(@row.verification_status)]}>
            {@row.verification_status || "unverified"}
          </span>
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
          <div class="text-base-content/50 uppercase tracking-wide">
            Other assignments on this agent
          </div>
          <ul class="mt-1 space-y-1">
            <li :for={stale <- @row.stale_assignments} class="font-mono">
              {stale.version || "unknown version"}
              <span class="font-sans text-base-content/50">
                ({if stale.enabled, do: "enabled", else: "disabled"}{if stale.source,
                  do: ", #{stale.source}"})
              </span>
            </li>
          </ul>
        </div>
      </div>
      <div class="space-y-2">
        <div>
          <div class="text-base-content/50 uppercase tracking-wide">Runtime diagnostics</div>
          <div
            :if={@row.degradation_reason}
            class={[
              "whitespace-pre-wrap break-words",
              diagnostic_text_class(@row.degradation_reason)
            ]}
          >
            {@row.degradation_reason}
          </div>
          <div :if={is_nil(@row.degradation_reason)} class="text-base-content/50">
            no diagnostics reported
          </div>
        </div>
        <div :if={@row.running_version}>
          <div class="text-base-content/50 uppercase tracking-wide">Reported version</div>
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
    <div class="rounded-xl border border-base-200 bg-base-100 p-4">
      <div class="text-xs uppercase tracking-wide text-base-content/60">{@label}</div>
      <div class={["mt-1 text-2xl font-semibold", stat_tone_class(@tone, @value)]}>{@value}</div>
    </div>
    """
  end

  defp stat_tone_class("error", value) when value > 0, do: "text-error"
  defp stat_tone_class("warning", value) when value > 0, do: "text-warning"
  defp stat_tone_class("success", value) when value > 0, do: "text-success"
  defp stat_tone_class("info", value) when value > 0, do: "text-info"
  defp stat_tone_class(_tone, _value), do: "text-base-content"

  defp verification_badge("verified"), do: "badge-success badge-soft"
  defp verification_badge("seeded"), do: "badge-warning badge-soft"
  defp verification_badge(nil), do: "badge-ghost"
  defp verification_badge(_other), do: "badge-error badge-soft"

  defp package_status_badge(:approved), do: "badge-success"
  defp package_status_badge(:staged), do: "badge-warning"
  defp package_status_badge(nil), do: "badge-ghost"
  defp package_status_badge(_other), do: "badge-error"

  defp package_status_label(nil), do: "no package"
  defp package_status_label(status), do: to_string(status)

  defp assigned_badge(%{assigned?: true, enabled?: true}), do: "badge-success badge-soft"
  defp assigned_badge(%{assigned?: true}), do: "badge-ghost"
  defp assigned_badge(%{management_mode: :required}), do: "badge-info badge-soft"
  defp assigned_badge(_row), do: "badge-ghost badge-outline"

  defp assigned_label(%{assigned?: true, enabled?: true}), do: "enabled"
  defp assigned_label(%{assigned?: true}), do: "disabled"
  defp assigned_label(%{management_mode: :required}), do: "required"
  defp assigned_label(_row), do: "unassigned"

  defp running_badge(%{category: :healthy}), do: "badge-success"
  defp running_badge(%{category: :expected_inactive}), do: "badge-info badge-soft"
  defp running_badge(%{category: :updating}), do: "badge-info"
  defp running_badge(%{category: :unavailable}), do: "badge-warning badge-soft"
  defp running_badge(%{active?: true}), do: "badge-success"
  defp running_badge(%{running_state: nil}), do: "badge-ghost"
  defp running_badge(_row), do: "badge-error"

  defp running_label(%{running_state: nil}), do: "not reported"
  defp running_label(%{running_state: state}), do: state

  defp category_badge(:healthy), do: "badge-success"
  defp category_badge(:updating), do: "badge-info"
  defp category_badge(:action_required), do: "badge-error"
  defp category_badge(:unavailable), do: "badge-warning"
  defp category_badge(:expected_inactive), do: "badge-ghost"
  defp category_badge(:observed_only), do: "badge-ghost badge-outline"
  defp category_badge(_), do: "badge-ghost"

  defp category_label(category), do: category |> to_string() |> String.replace("_", " ")

  defp reason_label(reason), do: Map.get(@attention_labels, reason, reason |> to_string() |> String.replace("_", " "))

  defp rollout_progress(targets) do
    total = length(targets)

    complete =
      Enum.count(targets, &(&1.state in [:succeeded, :promoted, :rolled_back, :excluded]))

    held = Enum.count(targets, &(&1.state == :rolled_back))
    suffix = if held > 0, do: " · #{held} held on prior version", else: ""
    "#{complete}/#{total} complete#{suffix}"
  end

  defp rollout_state_badge(:completed), do: "badge-success"
  defp rollout_state_badge(state) when state in [:running, :pending], do: "badge-info"
  defp rollout_state_badge(:paused), do: "badge-warning"
  defp rollout_state_badge(state) when state in [:failed, :rolled_back], do: "badge-error"
  defp rollout_state_badge(_), do: "badge-ghost"

  defp diagnostic_link_class(reason) do
    if AddonRuntimePolicy.resource_limit_warning?(reason), do: "text-warning", else: "text-error"
  end

  defp diagnostic_text_class(reason) do
    if AddonRuntimePolicy.resource_limit_warning?(reason), do: "text-warning", else: "text-error"
  end

  defp format_time(nil), do: "—"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp format_time(_other), do: "—"

  defp format_age(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_age(seconds) when seconds < 3_600, do: "#{div(seconds, 60)}m"
  defp format_age(seconds), do: "#{div(seconds, 3_600)}h"
end
