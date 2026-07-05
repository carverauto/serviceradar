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
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  @base_path "/settings/agents/addons/fleet"

  @attention_labels %{
    staged_not_approved: "staged / not approved",
    assigned_not_running: "assigned, not running",
    stopped_or_inactive: "stopped / inactive",
    version_drift: "version drift",
    observed_unassigned: "running, unassigned"
  }

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "plugins.view") do
      {:ok, load_fleet(socket, default_filters())}
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
    |> assign(:expanded_rows, MapSet.new())
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
    %{"agent_uid" => "", "addon_id" => "", "attention_only" => "false"}
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

        <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <.stat_card label="Deployments" value={@summary.total} />
          <.stat_card label="Needs attention" value={@summary.attention} tone="error" />
          <.stat_card label="Running" value={@summary.running} tone="success" />
          <.stat_card label="Staged packages" value={@summary.staged} tone="warning" />
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
                    <th>Attention</th>
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
                          <span class={["badge badge-sm", assigned_badge(row)]}>
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
                          class="mt-1 block text-left text-xs text-error underline decoration-dotted"
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
                          <%= for flag <- row.attention do %>
                            <span class={[
                              "badge badge-xs h-auto whitespace-normal py-0.5 text-left leading-tight",
                              attention_badge(flag)
                            ]}>
                              {attention_label(flag)}
                            </span>
                          <% end %>
                          <span :if={row.attention == []} class="text-xs text-base-content/40">
                            ok
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
          <div :if={@row.degradation_reason} class="whitespace-pre-wrap break-words text-error">
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
  defp assigned_badge(_row), do: "badge-ghost badge-outline"

  defp assigned_label(%{assigned?: true, enabled?: true}), do: "enabled"
  defp assigned_label(%{assigned?: true}), do: "disabled"
  defp assigned_label(_row), do: "unassigned"

  defp running_badge(%{active?: true}), do: "badge-success"
  defp running_badge(%{running_state: nil}), do: "badge-ghost"
  defp running_badge(_row), do: "badge-error"

  defp running_label(%{running_state: nil}), do: "not reported"
  defp running_label(%{running_state: state}), do: state

  defp attention_badge(:staged_not_approved), do: "badge-warning"
  defp attention_badge(:observed_unassigned), do: "badge-info"
  defp attention_badge(_flag), do: "badge-error"

  defp attention_label(flag), do: Map.get(@attention_labels, flag, to_string(flag))

  defp format_time(nil), do: "—"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp format_time(_other), do: "—"
end
