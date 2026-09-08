defmodule ServiceRadarWebNGWeb.ObservabilityHealthLive.Index do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNGWeb.SRQL.Builder
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  require Logger

  @anomaly_query "in:events event_type:(anomaly,anomaly_detection) time:last_24h sort:time:desc limit:25"
  @health_query "in:events rollup_stats:anomaly_findings time:last_24h limit:1"
  # The worker/DB only ever persist status projected|skipped (DB CHECK);
  # at_risk/exhaustion_projected never occur as row statuses.
  @capacity_query "in:capacity_forecasts status:projected has_exhaustion:true sort:projected_exhaustion_at:asc limit:25"
  # SRQL has no grouped stats for capacity_forecasts (the entity executor
  # ignores stats clauses), so fetch a bounded recent sample and aggregate
  # skip reasons per series in Elixir.
  @capacity_skipped_query "in:capacity_forecasts status:skipped time:last_24h sort:forecasted_at:desc limit:500"
  @capacity_skipped_top_reasons 3
  @capacity_skipped_visible_max 4
  @srql_default_limit 25

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Observability Health")
     |> assign(:loading?, connected?(socket))
     |> assign(:overview, empty_overview(:loading))
     |> assign(:capacity_query, @capacity_query)
     |> assign(:selected_capacity, nil)
     |> assign(:limit, @srql_default_limit)
     |> SRQLPage.init("capacity_forecasts", default_limit: @srql_default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    capacity_query = capacity_query_from_params(params)
    socket = prefill_srql_bar(socket, capacity_query, uri)

    if connected?(socket) do
      scope = socket.assigns.current_scope

      {:noreply,
       socket
       |> assign(:capacity_query, capacity_query)
       |> assign(:selected_capacity, nil)
       |> assign(:loading?, true)
       |> start_async(:observability_health_overview, fn ->
         load_overview(scope, capacity_query)
       end)}
    else
      {:noreply, assign(socket, :capacity_query, capacity_query)}
    end
  end

  @impl true
  def handle_async(:observability_health_overview, {:ok, overview}, socket) do
    {:noreply, socket |> assign(:loading?, false) |> assign(:overview, overview)}
  end

  def handle_async(:observability_health_overview, {:exit, reason}, socket) do
    Logger.warning("Failed to load observability health overview: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:loading?, false)
     |> assign(:overview, empty_overview(:error))}
  end

  @impl true
  def handle_event("open_capacity_row", %{"index" => index}, socket) do
    row = Enum.at(socket.assigns.overview.capacity_rows, parse_index(index))

    {:noreply, assign(socket, :selected_capacity, row)}
  end

  def handle_event("close_capacity_row", _params, socket) do
    {:noreply, assign(socket, :selected_capacity, nil)}
  end

  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, fallback_path: "/observability/health")}
  end

  def handle_event("srql_reset", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_reset", params, fallback_path: "/observability/health")}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "capacity_forecasts")}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_run", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_run", %{}, fallback_path: "/observability/health")}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "capacity_forecasts")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "capacity_forecasts")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="sr-observability-page mx-auto max-w-7xl space-y-5 p-6 font-sans">
        <.observability_chrome
          active_pane="health"
          title="Observability Health"
          subtitle="Anomaly findings, capacity runway, and causal-health signals in one fleet view."
        />

        <div
          :if={@overview.status in [:error, :partial]}
          class="rounded-lg border border-warning/30 bg-warning/10 p-4 text-sm text-warning"
        >
          Some observability health queries did not complete. Showing the data that is currently available.
        </div>

        <div :if={@loading?} class="rounded-lg border border-sr-line bg-sr-surface p-4">
          <div class="flex items-center gap-3 text-sm text-sr-muted">
            <.ui_spinner size="sm" />
            <span>Loading observability health...</span>
          </div>
        </div>

        <section class="grid gap-3 md:grid-cols-3">
          <.health_stat
            label="Anomaly findings"
            value={@overview.anomaly_count}
            detail="Recent anomaly-detection events"
            href={observability_href(@overview.anomaly_query)}
            tone="warning"
          />
          <.health_stat
            label="At-risk capacity"
            value={@overview.capacity_count}
            detail="Projected capacity rows"
            href={observability_href(@overview.capacity_query)}
            tone="error"
          />
          <.health_stat
            label="Health findings"
            value={@overview.health_count}
            detail="Anomaly and capacity event stream"
            href={observability_href(@overview.health_query)}
            tone="info"
          />
        </section>

        <section class="grid gap-5 xl:grid-cols-[1.2fr_0.8fr]">
          <div class="rounded-lg border border-sr-line bg-sr-surface">
            <div class="flex flex-wrap items-center justify-between gap-3 border-b border-sr-line px-5 py-4">
              <div>
                <h2 class="text-base font-semibold">Capacity Runway</h2>
                <p class="text-xs text-sr-muted">
                  Forecast rows ordered by projected exhaustion.
                </p>
              </div>
              <.ui_button
                navigate={~p"/observability/health?#{%{q: @capacity_query}}"}
                size="xs"
                variant="outline"
              >
                Refresh query
              </.ui_button>
            </div>

            <div class="border-b border-sr-line bg-sr-subtle/20 px-5 py-2">
              <code class="block truncate font-mono text-[11px] text-sr-muted" title={@capacity_query}>
                {@capacity_query}
              </code>
            </div>

            <div class="sr-ui-table-shell">
              <table class={ui_table_class(size: "sm")}>
                <thead>
                  <tr>
                    <th>Resource</th>
                    <th>Metric</th>
                    <th>Status</th>
                    <th>Current</th>
                    <th>Projected</th>
                    <th>Exhaustion</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :if={@overview.capacity_rows == []}>
                    <td colspan="6" class="py-8 text-center text-sr-muted">
                      No projected capacity risks found.
                    </td>
                  </tr>
                  <tr
                    :for={{row, index} <- Enum.with_index(@overview.capacity_rows)}
                    id={"capacity-row-#{index}"}
                    phx-click="open_capacity_row"
                    phx-value-index={index}
                    class="cursor-pointer transition-colors hover:bg-sr-subtle/60"
                  >
                    <td class="max-w-64 truncate font-medium text-sr-ink" title={resource_label(row)}>
                      {resource_label(row)}
                    </td>
                    <td class="font-mono text-xs">{value(row, "metric_name") || "unknown"}</td>
                    <td>
                      <.ui_badge size="sm" variant={status_badge_variant(value(row, "status"))}>
                        {value(row, "status") || "unknown"}
                      </.ui_badge>
                    </td>
                    <td class="font-mono text-xs tabular-nums">
                      {format_number(value(row, "current_value"))}
                    </td>
                    <td class="font-mono text-xs tabular-nums">
                      {format_number(value(row, "projected_value"))}
                    </td>
                    <td class="whitespace-nowrap font-mono text-xs">
                      <.user_time
                        id={"observability-capacity-#{capacity_time_key(row, index)}-projected-exhaustion-at"}
                        value={value(row, "projected_exhaustion_at")}
                        timezone={@current_scope.user.timezone || "Etc/UTC"}
                        style={:compact}
                      />
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <div
              :if={show_capacity_skipped?(@overview)}
              class="border-t border-sr-line px-5 py-3 text-xs text-sr-muted"
            >
              {capacity_skipped_summary(@overview.capacity_skipped)}
            </div>
          </div>

          <div class="space-y-3">
            <div class="rounded-lg border border-sr-line bg-sr-surface px-5 py-4">
              <h2 class="text-base font-semibold">Worst Forecasts</h2>
              <p class="text-xs text-sr-muted">
                Current to projected movement for the nearest-risk resources.
              </p>
            </div>

            <.forecast_card
              :for={{row, index} <- Enum.with_index(Enum.take(@overview.capacity_rows, 4))}
              row={row}
              index={index}
              timezone={@current_scope.user.timezone || "Etc/UTC"}
            />
            <div
              :if={@overview.capacity_rows == []}
              class="rounded-lg border border-sr-line bg-sr-surface p-5 text-sm text-sr-muted"
            >
              No forecast rows to visualize yet.
            </div>
          </div>
        </section>

        <section class="rounded-lg border border-sr-line bg-sr-surface">
          <div class="flex flex-wrap items-center justify-between gap-3 border-b border-sr-line px-5 py-4">
            <div>
              <h2 class="text-base font-semibold">Recent Anomaly Findings</h2>
              <p class="text-xs text-sr-muted">
                Detection findings from the causal anomaly spine.
              </p>
            </div>
            <.ui_button
              navigate={observability_href(@overview.anomaly_query)}
              size="xs"
              variant="outline"
            >
              Open events
            </.ui_button>
          </div>

          <div class="divide-y divide-sr-line">
            <div :if={@overview.anomaly_rows == []} class="p-6 text-sm text-sr-muted">
              No anomaly findings found in the last 24 hours.
            </div>
            <.link
              :for={{row, index} <- Enum.with_index(@overview.anomaly_rows)}
              navigate={anomaly_event_href(row)}
              class="block px-5 py-4 transition-colors hover:bg-sr-subtle/50"
            >
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div class="min-w-0">
                  <div class="truncate text-sm font-semibold text-sr-ink">
                    {finding_title(row)}
                  </div>
                  <div class="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-xs text-sr-muted">
                    <span>
                      {value(row, "source_type") || value(row, "log_provider") || "anomaly"}
                    </span>
                    <span :if={device_label(row)}>{device_label(row)}</span>
                    <.user_time
                      id={"observability-anomaly-#{anomaly_time_key(row, index)}-time"}
                      value={value(row, "time")}
                      timezone={@current_scope.user.timezone || "Etc/UTC"}
                      style={:compact}
                    />
                  </div>
                </div>
                <.ui_badge size="sm" variant={severity_badge_variant(value(row, "severity"))}>
                  {value(row, "severity") || "Unknown"}
                </.ui_badge>
              </div>
            </.link>
          </div>
        </section>
      </div>

      <.capacity_detail_modal
        :if={is_map(@selected_capacity)}
        row={@selected_capacity}
        timezone={@current_scope.user.timezone || "Etc/UTC"}
      />
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :detail, :string, required: true
  attr :href, :string, required: true
  attr :tone, :string, default: "base"

  defp health_stat(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class="block rounded-lg border border-sr-line bg-sr-surface p-4 hover:border-sr-brand/40"
    >
      <div class="text-xs font-semibold uppercase tracking-normal text-sr-muted">{@label}</div>
      <div class={["mt-2 text-3xl font-semibold", stat_tone_class(@tone)]}>{@value}</div>
      <div class="mt-1 text-xs text-sr-muted">{@detail}</div>
    </.link>
    """
  end

  attr :row, :map, required: true
  attr :index, :integer, default: 0
  attr :timezone, :string, required: true

  defp forecast_card(assigns) do
    current = number_value(assigns.row, "current_value")
    projected = number_value(assigns.row, "projected_value")
    threshold = number_value(assigns.row, "exhaustion_threshold")
    scale = Enum.max([current || 0.0, projected || 0.0, threshold || 0.0, 1.0])

    assigns =
      assigns
      |> assign(:current, current)
      |> assign(:projected, projected)
      |> assign(:threshold, threshold)
      |> assign(:current_width, percent_width(current, scale))
      |> assign(:projected_width, percent_width(projected, scale))
      |> assign(:threshold_width, percent_width(threshold, scale))

    ~H"""
    <button
      type="button"
      phx-click="open_capacity_row"
      phx-value-index={@index}
      class="w-full rounded-lg border border-sr-line bg-sr-surface p-4 text-left transition-colors hover:border-sr-brand/40 hover:bg-sr-subtle/30"
    >
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="truncate text-sm font-semibold text-sr-ink">{resource_label(@row)}</div>
          <div class="mt-1 text-xs text-sr-muted">
            {value(@row, "metric_name") || "metric"}
          </div>
        </div>
        <.ui_badge size="sm" variant={status_badge_variant(value(@row, "status"))}>
          {value(@row, "status") || "unknown"}
        </.ui_badge>
      </div>

      <div class="mt-4 space-y-2">
        <.forecast_bar label="Current" value={@current} width={@current_width} class="bg-sky-400" />
        <.forecast_bar
          label="Projected"
          value={@projected}
          width={@projected_width}
          class="bg-amber-400"
        />
        <.forecast_bar
          label="Threshold"
          value={@threshold}
          width={@threshold_width}
          class="bg-rose-400"
        />
      </div>

      <div class="mt-3 text-xs text-sr-muted">
        Exhaustion
        <.user_time
          id={"observability-forecast-#{capacity_time_key(@row, @index)}-projected-exhaustion-at"}
          value={value(@row, "projected_exhaustion_at")}
          timezone={@timezone}
          style={:compact}
        />
      </div>
    </button>
    """
  end

  attr :row, :map, required: true
  attr :timezone, :string, required: true

  defp capacity_detail_modal(assigns) do
    device_uid = capacity_device_uid(assigns.row)

    assigns =
      assigns
      |> assign(:device_uid, device_uid)
      |> assign(:resource, resource_label(assigns.row))

    ~H"""
    <dialog
      id="capacity-forecast-detail-modal"
      class="sr-ui-modal sr-ui-modal-open"
      phx-hook="DialogTopLayer"
      data-cancel="close_capacity_row"
    >
      <div class="sr-ui-modal-box sr-ui-modal-box-lg">
        <div class="flex items-start justify-between gap-4 border-b border-sr-line pb-4">
          <div class="min-w-0">
            <h2 class="text-lg font-semibold tracking-tight text-sr-ink">Capacity forecast</h2>
            <div class="mt-1 truncate text-sm text-sr-muted" title={@resource}>{@resource}</div>
          </div>
          <.ui_icon_button
            type="button"
            phx-click="close_capacity_row"
            aria-label="Close"
            size="sm"
            variant="ghost"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </.ui_icon_button>
        </div>

        <div class="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-2">
          <.capacity_fact label="Resource" value={@resource} mono />
          <.capacity_fact label="Metric" value={value(@row, "metric_name")} mono />
          <.capacity_fact label="Status" value={value(@row, "status")} />
          <.capacity_fact label="Current" value={format_number(value(@row, "current_value"))} mono />
          <.capacity_fact
            label="Projected"
            value={format_number(value(@row, "projected_value"))}
            mono
          />
          <.capacity_fact
            label="Threshold"
            value={format_number(value(@row, "exhaustion_threshold"))}
            mono
          />
          <.capacity_fact label="Exhaustion" mono>
            <.user_time
              id={"observability-capacity-detail-#{capacity_time_key(@row, 0)}-projected-exhaustion-at"}
              value={value(@row, "projected_exhaustion_at")}
              timezone={@timezone}
              style={:compact}
            />
          </.capacity_fact>
          <.capacity_fact label="Unit" value={capacity_value_unit(@row)} mono />
          <.capacity_fact label="Resource key" value={value(@row, "resource_key")} mono />
          <.capacity_fact label="Resource ID" value={value(@row, "resource_id")} mono />
          <.capacity_fact label="Skip reason" value={value(@row, "skip_reason")} />
          <.capacity_fact label="Forecasted at" mono>
            <.user_time
              id={"observability-capacity-detail-#{capacity_time_key(@row, 0)}-forecasted-at"}
              value={value(@row, "forecasted_at")}
              timezone={@timezone}
              style={:compact}
            />
          </.capacity_fact>
        </div>

        <div class="sr-ui-modal-action">
          <.ui_button
            :if={is_binary(@device_uid)}
            navigate={~p"/devices/#{@device_uid}"}
            size="sm"
            variant="outline"
          >
            View device
          </.ui_button>
          <.ui_button
            navigate={~p"/observability/health?#{%{q: capacity_row_query(@row)}}"}
            size="sm"
            variant="outline"
          >
            Filter runway
          </.ui_button>
          <.ui_button type="button" phx-click="close_capacity_row" size="sm" variant="ghost">
            Close
          </.ui_button>
        </div>
      </div>
    </dialog>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :mono, :boolean, default: false
  slot :inner_block

  defp capacity_fact(assigns) do
    ~H"""
    <div
      :if={@inner_block != [] or not blank_capacity?(@value)}
      class="min-w-0 rounded-lg border border-sr-line bg-sr-subtle/30 p-3"
    >
      <div class="text-[10px] font-medium uppercase tracking-wider text-sr-muted">{@label}</div>
      <div class={[
        "mt-1 break-all text-sm text-sr-ink",
        @mono && "font-mono text-[13px]"
      ]}>
        <%= if @inner_block != [] do %>
          {render_slot(@inner_block)}
        <% else %>
          {@value}
        <% end %>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :float, default: nil
  attr :width, :string, required: true
  attr :class, :string, required: true

  defp forecast_bar(assigns) do
    ~H"""
    <div>
      <div class="mb-1 flex items-center justify-between gap-3 text-xs">
        <span class="text-sr-muted">{@label}</span>
        <span class="font-mono">{format_number(@value)}</span>
      </div>
      <div class="h-2 rounded-full bg-sr-subtle">
        <div class={["h-2 rounded-full", @class]} style={"width: #{@width};"} />
      </div>
    </div>
    """
  end

  defp capacity_query_from_params(params) when is_map(params) do
    case Map.get(params, "q") do
      q when is_binary(q) ->
        q = String.trim(q)

        if q != "" and String.contains?(q, "in:capacity_forecasts") do
          q
        else
          @capacity_query
        end

      _ ->
        @capacity_query
    end
  end

  defp capacity_query_from_params(_), do: @capacity_query

  defp prefill_srql_bar(socket, query, uri) when is_binary(query) do
    page_path =
      case uri do
        path when is_binary(path) and path != "" -> URI.parse(uri).path || "/observability/health"
        _ -> "/observability/health"
      end

    srql =
      (socket.assigns[:srql] || %{})
      |> Map.merge(%{
        enabled: true,
        entity: "capacity_forecasts",
        query: query,
        draft: query,
        page_path: page_path,
        error: nil,
        loading: false,
        builder_available: true,
        builder_open: false
      })
      |> sync_builder_state(query)

    assign(socket, :srql, srql)
  end

  defp sync_builder_state(srql, query) do
    case Builder.parse(query) do
      {:ok, builder} ->
        Map.merge(srql, %{
          builder: builder,
          builder_available: true,
          builder_supported: true,
          builder_sync: true
        })

      {:error, _} ->
        Map.merge(srql, %{
          builder_available: true,
          builder_supported: false,
          builder_sync: false
        })
    end
  end

  defp parse_index(index) when is_binary(index) do
    case Integer.parse(index) do
      {i, _} -> i
      :error -> -1
    end
  end

  defp parse_index(index) when is_integer(index), do: index
  defp parse_index(_), do: -1

  defp load_overview(scope, capacity_query) do
    summary_result = query_rows(@health_query, scope)
    summary = summary_counts(summary_result)

    capacity_result = query_rows(capacity_query, scope)

    capacity_rows =
      capacity_result
      |> result_rows()
      |> Enum.reject(&invalid_capacity_runway_row?/1)

    # Supplemental summary; only fetched when the runway table is small enough
    # for the summary line to render at all. A failure is logged by query_rows
    # and hides the line instead of degrading the whole overview to :partial.
    capacity_skipped =
      if length(capacity_rows) <= @capacity_skipped_visible_max do
        @capacity_skipped_query
        |> query_rows(scope)
        |> result_rows()
        |> summarize_skipped_series()
      else
        %{count: 0, top_reasons: []}
      end

    anomaly_result =
      if summary.anomaly_count > 0 do
        query_rows(@anomaly_query, scope)
      else
        {:ok, []}
      end

    anomaly_rows = result_rows(anomaly_result)
    status = overview_status([summary_result, capacity_result, anomaly_result])

    %{
      status: status,
      anomaly_query: @anomaly_query,
      health_query: @health_query,
      capacity_query: capacity_query,
      anomaly_rows: anomaly_rows,
      health_rows: [],
      capacity_rows: capacity_rows,
      capacity_skipped: capacity_skipped,
      anomaly_count: summary.anomaly_count || length(anomaly_rows),
      health_count: summary.health_count || length(anomaly_rows),
      capacity_count: max(summary.capacity_count || 0, length(capacity_rows))
    }
  end

  defp query_rows(query, scope) do
    case srql_module().query(query, %{scope: scope}) do
      {:ok, response} ->
        {:ok, rows(response)}

      {:error, reason} = error ->
        Logger.warning("Observability health SRQL query failed query=#{inspect(query)} reason=#{inspect(reason)}")
        error
    end
  end

  defp result_rows({:ok, rows}) when is_list(rows), do: rows
  defp result_rows(_result), do: []

  defp summary_counts({:ok, [row | _rest]}) do
    %{
      anomaly_count: integer_value(row, "anomalies"),
      capacity_count: integer_value(row, "at_risk"),
      health_count: integer_value(row, "total")
    }
  end

  defp summary_counts(_result) do
    %{anomaly_count: 0, capacity_count: 0, health_count: 0}
  end

  defp integer_value(row, key) do
    case value(row, key) do
      value when is_integer(value) ->
        value

      value when is_float(value) ->
        trunc(value)

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, _rest} -> integer
          :error -> 0
        end

      _ ->
        0
    end
  end

  defp overview_status(results) do
    cond do
      Enum.all?(results, &match?({:ok, _rows}, &1)) -> :ok
      Enum.any?(results, &match?({:ok, _rows}, &1)) -> :partial
      true -> :error
    end
  end

  defp empty_overview(status) do
    %{
      status: status,
      anomaly_query: @anomaly_query,
      health_query: @health_query,
      capacity_query: @capacity_query,
      anomaly_rows: [],
      health_rows: [],
      capacity_rows: [],
      capacity_skipped: %{count: 0, top_reasons: []},
      anomaly_count: 0,
      health_count: 0,
      capacity_count: 0
    }
  end

  defp summarize_skipped_series(rows) do
    series =
      rows
      |> Enum.filter(&is_map/1)
      |> Enum.uniq_by(&{value(&1, "resource_id"), value(&1, "resource_key"), value(&1, "metric_name")})

    top_reasons =
      series
      |> Enum.frequencies_by(&(value(&1, "skip_reason") || "unknown"))
      |> Enum.sort_by(fn {reason, count} -> {-count, reason} end)
      |> Enum.take(@capacity_skipped_top_reasons)

    %{count: length(series), top_reasons: top_reasons}
  end

  defp show_capacity_skipped?(%{capacity_skipped: %{count: count}, capacity_rows: rows}) do
    count > 0 and length(rows) <= @capacity_skipped_visible_max
  end

  defp show_capacity_skipped?(_overview), do: false

  defp capacity_skipped_summary(%{count: count, top_reasons: []}) do
    "#{count} series skipped in last 24h"
  end

  defp capacity_skipped_summary(%{count: count, top_reasons: reasons}) do
    reasons_text = Enum.map_join(reasons, ", ", fn {reason, n} -> "#{reason} #{n}" end)
    "#{count} series skipped in last 24h (top: #{reasons_text})"
  end

  defp rows(%{"results" => rows}) when is_list(rows), do: rows
  defp rows(%{results: rows}) when is_list(rows), do: rows
  defp rows(_response), do: []

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  defp observability_href(query) do
    "/observability/events?" <> URI.encode_query(%{q: query})
  end

  defp value(%{} = row, key), do: Map.get(row, key) || Map.get(row, known_atom_key(key))
  defp value(_row, _key), do: nil

  defp nested_value(value, []), do: value

  defp nested_value(%{} = row, [key | rest]) do
    row
    |> value(key)
    |> nested_value(rest)
  end

  defp nested_value(_row, _path), do: nil

  defp known_atom_key("device"), do: :device
  defp known_atom_key("finding_title"), do: :finding_title
  defp known_atom_key("finding_uid"), do: :finding_uid
  defp known_atom_key("log_provider"), do: :log_provider
  defp known_atom_key("message"), do: :message
  defp known_atom_key("metadata"), do: :metadata
  defp known_atom_key("metric_name"), do: :metric_name
  defp known_atom_key("name"), do: :name
  defp known_atom_key("anomalies"), do: :anomalies
  defp known_atom_key("at_risk"), do: :at_risk
  defp known_atom_key("current_value"), do: :current_value
  defp known_atom_key("exhaustion_threshold"), do: :exhaustion_threshold
  defp known_atom_key("projected_value"), do: :projected_value
  defp known_atom_key("projected_exhaustion_at"), do: :projected_exhaustion_at
  defp known_atom_key("forecasted_at"), do: :forecasted_at
  defp known_atom_key("raw_data"), do: :raw_data
  defp known_atom_key("resource_id"), do: :resource_id
  defp known_atom_key("resource_key"), do: :resource_key
  defp known_atom_key("resource_label"), do: :resource_label
  defp known_atom_key("severity"), do: :severity
  defp known_atom_key("skip_reason"), do: :skip_reason
  defp known_atom_key("short_message"), do: :short_message
  defp known_atom_key("source_type"), do: :source_type
  defp known_atom_key("status"), do: :status
  defp known_atom_key("time"), do: :time
  defp known_atom_key("total"), do: :total
  defp known_atom_key("uid"), do: :uid
  defp known_atom_key("unit"), do: :unit
  defp known_atom_key("value_unit"), do: :value_unit
  defp known_atom_key("forecast_value_unit"), do: :forecast_value_unit
  defp known_atom_key("raw_value_unit"), do: :raw_value_unit
  defp known_atom_key(_), do: nil

  defp invalid_capacity_runway_row?(row) do
    missing_projected_exhaustion?(row) or invalid_percent_capacity_row?(row)
  end

  defp missing_projected_exhaustion?(row), do: is_nil(value(row, "projected_exhaustion_at"))

  defp invalid_percent_capacity_row?(row) do
    projected = number_value(row, "projected_value")
    percent_capacity_row?(row) and is_number(projected) and (projected < 0.0 or projected > 100.0)
  end

  defp percent_capacity_row?(row) do
    row
    |> capacity_value_unit()
    |> percent_unit?()
  end

  defp capacity_value_unit(row) do
    first_present(row, [
      ["value_unit"],
      ["unit"],
      ["metadata", "forecast_value_unit"],
      ["metadata", "raw_value_unit"],
      ["metadata", "unit"]
    ]) || inferred_capacity_value_unit(row)
  end

  defp inferred_capacity_value_unit(row) do
    row
    |> value("metric_name")
    |> case do
      metric when is_binary(metric) and metric in ["usage_percent", "utilization_percent"] ->
        "percent"

      metric when is_binary(metric) ->
        if String.ends_with?(metric, ["usage_percent", "used_percent", "utilization_percent"]) do
          "percent"
        end

      _ ->
        nil
    end
  end

  defp percent_unit?(unit) when is_binary(unit) do
    unit
    |> String.downcase()
    |> case do
      "%" -> true
      "percent" -> true
      "percentage" -> true
      _ -> false
    end
  end

  defp percent_unit?(_unit), do: false

  defp first_present(row, paths) do
    Enum.find_value(paths, fn path ->
      case nested_value(row, path) do
        nil -> nil
        "" -> nil
        value -> value
      end
    end)
  end

  defp resource_label(row) do
    value(row, "resource_label") || value(row, "resource_key") || value(row, "resource_id") ||
      "Unknown resource"
  end

  defp capacity_device_uid(row) do
    id = value(row, "resource_id") || value(row, "resource_key")

    if is_binary(id) and String.starts_with?(id, "sr:"), do: id
  end

  defp capacity_row_query(row) do
    resource = value(row, "resource_key") || value(row, "resource_id") || value(row, "resource_label")
    metric = value(row, "metric_name")

    resource_token =
      if is_binary(resource) and resource != "" do
        ~s|resource_key:"#{escape_srql(resource)}"|
      end

    metric_token =
      if is_binary(metric) and metric != "" do
        ~s|metric_name:"#{escape_srql(metric)}"|
      end

    ["in:capacity_forecasts", resource_token, metric_token, "sort:projected_exhaustion_at:asc", "limit:25"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp escape_srql(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp escape_srql(other), do: escape_srql(to_string(other))

  defp blank_capacity?(nil), do: true
  defp blank_capacity?(""), do: true
  defp blank_capacity?("-"), do: true
  defp blank_capacity?(_), do: false

  defp finding_title(row) do
    value(row, "finding_title") ||
      nested_value(row, ["metadata", "finding_info", "title"]) ||
      value(row, "message") ||
      value(row, "short_message") ||
      "Anomaly finding"
  end

  defp anomaly_event_href(row) do
    case value(row, "id") || nested_value(row, ["metadata", "finding_info", "uid"]) do
      id when is_binary(id) and id != "" -> ~p"/events/#{id}"
      _ -> observability_href(@anomaly_query)
    end
  end

  defp device_label(row) do
    nested_value(row, ["device", "name"]) || nested_value(row, ["device", "uid"])
  end

  defp number_value(row, key) do
    case value(row, key) do
      value when is_number(value) -> value * 1.0
      value when is_binary(value) -> parse_float(value)
      _ -> nil
    end
  end

  defp parse_float(value) do
    case Float.parse(value) do
      {float, _rest} -> float
      :error -> nil
    end
  end

  defp percent_width(nil, _scale), do: "0%"
  defp percent_width(_value, scale) when scale <= 0, do: "0%"

  defp percent_width(value, scale) do
    percent = value / scale * 100.0
    "#{min(max(percent, 0.0), 100.0)}%"
  end

  defp format_number(nil), do: "-"

  defp format_number(value) when is_integer(value), do: Integer.to_string(value)

  defp format_number(value) when is_float(value) do
    :erlang.float_to_binary(value, decimals: 2)
  end

  defp format_number(value) when is_binary(value), do: value
  defp format_number(_value), do: "-"

  defp capacity_time_key(row, index) do
    stable_time_key(
      [
        value(row, "id"),
        value(row, "forecast_id"),
        value(row, "resource_key"),
        value(row, "resource_id"),
        value(row, "metric_name")
      ],
      index
    )
  end

  defp anomaly_time_key(row, index) do
    stable_time_key([value(row, "id"), value(row, "uid"), value(row, "event_id")], index)
  end

  defp stable_time_key(candidates, index) do
    Enum.find_value(candidates, &observability_id_fragment/1) || Integer.to_string(index)
  end

  defp observability_id_fragment(value) when value in [nil, ""], do: nil

  defp observability_id_fragment(value) do
    case value |> to_string() |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-") |> String.trim("-") do
      "" -> nil
      fragment -> fragment
    end
  end

  defp stat_tone_class("warning"), do: "text-warning"
  defp stat_tone_class("error"), do: "text-error"
  defp stat_tone_class("info"), do: "text-info"
  defp stat_tone_class(_tone), do: "text-sr-ink"

  defp status_badge_variant(status) when status in ["at_risk", "exhaustion_projected"], do: "error"
  defp status_badge_variant("projected"), do: "warning"
  defp status_badge_variant("skipped"), do: "ghost"
  defp status_badge_variant(_status), do: "outline"

  defp severity_badge_variant(severity) when severity in ["Critical", "critical", "Fatal", "fatal"], do: "error"

  defp severity_badge_variant(severity) when severity in ["High", "high", "Warning", "warning"], do: "warning"

  defp severity_badge_variant(severity) when severity in ["Medium", "medium", "Info", "info"], do: "info"

  defp severity_badge_variant(_severity), do: "ghost"
end
