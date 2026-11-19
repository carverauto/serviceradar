defmodule ServiceRadarWebNGWeb.ServiceLive.Checks do
  @moduledoc """
  Operations Check Results Explorer (`/services/checks`) backed by SRQL
  `in:declarative_check_results` (and aliases `declarative_results`,
  `declarative_verdicts`).

  Renders KPI status summary cards, quick filter pills, expandable per-target
  verdict rows (linking back to `/settings/declarative-checks/:slug`), and
  `stats:` rollups while preserving the LiveView disconnected-mount Iron Law.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.ServiceLive.Checks.Components

  alias ServiceRadar.Observability.ServiceStatePubSub
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @page_path "/services/checks"
  @srql_entity "declarative_check_results"
  @default_limit 50
  @max_limit 200
  @list_opts [default_limit: @default_limit, max_limit: @max_limit]
  @default_query "in:declarative_check_results limit:50"
  @summary_query "in:declarative_check_results stats:count() as total by status"

  @view_permission "declarative_checks.view"
  @manage_permission "declarative_checks.manage"
  @evaluate_permission "declarative_checks.evaluate"

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if can_access?(scope) do
      if connected?(socket) do
        safe_subscribe_service_state()
      end

      {:ok,
       socket
       |> assign(:page_title, "Check Results")
       |> assign(:current_path, @page_path)
       |> assign(:can_view, true)
       |> assign(:can_manage, RBAC.can?(scope, @manage_permission))
       |> assign(:results, [])
       |> assign(:status_summary, empty_status_summary())
       |> assign(:stats_mode?, false)
       |> assign(:expanded_rows, MapSet.new())
       |> assign(:limit, @default_limit)
       |> assign(:pagination_page, 1)
       |> assign(:default_query, @default_query)
       |> SRQLPage.init(@srql_entity, default_limit: @default_limit)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to view Declarative Check Results")
       |> push_navigate(to: ~p"/services")}
    end
  end

  @impl true
  def handle_params(params, uri, socket) do
    if socket.assigns[:can_view] do
      query_params = ensure_default_query(params)

      socket =
        socket
        |> assign(:expanded_rows, MapSet.new())
        |> SRQLPage.sync_from_params(query_params, uri, @list_opts)

      query = get_in(socket.assigns, [:srql, :query]) || @default_query
      socket = assign(socket, :stats_mode?, stats_query?(query))

      {:noreply, load_results_and_summary(socket, query_params)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:service_state_updated, _payload}, socket) do
    if socket.assigns[:can_view] and connected_or_forced?(socket) do
      query = get_in(socket.assigns, [:srql, :query]) || @default_query
      page = socket.assigns[:pagination_page] || 1
      {:noreply, load_results_and_summary(socket, %{"q" => query, "page" => Integer.to_string(page)})}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_row_details", %{"row_key" => row_key}, socket) when is_binary(row_key) do
    if can_access?(socket.assigns.current_scope) do
      expanded = socket.assigns.expanded_rows

      updated =
        if MapSet.member?(expanded, row_key) do
          MapSet.delete(expanded, row_key)
        else
          MapSet.put(expanded, row_key)
        end

      {:noreply, assign(socket, :expanded_rows, updated)}
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  def handle_event("srql_change", params, socket) do
    if can_access?(socket.assigns.current_scope) do
      {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  def handle_event("srql_submit", params, socket) do
    if can_access?(socket.assigns.current_scope) do
      {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, fallback_path: @page_path)}
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  def handle_event("srql_reset", params, socket) do
    if can_access?(socket.assigns.current_scope) do
      {:noreply,
       SRQLPage.handle_event(socket, "srql_reset", params,
         fallback_path: @page_path,
         default_query: @default_query
       )}
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    if can_access?(socket.assigns.current_scope) do
      {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: @srql_entity)}
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  def handle_event("srql_builder_change", params, socket) do
    if can_access?(socket.assigns.current_scope) do
      {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  def handle_event("srql_builder_apply", _params, socket) do
    if can_access?(socket.assigns.current_scope) do
      {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  def handle_event("srql_builder_run", _params, socket) do
    if can_access?(socket.assigns.current_scope) do
      {:noreply, SRQLPage.handle_event(socket, "srql_builder_run", %{}, fallback_path: @page_path)}
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    if can_access?(socket.assigns.current_scope) do
      {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: @srql_entity)}
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    if can_access?(socket.assigns.current_scope) do
      {:noreply, SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: @srql_entity)}
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  def handle_event("srql_paginate", params, socket) when is_map(params) do
    if can_access?(socket.assigns.current_scope) do
      {:noreply, paginate_results(socket, params)}
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  @impl true
  def render(assigns) do
    pagination = get_in(assigns, [:srql, :pagination]) || %{}
    loading? = get_in(assigns, [:srql, :loading]) || false
    error = get_in(assigns, [:srql, :error])
    active_query = get_in(assigns, [:srql, :query]) || assigns.default_query

    assigns =
      assigns
      |> assign(:pagination, pagination)
      |> assign(:loading?, loading?)
      |> assign(:error, error)
      |> assign(:active_query, active_query)
      |> assign(:timezone, user_timezone(assigns[:current_scope]))
      |> assign(:active_filter, active_filter_key(active_query, assigns.stats_mode?))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div id="service-check-results-page" class="mx-auto max-w-7xl p-6 space-y-5">
        <nav
          id="services-subnav-tabs"
          aria-label="Services views"
          class="flex items-center justify-between gap-4 border-b border-sr-line"
        >
          <div class="flex items-center gap-2">
            <.link
              id="services-tab-overview"
              navigate={~p"/services"}
              class="border-b-2 border-transparent px-3 py-2 text-sm font-medium text-sr-muted hover:text-sr-ink transition-colors"
            >
              Service Checks
            </.link>
            <.link
              id="services-tab-check-results"
              navigate={~p"/services/checks"}
              class="border-b-2 border-sr-brand px-3 py-2 text-sm font-medium text-sr-ink"
            >
              Check Results
            </.link>
          </div>

          <.ui_button
            id="manage-declarative-checks-link"
            size="xs"
            variant="outline"
            navigate={~p"/settings/declarative-checks"}
          >
            <.icon name="hero-adjustments-horizontal" class="size-3.5 mr-1" /> Manage Checks
          </.ui_button>
        </nav>

        <header class="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h1 class="text-xl font-semibold text-sr-ink">Check Results Explorer</h1>
            <p class="mt-1 text-sm text-sr-muted">
              Live per-target declarative check verdicts queried via SRQL
              (<code>in:declarative_check_results</code>).
            </p>
          </div>
        </header>

        <.kpi_summary_cards summary={@status_summary} active_query={@active_query} />

        <.quick_filter_bar
          active_filter={@active_filter}
          active_query={@active_query}
          default_query={@default_query}
        />

        <.ui_alert :if={@error} id="check-results-error" variant="error">
          {@error}
        </.ui_alert>

        <div
          :if={@loading?}
          id="check-results-loading"
          class="rounded-lg border border-sr-line bg-sr-surface p-8 text-center text-sm text-sr-muted"
        >
          Loading check results...
        </div>

        <div
          :if={!@loading? and is_nil(@error) and @results == []}
          id="check-results-empty"
          class="rounded-lg border border-sr-line bg-sr-surface p-8 text-center space-y-2"
        >
          <p class="text-sm font-medium text-sr-ink">No check results matched</p>
          <p class="mx-auto max-w-md text-xs text-sr-muted">
            Adjust the SRQL query in the topbar, pick a quick filter pill, or configure checks in
            Declarative Checks settings.
          </p>
        </div>

        <div :if={!@loading? and @results != []}>
          <%= if @stats_mode? do %>
            <.stats_view results={@results} />
          <% else %>
            <.ui_panel>
              <.results_table
                results={@results}
                expanded_rows={@expanded_rows}
                timezone={@timezone}
              />

              <div class="mt-4 pt-4 border-t border-sr-line">
                <.ui_pagination
                  prev_cursor={Map.get(@pagination, "prev_cursor")}
                  next_cursor={Map.get(@pagination, "next_cursor")}
                  limit={@limit}
                  current_page={@pagination_page}
                  result_count={length(@results)}
                />
              </div>
            </.ui_panel>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp load_results_and_summary(socket, params) do
    request = SRQLPage.list_request(socket, params, :results, @list_opts)

    if connected_or_forced?(socket) do
      {results, _error, _viz, _pagination} = list_result = SRQLPage.fetch_list(request)
      socket = SRQLPage.apply_list_result(socket, request, list_result)
      summary = resolve_status_summary(socket, results)
      assign(socket, :status_summary, summary)
    else
      SRQLPage.apply_list_result(socket, request, {[], nil, nil, %{}}, loading: true)
    end
  end

  defp paginate_results(socket, params) do
    query = get_in(socket.assigns, [:srql, :query]) || @default_query
    page_path = get_in(socket.assigns, [:srql, :page_path]) || @page_path
    cursor = Map.get(params, "cursor")
    page = Map.get(params, "page", "1")

    query_params =
      then(%{"q" => query, "page" => to_string(page)}, fn map ->
        if is_binary(cursor) and cursor != "", do: Map.put(map, "cursor", cursor), else: map
      end)

    socket =
      socket
      |> assign(:expanded_rows, MapSet.new())
      |> SRQLPage.sync_from_params(query_params, page_path, @list_opts)
      |> assign(:stats_mode?, stats_query?(query))

    request = SRQLPage.list_request(socket, query_params, :results, @list_opts)

    if connected_or_forced?(socket) do
      SRQLPage.apply_list_result(socket, request, SRQLPage.fetch_list(request))
    else
      SRQLPage.apply_list_result(socket, request, {[], nil, nil, %{}}, loading: true)
    end
  end

  defp resolve_status_summary(socket, results) do
    case fetch_status_summary(socket.assigns.current_scope) do
      {:ok, summary} -> summary
      :error -> summarize_rows(results)
    end
  end

  defp fetch_status_summary(scope) do
    case srql_module().query(@summary_query, %{limit: 20, scope: scope}) do
      {:ok, %{"results" => rows}} when is_list(rows) ->
        {:ok, aggregate_status_rows(rows)}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp aggregate_status_rows(rows) do
    Enum.reduce(rows, empty_status_summary(), fn row, acc ->
      status = row |> Map.get("status") |> to_string() |> String.downcase()
      count = extract_numeric_count(row)

      if Map.has_key?(acc, status) do
        Map.update!(acc, status, &(&1 + count))
      else
        acc
      end
    end)
  end

  defp summarize_rows(rows) do
    Enum.reduce(rows, empty_status_summary(), fn row, acc ->
      status = row |> Map.get("status") |> to_string() |> String.downcase()

      if Map.has_key?(acc, status) do
        Map.update!(acc, status, &(&1 + 1))
      else
        acc
      end
    end)
  end

  defp extract_numeric_count(row) when is_map(row) do
    Enum.find_value(row, 0, fn
      {_k, v} when is_integer(v) -> v
      {_k, v} when is_float(v) -> trunc(v)
      _ -> nil
    end)
  end

  defp extract_numeric_count(_), do: 0

  defp empty_status_summary do
    %{"healthy" => 0, "degraded" => 0, "down" => 0, "unknown" => 0}
  end

  defp ensure_default_query(params) when is_map(params) do
    case Map.get(params, "q") do
      q when is_binary(q) ->
        if String.trim(q) == "", do: Map.put(params, "q", @default_query), else: params

      _ ->
        Map.put(params, "q", @default_query)
    end
  end

  defp active_filter_key(_query, true), do: "stats"

  defp active_filter_key(query, false) when is_binary(query) do
    cond do
      String.contains?(query, "status:(down,degraded)") -> "failing"
      String.contains?(query, "status:healthy") -> "healthy"
      not String.contains?(query, "status:") -> "all"
      true -> "custom"
    end
  end

  defp active_filter_key(_, _), do: "all"

  defp stats_query?(query) when is_binary(query) do
    Regex.match?(~r/(?:^|\s)stats:/i, query)
  end

  defp stats_query?(_), do: false

  defp connected_or_forced?(socket) do
    connected?(socket) or socket.assigns[:force_connected_load?] == true
  end

  defp can_access?(scope) do
    RBAC.can?(scope, @view_permission) or
      RBAC.can?(scope, @manage_permission) or
      RBAC.can?(scope, @evaluate_permission)
  end

  defp unauthorized_flash(socket) do
    put_flash(socket, :error, "You do not have permission to view Declarative Check Results")
  end

  defp safe_subscribe_service_state do
    ServiceStatePubSub.subscribe()
  rescue
    _ -> :ok
  end

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  defp user_timezone(%{user: %{timezone: timezone}}) when is_binary(timezone) and timezone != "", do: timezone

  defp user_timezone(_current_scope), do: "Etc/UTC"
end
