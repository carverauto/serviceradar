defmodule ServiceRadarWebNGWeb.Security.ThreatIntelLive.Index do
  @moduledoc """
  Operator investigation for IP/CIDR threat intelligence.

  Five views, each one bounded keyset page with URL-backed filters:

    * `matches` - current matched endpoints (live cache rows), with detail
    * `indicator_matches` - endpoint-to-indicator memberships, via SRQL
      `in:threat_intel_matches`
    * `inventory` - imported indicators; inventory, not local sightings
    * `objects` - imported provider objects (OTX pulses)
    * `retrohunt` - historical retrohunt runs and their findings

  Filters and the selected endpoint are in the shareable URL. Page position is
  a cursor stack in assigns, as elsewhere in web-ng.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Observability.ThreatIntelEvidence
  alias ServiceRadar.Observability.ThreatIntelInvestigation
  alias ServiceRadarWebNGWeb.Observability.ThreatIntelLinks

  require Logger

  @permission "observability.netflow.view"
  @page_size 50
  @views ~w(matches indicator_matches inventory objects retrohunt)
  @filter_keys ~w(source ip min_severity sort stale indicator run_id)
  @input_errors %{
    invalid_ip: "The IP filter is not a valid address.",
    invalid_cidr: "The indicator filter is not a valid IP or CIDR.",
    invalid_severity: "Min severity must be a whole number.",
    invalid_run_id: "The retrohunt run filter is not valid.",
    invalid_cursor: "The page position is no longer valid. Return to the first page."
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Threat Intel")
     |> assign(:view, "matches")
     |> assign(:filters, %{})
     |> assign(:rows, [])
     |> assign(:runs, [])
     |> assign(:runs_error, nil)
     |> assign(:next_cursor, nil)
     |> assign(:cursor, nil)
     |> assign(:cursor_stack, [])
     |> assign(:load_error, nil)
     |> assign(:indicators, [])
     |> assign(:selected_ip, nil)
     |> assign(:selected_match, nil)
     |> assign(:indicator_error, nil)
     |> assign(:indicator_state, :idle)
     |> assign(:loading, true)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope = socket.assigns.current_scope

    cond do
      not RBAC.can?(scope, @permission) ->
        {:noreply,
         socket
         |> put_flash(:error, "Not authorized to view threat intelligence matches")
         |> push_navigate(to: ~p"/dashboard")}

      not connected?(socket) ->
        {:noreply, assign(socket, :loading, true)}

      true ->
        view = normalize_view(params["view"])
        filters = params |> Map.take(@filter_keys) |> reject_blank()

        {:noreply,
         socket
         |> keep_page_if(view == socket.assigns.view and filters == socket.assigns.filters)
         |> assign(:view, view)
         |> assign(:filters, filters)
         |> assign(:selected_ip, blank_to_nil(params["selected"]) || blank_to_nil(params["ip"]))
         |> load_page()}
    end
  end

  defp keep_page_if(socket, true), do: socket

  defp keep_page_if(socket, false) do
    socket
    |> assign(:cursor, nil)
    |> assign(:cursor_stack, [])
  end

  @impl true
  def handle_event(event, params, socket) do
    if RBAC.can?(socket.assigns.current_scope, @permission) do
      {:noreply, handle_authorized(event, params, socket)}
    else
      {:noreply, put_flash(socket, :error, "Not authorized")}
    end
  end

  defp handle_authorized("select_ip", %{"ip" => ip}, socket) do
    push_patch(socket, to: view_path("matches", Map.put(socket.assigns.filters, "selected", ip)))
  end

  defp handle_authorized("filter", %{"filters" => filters}, socket) when is_map(filters) do
    filters =
      socket.assigns.filters
      |> Map.merge(Map.take(filters, @filter_keys))
      |> reject_blank()

    push_patch(socket, to: view_path(socket.assigns.view, filters))
  end

  defp handle_authorized("next_page", _params, %{assigns: %{next_cursor: cursor}} = socket) when is_binary(cursor) do
    socket
    |> assign(:cursor_stack, [socket.assigns.cursor | socket.assigns.cursor_stack])
    |> assign(:cursor, cursor)
    |> load_page()
  end

  defp handle_authorized("prev_page", _params, %{assigns: %{cursor_stack: [previous | rest]}} = socket) do
    socket
    |> assign(:cursor_stack, rest)
    |> assign(:cursor, previous)
    |> load_page()
  end

  defp handle_authorized("first_page", _params, socket) do
    socket
    |> assign(:cursor_stack, [])
    |> assign(:cursor, nil)
    |> load_page()
  end

  defp handle_authorized("retry", _params, socket), do: load_page(socket)
  defp handle_authorized(_event, _params, socket), do: socket

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path="/security/threat-intel"
      page_title={@page_title}
    >
      <div class="mx-auto w-full max-w-7xl space-y-6 p-4 sm:p-6">
        <div class="flex flex-wrap items-end justify-between gap-3">
          <div class="min-w-0">
            <p class="text-sm font-medium text-sr-brand">Security</p>
            <h1 class="text-2xl font-semibold text-sr-ink">Threat Intel</h1>
            <p class="mt-1 max-w-2xl text-sm text-sr-muted">{view_description(@view)}</p>
          </div>
          <div class="flex flex-wrap gap-2">
            <.ui_button navigate={~p"/security"} variant="ghost" size="sm">
              Security overview
            </.ui_button>
            <.ui_button href={ThreatIntelLinks.settings_path()} variant="outline" size="sm">
              Manage feeds
            </.ui_button>
          </div>
        </div>

        <nav
          id="threat-intel-views"
          class="flex flex-wrap gap-1 border-b border-sr-line pb-2"
          aria-label="Threat intel views"
        >
          <.ui_button
            :for={{view, label} <- view_tabs()}
            id={"threat-intel-view-#{view}"}
            patch={view_path(view, carry_filters(view, @filters))}
            variant="ghost"
            size="sm"
            active={@view == view}
            aria-current={if @view == view, do: "page"}
          >
            {label}
          </.ui_button>
        </nav>

        <.filter_bar view={@view} filters={@filters} />

        <.ui_alert
          :if={@load_error}
          variant="error"
          id="threat-intel-matches-error"
          data-testid="threat-intel-error"
        >
          <div class="flex flex-wrap items-center justify-between gap-3">
            <span>{@load_error}</span>
            <.ui_button
              type="button"
              phx-click="retry"
              variant="outline"
              size="sm"
              id="threat-intel-matches-retry"
            >
              Retry
            </.ui_button>
          </div>
        </.ui_alert>

        <div
          :if={@view == "matches"}
          class="grid grid-cols-1 gap-6 lg:grid-cols-[minmax(0,1.1fr)_minmax(0,0.9fr)]"
        >
          <.ui_panel id="threat-intel-matches">
            <:header>
              <div class="min-w-0">
                <h2 class="text-base font-semibold text-sr-ink">Current matches</h2>
                <p class="text-xs text-sr-muted">Matched endpoints on this page: {length(@rows)}</p>
              </div>
            </:header>
            <.list_state
              loading={@loading}
              rows={@rows}
              error={@load_error}
              empty="No current NetFlow IOC matches."
            />
            <div :if={@rows != []} class="overflow-x-auto">
              <table class="w-full min-w-[36rem] text-left text-sm">
                <thead class="border-b border-sr-line text-xs uppercase tracking-wide text-sr-muted">
                  <tr>
                    <th class="px-4 py-2 font-medium">Observed IP</th>
                    <th class="px-4 py-2 font-medium">Indicator matches</th>
                    <th class="px-4 py-2 font-medium">Max sev</th>
                    <th class="px-4 py-2 font-medium">Sources</th>
                    <th class="px-4 py-2 font-medium">Evaluated</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={match <- @rows}
                    class={[
                      "cursor-pointer border-b border-sr-line last:border-b-0 hover:bg-sr-subtle",
                      @selected_ip == match.observed_ip && "bg-sr-subtle"
                    ]}
                    phx-click="select_ip"
                    phx-value-ip={match.observed_ip}
                    data-testid={"threat-intel-row-#{match.observed_ip}"}
                  >
                    <td class="px-4 py-3 font-mono text-sr-ink">
                      <span class="break-all">{match.observed_ip}</span>
                      <span
                        :if={match.stale}
                        class="ml-2 inline-flex rounded-sr-control border border-amber-500/40 px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-amber-800 dark:text-amber-200"
                      >
                        Stale
                      </span>
                    </td>
                    <td class="px-4 py-3 text-sr-ink">{match.indicator_match_count}</td>
                    <td class="px-4 py-3 text-sr-ink">{match.max_severity || "—"}</td>
                    <td class="px-4 py-3 text-xs text-sr-muted">{Enum.join(match.sources, ", ")}</td>
                    <td class="px-4 py-3 text-sr-muted">
                      <.user_time
                        :if={match.evaluated_at}
                        id={"threat-intel-evaluated-#{dom_id(match.observed_ip)}"}
                        value={match.evaluated_at}
                        timezone={timezone(@current_scope)}
                        style={:compact}
                      />
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
            <.pager next_cursor={@next_cursor} cursor_stack={@cursor_stack} />
          </.ui_panel>

          <.match_detail
            selected_ip={@selected_ip}
            selected_match={@selected_match}
            indicators={@indicators}
            indicator_error={@indicator_error}
            indicator_state={@indicator_state}
          />
        </div>

        <.ui_panel :if={@view == "indicator_matches"} id="threat-intel-indicator-matches">
          <:header>
            <div class="min-w-0">
              <h2 class="text-base font-semibold text-sr-ink">Indicator matches</h2>
              <p class="text-xs text-sr-muted">
                One row per live endpoint-to-indicator membership. These are not flow counts.
              </p>
            </div>
          </:header>
          <.list_state
            loading={@loading}
            rows={@rows}
            error={@load_error}
            empty="No current indicator matches."
          />
          <div :if={@rows != []} class="overflow-x-auto">
            <table class="w-full min-w-[44rem] text-left text-sm">
              <thead class="border-b border-sr-line text-xs uppercase tracking-wide text-sr-muted">
                <tr>
                  <th class="px-4 py-2 font-medium">Observed IP</th>
                  <th class="px-4 py-2 font-medium">Indicator</th>
                  <th class="px-4 py-2 font-medium">Source</th>
                  <th class="px-4 py-2 font-medium">Severity</th>
                  <th class="px-4 py-2 font-medium">Evaluated</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={{row, idx} <- Enum.with_index(@rows)}
                  class="border-b border-sr-line last:border-b-0"
                  data-testid="threat-intel-membership"
                >
                  <td class="px-4 py-3 font-mono">
                    <.link
                      patch={view_path("matches", %{"selected" => row["observed_ip"]})}
                      class="break-all text-sr-ink hover:underline"
                    >
                      {row["observed_ip"]}
                    </.link>
                  </td>
                  <td class="px-4 py-3">
                    <div class="break-all font-mono text-sr-ink">{row["indicator"]}</div>
                    <div :if={row["label"]} class="break-words text-xs text-sr-muted">
                      {row["label"]}
                    </div>
                  </td>
                  <td class="px-4 py-3 text-sr-muted">{row["source"]}</td>
                  <td class="px-4 py-3 text-sr-ink">{row["severity"] || "—"}</td>
                  <td class="px-4 py-3 text-sr-muted">
                    <.user_time
                      :if={row["evaluated_at"]}
                      id={"threat-intel-membership-#{idx}-evaluated"}
                      value={row["evaluated_at"]}
                      timezone={timezone(@current_scope)}
                      style={:compact}
                    />
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <.pager next_cursor={@next_cursor} cursor_stack={@cursor_stack} />
        </.ui_panel>

        <.ui_panel :if={@view == "inventory"} id="threat-intel-inventory">
          <:header>
            <div class="min-w-0">
              <h2 class="text-base font-semibold text-sr-ink">Imported indicators</h2>
              <p class="text-xs text-sr-muted">
                Inventory imported from feeds. An indicator here has not necessarily been seen on your network.
              </p>
            </div>
          </:header>
          <.list_state
            loading={@loading}
            rows={@rows}
            error={@load_error}
            empty="No imported indicators match these filters."
          />
          <div :if={@rows != []} class="overflow-x-auto">
            <table class="w-full min-w-[44rem] text-left text-sm">
              <thead class="border-b border-sr-line text-xs uppercase tracking-wide text-sr-muted">
                <tr>
                  <th class="px-4 py-2 font-medium">Indicator</th>
                  <th class="px-4 py-2 font-medium">Source</th>
                  <th class="px-4 py-2 font-medium">Severity / confidence</th>
                  <th class="px-4 py-2 font-medium">Last seen in feed</th>
                  <th class="px-4 py-2 font-medium">Expires</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={row <- @rows}
                  class="border-b border-sr-line last:border-b-0"
                  data-testid="threat-intel-inventory-row"
                >
                  <td class="px-4 py-3">
                    <div class="break-all font-mono text-sr-ink">{row.indicator}</div>
                    <div :if={row.label} class="break-words text-xs text-sr-muted">{row.label}</div>
                  </td>
                  <td class="px-4 py-3 text-sr-muted">{row.source}</td>
                  <td class="px-4 py-3 text-sr-ink">
                    {row.severity || "—"} / {row.confidence || "—"}
                  </td>
                  <td class="px-4 py-3 text-sr-muted">
                    <.user_time
                      id={"threat-intel-inventory-#{row.indicator_id}-last-seen"}
                      value={row.indicator_last_seen_at}
                      timezone={timezone(@current_scope)}
                      style={:compact}
                    />
                  </td>
                  <td class="px-4 py-3 text-sr-muted">
                    <span :if={is_nil(row.indicator_expires_at)}>Never</span>
                    <.user_time
                      :if={row.indicator_expires_at}
                      id={"threat-intel-inventory-#{row.indicator_id}-expires"}
                      value={row.indicator_expires_at}
                      timezone={timezone(@current_scope)}
                      style={:compact}
                    />
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <.pager next_cursor={@next_cursor} cursor_stack={@cursor_stack} />
        </.ui_panel>

        <.ui_panel :if={@view == "objects"} id="threat-intel-objects">
          <:header>
            <div class="min-w-0">
              <h2 class="text-base font-semibold text-sr-ink">Provider objects</h2>
              <p class="text-xs text-sr-muted">
                Imported provider records, such as OTX pulses. Inventory, not local sightings.
              </p>
            </div>
          </:header>
          <.list_state
            loading={@loading}
            rows={@rows}
            error={@load_error}
            empty="No imported provider objects match these filters."
          />
          <div :if={@rows != []} class="overflow-x-auto">
            <table class="w-full min-w-[44rem] text-left text-sm">
              <thead class="border-b border-sr-line text-xs uppercase tracking-wide text-sr-muted">
                <tr>
                  <th class="px-4 py-2 font-medium">Object</th>
                  <th class="px-4 py-2 font-medium">Type</th>
                  <th class="px-4 py-2 font-medium">Indicator</th>
                  <th class="px-4 py-2 font-medium">Updated</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={row <- @rows}
                  class="border-b border-sr-line last:border-b-0"
                  data-testid="threat-intel-object-row"
                >
                  <td class="px-4 py-3">
                    <div class="break-words text-sr-ink">{row.label || row.object_id}</div>
                    <div class="break-all font-mono text-xs text-sr-muted">
                      {row.source} · {row.object_id}
                    </div>
                  </td>
                  <td class="px-4 py-3 text-sr-muted">{row.object_type}</td>
                  <td class="px-4 py-3 font-mono">
                    <.link
                      :if={row.indicator}
                      patch={view_path("inventory", %{"indicator" => row.indicator})}
                      class="break-all text-sr-ink hover:underline"
                    >
                      {row.indicator}
                    </.link>
                  </td>
                  <td class="px-4 py-3 text-sr-muted">
                    <.user_time
                      id={"threat-intel-object-#{row.id}-updated"}
                      value={row.updated_at}
                      timezone={timezone(@current_scope)}
                      style={:compact}
                    />
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <.pager next_cursor={@next_cursor} cursor_stack={@cursor_stack} />
        </.ui_panel>

        <div :if={@view == "retrohunt"} class="space-y-6">
          <.ui_panel id="threat-intel-retrohunt-runs">
            <:header>
              <div class="min-w-0">
                <h2 class="text-base font-semibold text-sr-ink">Recent retrohunt runs</h2>
                <p class="text-xs text-sr-muted">
                  Hunts of imported indicators against retained flows. Start or schedule them in Manage feeds.
                </p>
              </div>
            </:header>
            <p
              :if={@runs_error}
              class="p-4 text-sm text-red-700 dark:text-red-300"
              data-testid="threat-intel-runs-error"
            >
              {@runs_error}
            </p>
            <p
              :if={@runs == [] and not @loading and is_nil(@runs_error)}
              class="p-4 text-sm text-sr-muted"
              data-testid="threat-intel-runs-empty"
            >
              No retrohunt has run yet.
            </p>
            <ul :if={@runs != []} class="divide-y divide-sr-line">
              <li
                :for={run <- @runs}
                class="flex flex-wrap items-center justify-between gap-3 px-4 py-3 text-sm"
                data-testid="threat-intel-run"
              >
                <div class="min-w-0">
                  <.user_time
                    id={"threat-intel-run-#{run.id}-started"}
                    value={run.started_at}
                    timezone={timezone(@current_scope)}
                    style={:compact}
                    class="text-sr-ink"
                  />
                  <div class="text-xs text-sr-muted">
                    {run.triggered_by} · {run.indicators_evaluated} indicators · {run.findings_count} findings
                  </div>
                </div>
                <div class="flex items-center gap-2">
                  <.ui_badge size="xs" variant={run_badge(run.status)}>{run.status}</.ui_badge>
                  <.ui_button
                    :if={run.findings_count > 0}
                    patch={view_path("retrohunt", %{"run_id" => run.id})}
                    variant="ghost"
                    size="xs"
                  >
                    Findings
                  </.ui_button>
                </div>
              </li>
            </ul>
          </.ui_panel>

          <.ui_panel id="threat-intel-retrohunt-findings">
            <:header>
              <div class="min-w-0">
                <h2 class="text-base font-semibold text-sr-ink">Retrohunt findings</h2>
                <p class="text-xs text-sr-muted">
                  Flow evidence recorded by past runs: when an endpoint was seen, how often, and which indicator contained it.
                </p>
              </div>
            </:header>
            <.list_state
              loading={@loading}
              rows={@rows}
              error={@load_error}
              empty="No retrohunt findings match these filters."
            />
            <div :if={@rows != []} class="overflow-x-auto">
              <table class="w-full min-w-[48rem] text-left text-sm">
                <thead class="border-b border-sr-line text-xs uppercase tracking-wide text-sr-muted">
                  <tr>
                    <th class="px-4 py-2 font-medium">Observed IP</th>
                    <th class="px-4 py-2 font-medium">Indicator</th>
                    <th class="px-4 py-2 font-medium">Direction</th>
                    <th class="px-4 py-2 font-medium">Evidence</th>
                    <th class="px-4 py-2 font-medium">Last seen</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={row <- @rows}
                    class="border-b border-sr-line last:border-b-0"
                    data-testid="threat-intel-finding-row"
                  >
                    <td class="break-all px-4 py-3 font-mono text-sr-ink">{row.observed_ip}</td>
                    <td class="px-4 py-3">
                      <div class="break-all font-mono text-sr-ink">{row.indicator}</div>
                      <div :if={row.label} class="break-words text-xs text-sr-muted">{row.label}</div>
                    </td>
                    <td class="px-4 py-3 text-sr-muted">{row.direction}</td>
                    <td class="px-4 py-3 text-sr-ink">{row.evidence_count} flows</td>
                    <td class="px-4 py-3 text-sr-muted">
                      <.user_time
                        id={"threat-intel-finding-#{row.id}-last-seen"}
                        value={row.last_seen_at}
                        timezone={timezone(@current_scope)}
                        style={:compact}
                      />
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
            <.pager next_cursor={@next_cursor} cursor_stack={@cursor_stack} />
          </.ui_panel>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :view, :string, required: true
  attr :filters, :map, required: true

  defp filter_bar(assigns) do
    ~H"""
    <form
      id="threat-intel-filters"
      phx-submit="filter"
      class="flex flex-wrap items-end gap-3 rounded-sr-surface border border-sr-line bg-sr-surface p-3"
    >
      <.filter_input
        name="source"
        label="Source"
        value={@filters["source"]}
        placeholder="alienvault_otx"
      />
      <.filter_input
        :if={@view in ["matches", "indicator_matches", "retrohunt"]}
        name="ip"
        label="Observed IP"
        value={@filters["ip"]}
        placeholder="192.0.2.10"
      />
      <.filter_input
        :if={@view in ["matches", "indicator_matches"]}
        name="min_severity"
        label="Min severity"
        value={@filters["min_severity"]}
        placeholder="0"
      />
      <.filter_input
        :if={@view in ["indicator_matches", "inventory", "objects", "retrohunt"]}
        name="indicator"
        label="Indicator"
        value={@filters["indicator"]}
        placeholder="198.51.100.0/24"
      />
      <div :if={@view == "matches"} class="min-w-36">
        <label for="threat-intel-filter-sort" class="text-xs font-medium text-sr-muted">Sort</label>
        <select
          id="threat-intel-filter-sort"
          name="filters[sort]"
          class={ui_field_class(size: "sm", class: "w-full")}
        >
          <option value="recent" selected={@filters["sort"] != "severity"}>Recently evaluated</option>
          <option value="severity" selected={@filters["sort"] == "severity"}>Highest severity</option>
        </select>
      </div>
      <label :if={@view == "matches"} class="flex items-center gap-2 pb-2 text-sm text-sr-ink">
        <input type="hidden" name="filters[stale]" value="" />
        <input
          type="checkbox"
          name="filters[stale]"
          value="true"
          checked={@filters["stale"] == "true"}
        /> Include stale
      </label>
      <.ui_button type="submit" variant="outline" size="sm" id="threat-intel-apply-filters">
        Apply
      </.ui_button>
      <.ui_button
        :if={@filters != %{}}
        patch={view_path(@view, %{})}
        variant="ghost"
        size="sm"
        id="threat-intel-clear-filters"
      >
        Clear
      </.ui_button>
    </form>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :placeholder, :string, default: nil

  defp filter_input(assigns) do
    ~H"""
    <div class="min-w-40 flex-1 sm:flex-none">
      <label for={"threat-intel-filter-#{@name}"} class="text-xs font-medium text-sr-muted">
        {@label}
      </label>
      <input
        id={"threat-intel-filter-#{@name}"}
        type="text"
        name={"filters[#{@name}]"}
        value={@value}
        placeholder={@placeholder}
        autocomplete="off"
        class={ui_field_class(size: "sm", mono: true, class: "w-full")}
      />
    </div>
    """
  end

  attr :loading, :boolean, required: true
  attr :rows, :list, required: true
  attr :error, :any, default: nil
  attr :empty, :string, required: true

  defp list_state(assigns) do
    ~H"""
    <div :if={@loading and @rows == []} class="p-4 text-sm text-sr-muted">Loading…</div>
    <div
      :if={not @loading and @rows == [] and is_nil(@error)}
      class="p-4 text-sm text-sr-muted"
      data-testid="threat-intel-empty"
    >
      {@empty}
    </div>
    """
  end

  attr :next_cursor, :any, default: nil
  attr :cursor_stack, :list, default: []

  defp pager(assigns) do
    ~H"""
    <div
      :if={@next_cursor || @cursor_stack != []}
      class="flex items-center justify-end gap-2 border-t border-sr-line px-4 py-3"
      data-testid="threat-intel-pager"
    >
      <.ui_button
        :if={@cursor_stack != []}
        type="button"
        phx-click="first_page"
        variant="ghost"
        size="xs"
        id="threat-intel-first-page"
      >
        First
      </.ui_button>
      <.ui_button
        type="button"
        phx-click="prev_page"
        variant="outline"
        size="xs"
        disabled={@cursor_stack == []}
        id="threat-intel-prev-page"
      >
        <.icon name="hero-chevron-left" class="size-3.5" /> Previous
      </.ui_button>
      <.ui_button
        type="button"
        phx-click="next_page"
        variant="outline"
        size="xs"
        disabled={is_nil(@next_cursor)}
        id="threat-intel-next-page"
      >
        Next <.icon name="hero-chevron-right" class="size-3.5" />
      </.ui_button>
    </div>
    """
  end

  attr :selected_ip, :any, default: nil
  attr :selected_match, :any, default: nil
  attr :indicators, :list, default: []
  attr :indicator_error, :any, default: nil
  attr :indicator_state, :atom, default: :idle

  defp match_detail(assigns) do
    ~H"""
    <.ui_panel id="threat-intel-detail">
      <:header>
        <h2 class="text-base font-semibold text-sr-ink">Match detail</h2>
      </:header>
      <p :if={!@selected_ip} class="text-sm text-sr-muted">
        Select an endpoint to resolve the overlapping indicators.
      </p>
      <div :if={@selected_ip} class="space-y-3">
        <p class="break-all font-mono text-sm text-sr-ink">{@selected_ip}</p>
        <p
          :if={@selected_match && @selected_match.stale}
          class="text-sm text-amber-800 dark:text-amber-200"
        >
          Stale cache row. It is past its expiry and is hidden from the default list.
        </p>
        <.ui_alert
          :if={@indicator_error}
          variant="error"
          id="threat-intel-indicator-error"
          data-testid="threat-intel-indicator-error"
        >
          <div class="flex flex-wrap items-center justify-between gap-3">
            <span>{@indicator_error}</span>
            <.ui_button
              type="button"
              phx-click="retry"
              variant="outline"
              size="sm"
              id="threat-intel-indicator-retry"
            >
              Retry
            </.ui_button>
          </div>
        </.ui_alert>
        <div :if={@indicator_state in [:ready, :missing]} class="flex flex-wrap gap-2">
          <.ui_button
            id="threat-intel-inventory-link"
            href={ThreatIntelLinks.device_path(@selected_ip)}
            variant="ghost"
            size="xs"
          >
            Inventory
          </.ui_button>
          <.ui_button
            id="threat-intel-flow-link"
            href={ThreatIntelLinks.flow_path(@selected_ip)}
            variant="ghost"
            size="xs"
          >
            View flows
          </.ui_button>
          <.ui_button
            id="threat-intel-attributed-flow-link"
            href={ThreatIntelLinks.attributed_flow_path(@selected_ip)}
            variant="ghost"
            size="xs"
          >
            View attributed flows
          </.ui_button>
          <.ui_button
            id="threat-intel-retrohunt-link"
            patch={view_path("retrohunt", %{"ip" => @selected_ip})}
            variant="ghost"
            size="xs"
          >
            Retrohunt evidence
          </.ui_button>
        </div>
        <p
          :if={@indicator_state == :missing}
          class="text-sm text-sr-muted"
          data-testid="threat-intel-detail-notice"
        >
          {detail_notice(@selected_match)}
        </p>
        <ul :if={@indicator_state == :ready} class="space-y-2">
          <li
            :for={indicator <- @indicators}
            class="space-y-1 rounded-sr-surface border border-sr-line p-3"
            data-testid="threat-intel-indicator"
          >
            <div class="break-words font-medium text-sr-ink">
              {indicator.label || indicator.indicator}
            </div>
            <div class="break-all text-xs text-sr-muted">
              {indicator_summary(indicator)}
            </div>
            <div class="break-words text-xs text-sr-muted" data-testid="threat-intel-provider-context">
              {provider_context(indicator.source_context)}
            </div>
          </li>
        </ul>
      </div>
    </.ui_panel>
    """
  end

  defp load_page(socket) do
    socket
    |> assign(:loading, false)
    |> load_view(socket.assigns.view)
  end

  defp load_view(socket, "matches") do
    filters = socket.assigns.filters

    opts = [
      source: filters["source"],
      ip: filters["ip"],
      min_severity: filters["min_severity"],
      sort: filters["sort"],
      stale: filters["stale"] == "true",
      limit: @page_size,
      cursor: socket.assigns.cursor
    ]

    socket =
      put_page(
        socket,
        :matches,
        ThreatIntelInvestigation.list_current_matches(socket.assigns.current_scope, opts)
      )

    selected = socket.assigns.selected_ip

    socket
    |> assign(:selected_match, Enum.find(socket.assigns.rows, &(&1.observed_ip == selected)))
    |> load_indicators(selected)
  end

  defp load_view(socket, "indicator_matches") do
    opts = %{scope: socket.assigns.current_scope, limit: @page_size, cursor: socket.assigns.cursor}

    result =
      with {:ok, query} <- indicator_match_query(socket.assigns.filters) do
        case srql_module().query(query, opts) do
          {:ok, %{"results" => rows} = response} when is_list(rows) ->
            {:ok, %{rows: rows, next_cursor: get_in(response, ["pagination", "next_cursor"])}}

          {:ok, _other} ->
            {:ok, %{rows: [], next_cursor: nil}}

          {:error, reason} ->
            {:error, reason}
        end
      end

    put_page(socket, :indicator_matches, result)
  end

  defp load_view(socket, "inventory") do
    filters = socket.assigns.filters

    result =
      ThreatIntelEvidence.page_indicators(socket.assigns.current_scope,
        source: filters["source"],
        indicator: filters["indicator"],
        limit: @page_size,
        cursor: socket.assigns.cursor
      )

    put_page(socket, :inventory, result)
  end

  defp load_view(socket, "objects") do
    filters = socket.assigns.filters

    result =
      ThreatIntelEvidence.page_source_objects(socket.assigns.current_scope,
        source: filters["source"],
        indicator: filters["indicator"],
        limit: @page_size,
        cursor: socket.assigns.cursor
      )

    put_page(socket, :objects, result)
  end

  defp load_view(socket, "retrohunt") do
    scope = socket.assigns.current_scope
    filters = socket.assigns.filters

    {runs, runs_error} =
      case ThreatIntelEvidence.recent_retrohunt_runs(scope) do
        {:ok, runs} -> {runs, nil}
        {:error, reason} -> {[], load_error_message(:retrohunt_runs, reason)}
      end

    result =
      ThreatIntelEvidence.page_retrohunt_findings(scope,
        run_id: filters["run_id"],
        source: filters["source"],
        observed_ip: filters["ip"],
        indicator: filters["indicator"],
        limit: @page_size,
        cursor: socket.assigns.cursor
      )

    socket
    |> assign(:runs, runs)
    |> assign(:runs_error, runs_error)
    |> put_page(:retrohunt, result)
  end

  defp put_page(socket, _kind, {:ok, %{rows: rows, next_cursor: next_cursor}}) do
    socket
    |> assign(:rows, rows)
    |> assign(:next_cursor, next_cursor)
    |> assign(:load_error, nil)
  end

  defp put_page(socket, kind, {:error, reason}) do
    socket
    |> assign(:rows, [])
    |> assign(:next_cursor, nil)
    |> assign(:load_error, load_error_message(kind, reason))
  end

  defp indicator_match_query(filters) do
    with {:ok, ip} <- match_ip_filter(filters["ip"]),
         {:ok, severity} <- min_severity_filter(filters["min_severity"]) do
      query =
        [
          "in:threat_intel_matches",
          srql_token("source", filters["source"]),
          srql_token("observed_ip", ip),
          srql_token("indicator", filters["indicator"]),
          severity && "severity:>=#{severity}"
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")

      {:ok, query}
    end
  end

  defp match_ip_filter(nil), do: {:ok, nil}

  defp match_ip_filter(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, _address} -> {:ok, ip}
      {:error, _reason} -> {:error, :invalid_ip}
    end
  end

  defp min_severity_filter(nil), do: {:ok, nil}

  defp min_severity_filter(value) do
    case Integer.parse(value) do
      {severity, ""} -> {:ok, severity}
      _ -> {:error, :invalid_severity}
    end
  end

  defp srql_token(_field, nil), do: nil

  defp srql_token(field, value) do
    escaped = value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    ~s(#{field}:"#{escaped}")
  end

  defp load_indicators(socket, nil) do
    socket
    |> assign(:indicators, [])
    |> assign(:indicator_error, nil)
    |> assign(:indicator_state, :idle)
  end

  defp load_indicators(socket, ip) do
    case ThreatIntelInvestigation.indicators_for_ip(socket.assigns.current_scope, ip) do
      {:ok, indicators} ->
        socket
        |> assign(:indicators, indicators)
        |> assign(:indicator_error, nil)
        |> assign(:indicator_state, if(indicators == [], do: :missing, else: :ready))

      {:error, :invalid_ip} ->
        socket
        |> assign(:indicators, [])
        |> assign(:indicator_error, "The selected IP address is not valid.")
        |> assign(:indicator_state, :invalid)

      {:error, reason} ->
        socket
        |> assign(:indicators, [])
        |> assign(:indicator_error, load_error_message(:indicators, reason))
        |> assign(:indicator_state, :error)
    end
  end

  defp load_error_message(_kind, reason) when is_atom(reason) and is_map_key(@input_errors, reason) do
    Map.fetch!(@input_errors, reason)
  end

  defp load_error_message(kind, reason) do
    Logger.warning("threat intel investigation #{kind} failed: #{inspect(reason)}")

    if timeout?(reason) do
      "The #{kind_label(kind)} query timed out."
    else
      "Failed to load #{kind_label(kind)}."
    end
  end

  defp kind_label(:matches), do: "current-match"
  defp kind_label(:indicator_matches), do: "indicator-match"
  defp kind_label(:inventory), do: "imported-indicator"
  defp kind_label(:objects), do: "provider-object"
  defp kind_label(:retrohunt), do: "retrohunt-finding"
  defp kind_label(:retrohunt_runs), do: "retrohunt-run"
  defp kind_label(:indicators), do: "indicator"

  defp timeout?(%{postgres: %{code: :query_canceled}}), do: true
  defp timeout?(%DBConnection.ConnectionError{reason: reason}) when reason in [:timeout, :queue_timeout], do: true
  defp timeout?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &timeout?/1)
  defp timeout?(%{error: error}) when not is_nil(error), do: timeout?(error)
  defp timeout?(reason) when is_binary(reason), do: reason =~ ~r/timeout|timed out|canceling statement/i
  defp timeout?(_reason), do: false

  defp detail_notice(%{stale: true}), do: "This cache row is stale, and no active indicator still contains this endpoint."

  defp detail_notice(%{}), do: "No active indicator still contains this endpoint."

  defp detail_notice(_match), do: "This endpoint is not a current match, and no active indicator contains it."

  defp indicator_summary(indicator) do
    "#{indicator.source} · #{indicator.indicator} · sev #{indicator.severity || "—"} · confidence #{indicator.confidence || "—"}"
  end

  defp provider_context(%{source_label: label, source_object_type: type}) when is_binary(label) and label != "",
    do: "#{type}: #{label}"

  defp provider_context(%{source_object_id: id, source_object_type: type}), do: "#{type}: #{id}"
  defp provider_context(_context), do: "Provider context not available."

  defp view_tabs do
    [
      {"matches", "Matched IPs"},
      {"indicator_matches", "Indicator matches"},
      {"inventory", "IOCs"},
      {"objects", "Objects"},
      {"retrohunt", "Retrohunt"}
    ]
  end

  defp view_description("matches"),
    do: "Endpoints that currently match an imported indicator. Counts are indicator memberships, not flows."

  defp view_description("indicator_matches"), do: "Each live endpoint-to-indicator membership behind the match counts."

  defp view_description("inventory"), do: "Indicators imported from your feeds. Inventory, not local sightings."

  defp view_description("objects"), do: "Provider records, such as OTX pulses, that indicators were imported from."

  defp view_description("retrohunt"), do: "Historical evidence from retrohunt runs over retained flows."

  defp run_badge("ok"), do: "success"
  defp run_badge("error"), do: "error"
  defp run_badge("running"), do: "info"
  defp run_badge(_status), do: "ghost"

  # Moving between views keeps only the filters that mean the same thing there.
  defp carry_filters("matches", filters), do: Map.take(filters, ~w(source ip min_severity))
  defp carry_filters("indicator_matches", filters), do: Map.take(filters, ~w(source ip min_severity indicator))
  defp carry_filters("inventory", filters), do: Map.take(filters, ~w(source indicator))
  defp carry_filters("objects", filters), do: Map.take(filters, ~w(source indicator))
  defp carry_filters("retrohunt", filters), do: Map.take(filters, ~w(source ip indicator))

  defp view_path(view, filters) do
    params = reject_blank(filters)
    params = if view == "matches", do: params, else: Map.put(params, "view", view)
    ThreatIntelLinks.investigation_path(Enum.sort(params))
  end

  defp normalize_view(view) when view in @views, do: view
  defp normalize_view(_view), do: "matches"

  defp reject_blank(map) do
    map
    |> Enum.map(fn {key, value} -> {key, blank_to_nil(value)} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp timezone(%{user: %{timezone: timezone}}) when is_binary(timezone) and timezone != "", do: timezone
  defp timezone(_scope), do: "Etc/UTC"

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp dom_id(ip), do: ip |> to_string() |> String.replace(~r/[^A-Za-z0-9]/, "-")
end
