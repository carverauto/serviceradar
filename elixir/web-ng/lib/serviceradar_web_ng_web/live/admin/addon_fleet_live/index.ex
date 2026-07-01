defmodule ServiceRadarWebNGWeb.Admin.AddonFleetLive.Index do
  @moduledoc """
  Fleet-wide reporting view for native agent add-ons (issue 3425).

  Where Admin.AddonPackageLive.Index is catalog/assignment-centric, this page is
  operations-centric: a matrix of agent x add-on x assigned version / content hash
  / approval / running state, joining desired state (packages + assignments)
  against observed state (statuses). It exists to close the visibility gap that
  let a fleet of broken/disabled/undelivered add-ons go unnoticed.

  Read-only; gated by `plugins.view` (same permission as the add-on catalog page).
  All data comes from the ServiceRadarWebNG.Plugins.AddonFleet context, which reads
  the ServiceRadar.Plugins.Addon* and ServiceRadar.Inventory.EndpointInventoryScan
  Ash resources with the current scope.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias ServiceRadarWebNG.Plugins.AddonFleet
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  @base_path "/settings/agents/addons/fleet"

  @attention_labels %{
    staged_not_approved: "staged / not approved",
    assigned_not_running: "assigned, not running",
    stopped_or_inactive: "stopped / inactive",
    version_drift: "version drift",
    observed_unassigned: "observed, unassigned"
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

  defp load_fleet(socket, filters) do
    rows = AddonFleet.rows(scope: socket.assigns.current_scope)

    socket
    |> assign(:page_title, "Add-on Fleet")
    |> assign(:current_path, @base_path)
    |> assign(:all_rows, rows)
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.settings_chrome
        settings_ui={@settings_ui}
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
      >
        <:legacy>
          <.settings_nav current_path={@current_path} current_scope={@current_scope} />
          <.edge_nav current_path={@current_path} class="mt-2" current_scope={@current_scope} />
        </:legacy>

        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-base-content">Add-on Fleet</h1>
            <p class="text-sm text-base-content/60">
              Every agent's native add-on assignment vs. what it is actually running —
              version, published content hash, approval, and runtime state in one matrix.
            </p>
          </div>
          <.ui_button variant="ghost" size="sm" phx-click="refresh">
            <.icon name="hero-arrow-path" class="size-4" /> Refresh
          </.ui_button>
        </div>

        <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <.stat_card label="Rows" value={@summary.total} />
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
            <div class="overflow-x-auto">
              <table class="table table-sm table-pin-rows">
                <thead>
                  <tr class="text-xs uppercase tracking-wide text-base-content/60">
                    <th>Agent</th>
                    <th>Add-on</th>
                    <th>Assigned version</th>
                    <th>Content hash</th>
                    <th>Approved</th>
                    <th>Assigned</th>
                    <th>Running state</th>
                    <th>Reported</th>
                    <th>Last scan</th>
                    <th>Attention</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for row <- @rows do %>
                    <tr class={["hover:bg-base-200/30", row.attention? && "bg-error/5"]}>
                      <td class="max-w-[18rem]">
                        <div class="truncate font-medium">{row.agent_label}</div>
                        <div
                          :if={row.agent_uid}
                          class="truncate text-xs font-mono text-base-content/60"
                        >
                          {row.agent_uid}
                        </div>
                      </td>
                      <td>
                        <div class="font-medium">{row.addon_name}</div>
                        <div class="text-xs font-mono text-base-content/60">{row.addon_id}</div>
                        <span :if={row.collector?} class="badge badge-ghost badge-xs">collector</span>
                      </td>
                      <td class="text-xs font-mono">{row.assigned_version || "—"}</td>
                      <td class="max-w-[14rem] text-xs">
                        <span class="block truncate font-mono" title={row.content_hash}>
                          {short_hash(row.content_hash)}
                        </span>
                        <span class={[
                          "badge badge-xs mt-1",
                          verification_badge(row.verification_status)
                        ]}>
                          {row.verification_status || "unverified"}
                        </span>
                      </td>
                      <td>
                        <span class={["badge badge-sm", package_status_badge(row.package_status)]}>
                          {package_status_label(row.package_status)}
                        </span>
                      </td>
                      <td>
                        <span class={["badge badge-sm", assigned_badge(row)]}>
                          {assigned_label(row)}
                        </span>
                      </td>
                      <td>
                        <span class={["badge badge-sm", running_badge(row)]}>
                          {running_label(row)}
                        </span>
                        <div
                          :if={row.running_version && row.running_version != row.assigned_version}
                          class="mt-1 text-xs text-warning"
                          title="Running version differs from the assigned package version"
                        >
                          drift: {row.running_version}
                        </div>
                        <div
                          :if={row.degradation_reason}
                          class="mt-1 max-w-[16rem] truncate text-xs text-error"
                          title={row.degradation_reason}
                        >
                          {row.degradation_reason}
                        </div>
                      </td>
                      <td class="text-xs text-base-content/70">{format_time(row.reported_at)}</td>
                      <td class="text-xs text-base-content/70">
                        {if row.collector?, do: format_time(row.last_scan_at), else: "—"}
                      </td>
                      <td>
                        <div class="flex flex-wrap gap-1">
                          <%= for flag <- row.attention do %>
                            <span class={["badge badge-xs", attention_badge(flag)]}>
                              {attention_label(flag)}
                            </span>
                          <% end %>
                          <span :if={row.attention == []} class="text-xs text-base-content/40">
                            ok
                          </span>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </.ui_panel>
      </Shell.settings_chrome>
    </Layouts.app>
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

  defp short_hash(nil), do: "—"

  defp short_hash(hash) when is_binary(hash) do
    case String.split(hash, ":", parts: 2) do
      [algo, digest] -> "#{algo}:#{String.slice(digest, 0, 12)}…"
      _ -> String.slice(hash, 0, 16) <> "…"
    end
  end

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

  defp assigned_badge(%{assigned?: true, enabled?: true}), do: "badge-success"
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
