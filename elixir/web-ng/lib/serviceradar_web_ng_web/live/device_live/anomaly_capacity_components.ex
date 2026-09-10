defmodule ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityComponents do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.AnomalySeriesKey

  @detail_chart_focus_side_seconds 2 * 60 * 60

  attr :overview, :map, required: true
  attr :anomaly_page, :integer, default: 1
  attr :detail, :map, default: nil
  attr :device_uid, :string, default: nil
  attr :device_display_name, :string, default: nil
  attr :metric_sections, :list, default: []
  attr :anomaly_filters, :map, default: %{}
  attr :timezone, :string, required: true

  def anomaly_capacity_section(assigns) do
    assigns =
      assign(
        assigns,
        :anomaly_pagination,
        anomaly_pagination(
          assigns.overview.anomaly_rows,
          assigns.anomaly_page,
          Map.get(assigns.overview, :anomaly_pagination, %{}),
          assigns.anomaly_filters
        )
      )

    ~H"""
    <div>
      <section class="rounded-lg border border-sr-line bg-sr-surface">
        <div class="flex flex-wrap items-start justify-between gap-3 border-b border-sr-line px-5 py-4">
          <div>
            <h2 class="text-base font-semibold">Anomaly &amp; Capacity</h2>
            <p class="text-xs text-sr-muted">
              Device-scoped anomaly status, recent findings, and forecast runway.
            </p>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <.ui_button
              :if={@overview.anomaly_query}
              navigate={observability_href(@overview.anomaly_query)}
              size="xs"
              variant="neutral"
            >
              Open findings
            </.ui_button>
            <.ui_button navigate="/observability/health" size="xs" variant="ghost">
              Fleet health
            </.ui_button>
          </div>
        </div>

        <div class="space-y-5 p-5">
          <div
            :if={@overview.status == :error}
            class="rounded-lg border border-warning/30 bg-warning/10 p-3 text-sm text-warning"
          >
            <div class="font-semibold">Some observability queries failed.</div>
            <div :if={@overview.anomaly_error} class="mt-1">{@overview.anomaly_error}</div>
            <div :if={@overview.capacity_error} class="mt-1">{@overview.capacity_error}</div>
          </div>

          <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-6">
            <.metric_status_card :for={status <- @overview.metric_statuses} status={status} />
          </div>

          <div class="grid gap-5 xl:grid-cols-[0.95fr_1.05fr]">
            <div class="rounded-lg border border-sr-line">
              <div class="flex items-center justify-between gap-3 border-b border-sr-line px-4 py-3">
                <div>
                  <h3 class="text-sm font-semibold">Recent Anomaly Findings</h3>
                  <p class="text-xs text-sr-muted">{filter_label(@overview.anomaly_filter)}</p>
                </div>
                <.ui_badge size="sm" variant="ghost">{@anomaly_pagination.filtered_total}</.ui_badge>
              </div>

              <form
                id="anomaly-findings-controls"
                class="grid gap-2 border-b border-sr-line px-4 py-3 sm:grid-cols-3"
                phx-change="anomaly_findings_filter"
              >
                <label class="flex flex-col gap-1.5">
                  <span class="flex items-center justify-between gap-2 py-0 text-xs text-sr-muted">
                    Severity
                  </span>
                  <select
                    name="anomaly_filters[severity]"
                    class={ui_field_class(size: "sm", class: "w-full")}
                  >
                    <option value="all" selected={filter_value(@anomaly_filters, "severity") == "all"}>
                      All
                    </option>
                    <option
                      value="critical"
                      selected={filter_value(@anomaly_filters, "severity") == "critical"}
                    >
                      Critical
                    </option>
                    <option
                      value="high"
                      selected={filter_value(@anomaly_filters, "severity") == "high"}
                    >
                      High
                    </option>
                    <option
                      value="medium"
                      selected={filter_value(@anomaly_filters, "severity") == "medium"}
                    >
                      Medium
                    </option>
                    <option value="low" selected={filter_value(@anomaly_filters, "severity") == "low"}>
                      Low
                    </option>
                  </select>
                </label>
                <label class="flex flex-col gap-1.5">
                  <span class="flex items-center justify-between gap-2 py-0 text-xs text-sr-muted">
                    Status
                  </span>
                  <select
                    name="anomaly_filters[status]"
                    class={ui_field_class(size: "sm", class: "w-full")}
                  >
                    <option value="all" selected={filter_value(@anomaly_filters, "status") == "all"}>
                      All
                    </option>
                    <option value="open" selected={filter_value(@anomaly_filters, "status") == "open"}>
                      Open
                    </option>
                    <option
                      value="pending"
                      selected={filter_value(@anomaly_filters, "status") == "pending"}
                    >
                      Pending
                    </option>
                    <option
                      value="cleared"
                      selected={filter_value(@anomaly_filters, "status") == "cleared"}
                    >
                      Cleared
                    </option>
                  </select>
                </label>
                <label class="flex flex-col gap-1.5">
                  <span class="flex items-center justify-between gap-2 py-0 text-xs text-sr-muted">
                    Sort
                  </span>
                  <select
                    name="anomaly_filters[sort]"
                    class={ui_field_class(size: "sm", class: "w-full")}
                  >
                    <option
                      value="newest"
                      selected={filter_value(@anomaly_filters, "sort") == "newest"}
                    >
                      Newest
                    </option>
                    <option
                      value="oldest"
                      selected={filter_value(@anomaly_filters, "sort") == "oldest"}
                    >
                      Oldest
                    </option>
                    <option
                      value="severity"
                      selected={filter_value(@anomaly_filters, "sort") == "severity"}
                    >
                      Severity
                    </option>
                  </select>
                </label>
              </form>

              <div class="divide-y divide-sr-line">
                <div
                  :if={@anomaly_pagination.filtered_total == 0}
                  class="p-4 text-sm text-sr-muted"
                >
                  No anomaly findings found for this device in the last 7 days.
                </div>
                <button
                  :for={{row, index} <- @anomaly_pagination.rows}
                  type="button"
                  class="block w-full min-w-0 px-4 py-3 text-left hover:bg-sr-subtle/60 focus:bg-sr-subtle/60 focus:outline-none"
                  phx-click="open_anomaly_capacity_detail"
                  phx-value-kind={detail_kind_for_row(row)}
                  phx-value-index={index}
                >
                  <div class="flex items-start justify-between gap-3">
                    <div class="min-w-0">
                      <div class="max-w-full break-words text-sm font-medium [overflow-wrap:anywhere]">
                        {finding_title(row)}
                      </div>
                      <div
                        :if={finding_reason(row)}
                        class="mt-1 line-clamp-2 text-xs text-sr-muted"
                        title={finding_reason(row)}
                      >
                        {finding_reason(row)}
                      </div>
                      <div class="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-xs text-sr-muted">
                        <span title={finding_identity_title(row)}>
                          {finding_metric_name(row) || metric_class_label(row)}
                        </span>
                        <span :if={interface_label(row)} title={interface_label(row)}>
                          {interface_label(row)}
                        </span>
                        <span :if={anomaly_value_label(row)}>{anomaly_value_label(row)}</span>
                        <span :if={anomaly_score_label(row)}>{anomaly_score_label(row)}</span>
                        <span :if={finding_state_label(row)}>{finding_state_label(row)}</span>
                        <span :if={related_finding_label(row)}>{related_finding_label(row)}</span>
                        <span
                          :if={source_device_label(row, @device_uid, @device_display_name)}
                          title={source_device_title(row, @device_uid, @device_display_name)}
                        >
                          {source_device_label(row, @device_uid, @device_display_name)}
                        </span>
                        <.user_time
                          id={timestamp_row_id("device-anomaly", row, index)}
                          value={parse_timestamp(value(row, "time"))}
                          timezone={@timezone}
                          style={:compact}
                          fallback="n/a"
                        />
                      </div>
                    </div>
                    <.ui_badge
                      size="sm"
                      variant={severity_badge_variant(value(row, "severity"))}
                      class="shrink-0"
                    >
                      {value(row, "severity") || "Unknown"}
                    </.ui_badge>
                  </div>
                </button>
              </div>
              <.anomaly_cursor_pager
                page={@anomaly_pagination.page}
                range_start={@anomaly_pagination.range_start}
                range_end={@anomaly_pagination.range_end}
                pagination={Map.get(@overview, :anomaly_pagination, %{})}
              />
            </div>

            <div class="rounded-lg border border-sr-line">
              <div class="flex items-center justify-between gap-3 border-b border-sr-line px-4 py-3">
                <div>
                  <h3 class="text-sm font-semibold">Capacity Runway</h3>
                  <p class="text-xs text-sr-muted">
                    {filter_label(@overview.capacity_filter)}
                  </p>
                </div>
                <.ui_button
                  :if={@overview.capacity_query}
                  navigate={observability_href(@overview.capacity_query)}
                  size="xs"
                  variant="neutral"
                >
                  Open SRQL
                </.ui_button>
              </div>

              <div class="sr-ui-table-shell">
                <table class={ui_table_class(size: "sm")}>
                  <thead>
                    <tr>
                      <th>Resource</th>
                      <th>Metric</th>
                      <th>Status</th>
                      <th>Projected</th>
                      <th>Exhaustion</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :if={projected_capacity_rows(@overview.capacity_rows) == []}>
                      <td colspan="5" class="py-8 text-center text-sr-muted">
                        No projected capacity forecasts found for this device yet.
                      </td>
                    </tr>
                    <tr
                      :for={{row, index} <- projected_capacity_rows(@overview.capacity_rows)}
                      class="cursor-pointer hover:bg-sr-subtle/60"
                      phx-click="open_anomaly_capacity_detail"
                      phx-value-kind="capacity"
                      phx-value-index={index}
                    >
                      <td
                        class="max-w-48 truncate"
                        title={resource_title(row, @device_uid, @device_display_name)}
                      >
                        {resource_label(row, @device_uid, @device_display_name)}
                      </td>
                      <td title={capacity_metric_title(row)}>
                        <div class="whitespace-nowrap">{capacity_metric_label(row)}</div>
                        <div :if={capacity_threshold_label(row)} class="text-xs text-sr-muted">
                          threshold {capacity_threshold_label(row)}
                        </div>
                      </td>
                      <td>
                        <.ui_badge size="sm" variant={status_badge_variant(value(row, "status"))}>
                          {value(row, "status") || "unknown"}
                        </.ui_badge>
                      </td>
                      <td>
                        <div class="whitespace-nowrap">
                          {format_metric_value(value(row, "projected_value"), row)}
                        </div>
                        <div class="text-xs text-sr-muted">
                          now {format_metric_value(value(row, "current_value"), row)}
                        </div>
                        <div :if={capacity_headroom_label(row)} class="text-xs text-sr-muted">
                          headroom {capacity_headroom_label(row)}
                        </div>
                      </td>
                      <td class="whitespace-nowrap">
                        <.user_time
                          id={timestamp_row_id("device-capacity-exhaustion", row, index)}
                          value={parse_timestamp(value(row, "projected_exhaustion_at"))}
                          timezone={@timezone}
                          style={:compact}
                          fallback="n/a"
                        />
                        <div :if={capacity_horizon_label(row)} class="text-xs text-sr-muted">
                          horizon {capacity_horizon_label(row)}
                        </div>
                        <div :if={value(row, "confidence")} class="text-xs text-sr-muted">
                          confidence {format_percent(value(row, "confidence"))}
                        </div>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        </div>
      </section>

      <.anomaly_capacity_detail_modal
        detail={@detail}
        device_uid={@device_uid}
        device_display_name={@device_display_name}
        metric_sections={@metric_sections}
        timezone={@timezone}
      />
    </div>
    """
  end

  attr :status, :map, required: true

  defp metric_status_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-sr-line bg-sr-surface p-3">
      <div class="text-xs font-semibold uppercase tracking-normal text-sr-muted">
        {@status.label}
      </div>
      <div class="mt-2 flex items-center justify-between gap-2">
        <.ui_badge size="sm" variant={anomaly_badge_variant(@status.status)}>
          {@status.status}
        </.ui_badge>
        <span class="text-xs text-sr-muted">{@status.count}</span>
      </div>
    </div>
    """
  end

  attr :page, :integer, default: 1
  attr :range_start, :integer, default: 0
  attr :range_end, :integer, default: 0
  attr :pagination, :map, default: %{}

  defp anomaly_cursor_pager(assigns) do
    assigns =
      assigns
      |> assign(:has_prev, cursor_present?(Map.get(assigns.pagination, "prev_cursor")))
      |> assign(:has_next, cursor_present?(Map.get(assigns.pagination, "next_cursor")))
      |> assign(:page_count, integer_value(Map.get(assigns.pagination, "page_count")))

    ~H"""
    <div
      :if={@has_prev or @has_next or @range_end > 0}
      class="flex flex-col gap-2 border-t border-sr-line px-4 py-3 text-xs sm:flex-row sm:items-center sm:justify-between"
    >
      <span class="text-sr-muted">
        Showing {@range_start}–{@range_end} on this episode page
      </span>
      <div class={ui_join_class()}>
        <.ui_button
          type="button"
          phx-click="anomaly_findings_prev_page"
          disabled={not @has_prev}
          size="xs"
          variant="ghost"
        >
          Prev
        </.ui_button>
        <span class="pointer-events-none inline-flex min-h-7 items-center justify-center px-2 text-xs font-semibold text-sr-muted">
          <%= if is_integer(@page_count) do %>
            Page {@page} / {@page_count}
          <% else %>
            Page {@page}
          <% end %>
        </span>
        <.ui_button
          type="button"
          phx-click="anomaly_findings_next_page"
          disabled={not @has_next}
          size="xs"
          variant="ghost"
        >
          Next
        </.ui_button>
      </div>
    </div>
    """
  end

  defp cursor_present?(value), do: present?(value)

  attr :detail, :map, default: nil
  attr :device_uid, :string, default: nil
  attr :device_display_name, :string, default: nil
  attr :metric_sections, :list, default: []
  attr :timezone, :string, required: true

  defp anomaly_capacity_detail_modal(%{detail: nil} = assigns) do
    ~H"""
    """
  end

  defp anomaly_capacity_detail_modal(assigns) do
    assigns =
      assigns
      |> assign(:detail_chart_sections, detail_chart_sections(assigns.detail, assigns.metric_sections))
      |> assign(:detail_chart_focus, detail_chart_focus(assigns.detail))
      |> assign(:lifecycle_notice, detail_lifecycle_notice(assigns.detail))

    ~H"""
    <dialog
      id="anomaly-capacity-detail-modal"
      class="sr-ui-modal sr-ui-modal-open"
      phx-hook="DialogTopLayer"
      data-cancel="close_anomaly_capacity_detail"
    >
      <div class="sr-ui-modal-box sr-ui-modal-box-xl">
        <div class="flex items-start justify-between gap-4">
          <div class="min-w-0">
            <div class="text-xs font-semibold uppercase tracking-normal text-sr-muted">
              {detail_kind_label(@detail.kind)}
            </div>
            <h3 class="mt-1 break-words text-lg font-semibold [overflow-wrap:anywhere]">
              {detail_title(@detail, @device_uid, @device_display_name)}
            </h3>
          </div>
          <.ui_button
            type="button"
            phx-click="close_anomaly_capacity_detail"
            size="sm"
            variant="ghost"
          >
            Close
          </.ui_button>
        </div>

        <div class="mt-5 grid gap-3 sm:grid-cols-2">
          <.detail_item label="Finding UID" value={detail_finding_uid(@detail)} />
          <.detail_item label="Metric" value={detail_metric(@detail)} />
          <.detail_item label="Severity" value={detail_severity(@detail)} />
          <.detail_item label="Lifecycle" value={detail_lifecycle(@detail)} />
          <.detail_item label="Interface" value={detail_interface(@detail)} />
          <.detail_item label="Value / Score" value={detail_value_score(@detail)} />
          <.detail_item
            label="Resource"
            value={detail_resource(@detail, @device_uid, @device_display_name)}
          />
          <.detail_item
            label="Series"
            value={detail_series(@detail)}
            title={detail_series_title(@detail)}
          />
          <.detail_time_item
            id="anomaly-capacity-detail-observed-time"
            label={detail_time_label(@detail)}
            value={detail_time(@detail)}
            timezone={@timezone}
          />
          <.detail_time_item
            id="anomaly-capacity-detail-projected-crossing"
            label="Projected crossing"
            value={detail_projected_crossing(@detail)}
            timezone={@timezone}
          />
          <.detail_item label="Confidence" value={detail_confidence(@detail)} />
        </div>

        <div
          :if={@lifecycle_notice}
          class="mt-4 rounded-xl border border-success/30 bg-success/10 p-4"
        >
          <div class="flex items-start gap-3">
            <.icon name="hero-check-circle" class="mt-0.5 size-5 shrink-0 text-success" />
            <div class="min-w-0">
              <p class="text-sm font-semibold">{@lifecycle_notice.title}</p>
              <p class="mt-1 text-sm text-sr-ink/75">{@lifecycle_notice.body}</p>
              <.link
                href="https://docs.serviceradar.cloud/docs/anomaly-detection#episode-lifecycle"
                target="_blank"
                rel="noopener noreferrer"
                class="mt-2 inline-flex text-xs font-semibold text-sr-brand hover:underline"
              >
                How anomaly episode lifecycle works
                <.icon name="hero-arrow-top-right-on-square" class="ml-1 size-3.5" />
              </.link>
            </div>
          </div>
        </div>

        <div :if={detail_related_query(@detail)} class="mt-3 rounded-lg border border-sr-line p-3">
          <div class="text-xs font-semibold uppercase tracking-normal text-sr-muted">
            Related finding
          </div>
          <div class="mt-1 flex flex-wrap items-center gap-2 text-sm">
            <span>{detail_related_label(@detail)}</span>
            <.ui_button
              navigate={observability_href(detail_related_query(@detail))}
              size="xs"
              variant="neutral"
            >
              Open trigger
            </.ui_button>
          </div>
        </div>

        <div :if={detail_reason(@detail)} class="mt-5 rounded-lg bg-sr-subtle p-3">
          <div class="text-xs font-semibold uppercase tracking-normal text-sr-muted">
            {detail_reason_label(@detail)}
          </div>
          <p class="mt-1 whitespace-pre-wrap break-words text-sm [overflow-wrap:anywhere]">
            {detail_reason(@detail)}
          </p>
        </div>

        <div :if={detail_opening_reason(@detail)} class="mt-3 rounded-lg border border-sr-line p-3">
          <div class="text-xs font-semibold uppercase tracking-normal text-sr-muted">
            Original detection trigger
          </div>
          <p class="mt-1 whitespace-pre-wrap break-words text-sm [overflow-wrap:anywhere]">
            {detail_opening_reason(@detail)}
          </p>
        </div>

        <div :if={@detail_chart_sections != []} class="mt-5 space-y-3">
          <div>
            <div class="text-xs font-semibold uppercase tracking-normal text-sr-muted">
              Metric context
            </div>
            <p :if={@detail_chart_focus} class="text-xs text-sr-muted">
              {detail_marker_description(@detail)}
            </p>
          </div>
          <div
            :for={{section, section_index} <- Enum.with_index(@detail_chart_sections)}
            class="rounded-lg border border-sr-line p-3"
          >
            <div class="mb-2 flex items-center gap-2">
              <span class="text-sm font-semibold">{section.title}</span>
              <span class="text-xs text-sr-muted">{section.subtitle}</span>
              <span
                :if={Map.get(section, :subtitle_time)}
                class="text-xs text-sr-muted"
              >
                · centered at
                <.user_time
                  id={"anomaly-capacity-detail-#{section.key}-#{section_index}-subtitle-time"}
                  value={Map.get(section, :subtitle_time)}
                  timezone={@timezone}
                  style={:compact}
                  fallback=""
                />
              </span>
            </div>
            <%= for {panel, idx} <- Enum.with_index(section.panels) do %>
              <.live_component
                module={panel.plugin}
                id={"anomaly-capacity-detail-#{section.key}-#{panel.id}-#{idx}"}
                title={Map.get(panel, :title) || section.title}
                panel_assigns={detail_panel_assigns(panel, @detail_chart_focus, @timezone)}
              />
            <% end %>
          </div>
        </div>
      </div>
      <form method="dialog" class="sr-ui-modal-backdrop">
        <button phx-click="close_anomaly_capacity_detail">close</button>
      </form>
    </dialog>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :title, :any, default: nil

  defp detail_item(assigns) do
    assigns =
      assigns
      |> assign(:display_value, display_detail_value(assigns.value))
      |> assign(:title_value, display_detail_value(assigns.title || assigns.value))

    ~H"""
    <div class="rounded-lg border border-sr-line p-3">
      <div class="text-xs font-semibold uppercase tracking-normal text-sr-muted">
        {@label}
      </div>
      <div class="mt-1 break-words text-sm [overflow-wrap:anywhere]" title={@title_value}>
        {@display_value}
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :timezone, :string, required: true

  defp detail_time_item(assigns) do
    ~H"""
    <div class="rounded-lg border border-sr-line p-3">
      <div class="text-xs font-semibold uppercase tracking-normal text-sr-muted">
        {@label}
      </div>
      <.user_time
        id={@id}
        value={@value}
        timezone={@timezone}
        style={:compact}
        fallback="n/a"
        class="mt-1 break-words text-sm [overflow-wrap:anywhere]"
      />
    </div>
    """
  end

  defp display_detail_value(value), do: if(blank?(value), do: "n/a", else: value)

  defp detail_chart_sections(%{row: row}, sections) when is_list(sections) do
    key = detail_metric_section_key(row)

    sections
    |> Enum.filter(fn section ->
      is_map(section) and Map.get(section, :key) == key and is_list(Map.get(section, :panels))
    end)
    |> Enum.map(fn section ->
      %{section | panels: Enum.take(Map.get(section, :panels, []), 2)}
    end)
  end

  defp detail_chart_sections(_detail, _sections), do: []

  defp detail_metric_section_key(row) do
    text =
      [
        metric_class(row),
        finding_metric_name(row),
        finding_title(row),
        finding_reason(row)
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
      |> normalize_text()

    cond do
      String.contains?(text, "cpu") ->
        "cpu"

      String.contains?(text, "memory") or String.contains?(text, "mem") ->
        "memory"

      String.contains?(text, "disk") or String.contains?(text, "filesystem") ->
        "disk"

      String.contains?(text, "interface") or String.contains?(text, "if_") or String.contains?(text, "snmp") ->
        "interfaces"

      true ->
        nil
    end
  end

  defp detail_panel_assigns(panel, chart_focus, timezone) do
    panel.assigns
    |> Map.put(:compact, true)
    |> Map.put(:timezone, timezone)
    |> maybe_put_detail_chart_focus(chart_focus)
  end

  defp maybe_put_detail_chart_focus(assigns, nil), do: assigns
  defp maybe_put_detail_chart_focus(assigns, focus), do: Map.put(assigns, :chart_focus, focus)

  defp detail_chart_focus(%{kind: kind, row: row}) when is_map(row) do
    timestamp =
      case kind do
        "capacity" -> first_present(row, [["forecasted_at"], ["time"], ["timestamp"], ["window_ended_at"]])
        _ -> first_present(row, [["time"], ["timestamp"], ["window_ended_at"], ["forecasted_at"]])
      end

    case timestamp do
      nil ->
        nil

      timestamp ->
        %{
          timestamp: timestamp,
          label: detail_marker_label(%{kind: kind, row: row}),
          severity: value(row, "effective_severity") || value(row, "severity") || value(row, "status"),
          series: first_present(row, [["series"], ["series_key"], ["metric_name"], ["resource_key"]]),
          series_key: value(row, "series_key"),
          metric_name: value(row, "metric_name"),
          resource_key: value(row, "resource_key"),
          before_seconds: @detail_chart_focus_side_seconds,
          after_seconds: @detail_chart_focus_side_seconds
        }
    end
  end

  defp detail_chart_focus(_detail), do: nil

  defp observability_href(query) do
    "/observability/events?" <> URI.encode_query(%{q: query})
  end

  defp filter_label(nil), do: "No device identity filter selected"

  defp filter_label(%{field: field, label: label, value: value}) do
    "#{label} #{field}=#{value}"
  end

  defp filter_label(_), do: "Device identity fallback"

  defp anomaly_pagination(rows, page, pagination, filters) when is_list(rows) do
    paged_rows = actionable_anomaly_rows(rows, filters)
    local_total = length(paged_rows)

    %{
      rows: paged_rows,
      page: page,
      page_count: integer_value(Map.get(pagination, "page_count")),
      filtered_total: local_total,
      range_start: if(local_total == 0, do: 0, else: 1),
      range_end: local_total
    }
  end

  defp anomaly_pagination(_rows, page, _pagination, _filters) do
    %{rows: [], page: page, page_count: nil, filtered_total: 0, range_start: 0, range_end: 0}
  end

  defp actionable_anomaly_rows(rows, filters) do
    sort = anomaly_sort_mode(filters)

    rows
    |> Enum.with_index()
    |> Enum.filter(fn {row, _index} -> actionable_anomaly_row?(row) end)
    |> Enum.sort_by(fn {row, index} -> anomaly_display_key(row, index, sort) end)
  end

  # The displayed findings follow the user-selected Sort control (Newest,
  # Oldest, Severity). Sorting by finding state first would float e.g. a
  # confirmed finding above a newer cleared one even with Sort=Newest.
  defp anomaly_display_key(row, index, :oldest) do
    {capacity_notice_last(row), timestamp_sort_asc(value(row, "time")), index}
  end

  defp anomaly_display_key(row, index, :severity) do
    {capacity_notice_last(row), severity_rank(row), timestamp_sort(value(row, "time")), index}
  end

  defp anomaly_display_key(row, index, _newest) do
    {capacity_notice_last(row), timestamp_sort(value(row, "time")), index}
  end

  defp capacity_notice_last(row) do
    if capacity_notice?(row), do: 1, else: 0
  end

  defp anomaly_sort_mode(filters) when is_map(filters) do
    sort = Map.get(filters, "sort") || Map.get(filters, :sort)

    case normalize_text(sort) do
      "oldest" -> :oldest
      "severity" -> :severity
      _ -> :newest
    end
  end

  defp anomaly_sort_mode(_filters), do: :newest

  defp severity_rank(row) do
    case normalize_text(value(row, "severity")) do
      "critical" -> 0
      "high" -> 1
      "medium" -> 2
      "warning" -> 2
      "low" -> 3
      _ -> 4
    end
  end

  defp actionable_anomaly_row?(row) when is_map(row) do
    capacity_notice?(row) or confirmed_or_cleared_anomaly?(row)
  end

  defp actionable_anomaly_row?(_row), do: false

  defp confirmed_or_cleared_anomaly?(row) do
    state = finding_state(row)
    status = normalize_text(value(row, "status"))
    reason = normalize_text(finding_reason(row))

    cond do
      state in ["pending", "pending_anomaly"] -> false
      String.contains?(reason, "pending confirmation") -> false
      present?(value(row, "episode_uid")) and status in ["cleared", "stale_closed"] -> true
      state in ["confirmed", "anomalous"] -> true
      status in ["active", "open", "anomaly_open"] -> true
      status in ["inactive", "cleared", "resolved"] -> String.contains?(reason, "confirmed")
      true -> false
    end
  end

  defp filter_value(filters, key) when is_map(filters) do
    atom_value =
      case key do
        "severity" -> Map.get(filters, :severity)
        "status" -> Map.get(filters, :status)
        "sort" -> Map.get(filters, :sort)
        _ -> nil
      end

    case Map.get(filters, key) || atom_value do
      value when is_binary(value) and value != "" -> value
      _ -> "all"
    end
  end

  defp filter_value(_filters, _key), do: "all"

  defp timestamp_sort(value) do
    case parse_timestamp(value) do
      %DateTime{} = dt -> -DateTime.to_unix(dt, :microsecond)
      nil -> 0
    end
  end

  # Ascending companion for Oldest sort. Missing timestamps sort last:
  # in Erlang term order atoms sort after numbers, so nil never wins.
  defp timestamp_sort_asc(value) do
    case parse_timestamp(value) do
      %DateTime{} = dt -> DateTime.to_unix(dt, :microsecond)
      nil -> nil
    end
  end

  defp projected_capacity_rows(rows) when is_list(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reject(fn {row, _index} -> normalize_text(value(row, "status")) == "skipped" end)
    |> Enum.take(8)
  end

  defp projected_capacity_rows(_rows), do: []

  defp finding_title(row) do
    finding_info_title(row) ||
      value(row, "finding_title") ||
      nested_value(row, ["metadata", "finding_info", "title"]) ||
      nested_value(row, ["metadata", "detection_finding", "title"]) ||
      finding_reason(row) ||
      value(row, "message") ||
      "Anomaly finding"
  end

  defp detail_kind_for_row(row) do
    if capacity_notice?(row), do: "capacity_notice", else: "anomaly"
  end

  defp finding_info_title(row) do
    first_present(row, [
      ["finding_info", "title"],
      ["metadata", "finding_info", "title"],
      ["metadata", "detection_finding", "title"],
      ["raw_data", "finding_info", "title"],
      ["unmapped", "finding_info", "title"]
    ])
  end

  defp finding_reason(row) do
    reason =
      first_present(row, [
        ["metadata", "verdict", "reason"],
        ["metadata", "anomaly", "reason"],
        ["metadata", "detection_finding", "reason"],
        ["raw_data", "verdict", "reason"],
        ["raw_data", "reason"],
        ["unmapped", "reason"],
        ["message"]
      ])

    if normalize_text(reason) == normalize_text(finding_info_title(row)) do
      nil
    else
      reason
    end
  end

  defp finding_state(row) do
    row
    |> first_present([
      ["state"],
      ["metadata", "service_radar", "state"],
      ["metadata", "anomaly", "state"],
      ["metadata", "detection_finding", "state"],
      ["metadata", "detection_finding", "dimensions", "state"],
      ["raw_data", "state"],
      ["unmapped", "state"]
    ])
    |> normalize_text()
  end

  defp finding_state_label(row) do
    case finding_state(row) do
      "" -> nil
      "nil" -> nil
      "null" -> nil
      "pending_anomaly" -> "pending"
      "anomalous" -> "confirmed"
      state -> String.replace(state, "_", " ")
    end
  end

  defp finding_metric_name(row) do
    first_present(row, [
      ["metric_name"],
      ["metadata", "source_identity", "metric_name"],
      ["metadata", "service_radar", "metric_name"],
      ["metadata", "anomaly", "metric_name"],
      ["metadata", "detection_finding", "metric_name"],
      ["raw_data", "metric_name"],
      ["unmapped", "metric_name"]
    ])
  end

  defp finding_identity_title(row) do
    [
      finding_metric_name(row),
      interface_label(row),
      decoded_series_display(row) || series_key(row),
      source_device_uid(row)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" | ")
  end

  defp interface_label(row) do
    label =
      source_identity_tag(row, "label") ||
        source_identity_tag(row, "if_name") ||
        source_identity_tag(row, "interface_name") ||
        source_identity_tag(row, "name") ||
        decoded_series_tag(row, "label") ||
        decoded_series_tag(row, "if_name") ||
        decoded_series_tag(row, "interface_name")

    interface_uid =
      first_present(row, [
        ["interface_uid"],
        ["metadata", "source_identity", "interface_uid"],
        ["metadata", "service_radar", "interface_uid"],
        ["raw_data", "interface_uid"],
        ["unmapped", "interface_uid"]
      ])

    if_index =
      first_present(row, [
        ["if_index"],
        ["metadata", "source_identity", "if_index"],
        ["metadata", "service_radar", "if_index"],
        ["raw_data", "if_index"],
        ["unmapped", "if_index"]
      ]) || decoded_series_component(row, "if_index")

    cond do
      present?(label) and present?(if_index) -> "#{label} / ifIndex #{if_index}"
      present?(interface_uid) and present?(if_index) -> "#{interface_uid} / ifIndex #{if_index}"
      present?(label) -> label
      present?(interface_uid) -> interface_uid
      present?(if_index) -> "ifIndex #{if_index}"
      true -> nil
    end
  end

  defp anomaly_value_label(row) do
    case anomaly_value(row) do
      nil -> nil
      value -> "value #{format_number(value)}"
    end
  end

  defp anomaly_score_label(row) do
    case anomaly_score(row) do
      nil -> nil
      score -> "score #{format_number(score)}"
    end
  end

  defp related_finding_label(row) do
    if capacity_notice?(row) and cleared_capacity_notice?(row) and present?(related_finding_uid(row)) do
      "clears #{short_uid(related_finding_uid(row))}"
    end
  end

  defp anomaly_value(row) do
    first_present(row, [
      ["anomaly_value"],
      ["metric_value"],
      ["metadata", "service_radar", "metric_value"],
      ["metadata", "anomaly", "value"],
      ["metadata", "detection_finding", "value"],
      ["raw_data", "anomaly", "value"],
      ["unmapped", "anomaly_value"]
    ])
  end

  defp anomaly_score(row) do
    first_present(row, [
      ["score"],
      ["anomaly_score"],
      ["metadata", "anomaly", "score"],
      ["metadata", "detection_finding", "score"],
      ["raw_data", "anomaly", "score"],
      ["unmapped", "anomaly_score"]
    ])
  end

  defp series_key(row) do
    first_present(row, [
      ["series_key"],
      ["metadata", "source_identity", "series_key"],
      ["metadata", "service_radar", "series_key"],
      ["raw_data", "series_key"],
      ["unmapped", "series_key"]
    ])
  end

  defp decoded_series_display(row), do: row |> series_key() |> AnomalySeriesKey.display()

  defp decoded_series_tag(row, key) do
    row
    |> series_key()
    |> AnomalySeriesKey.decode()
    |> AnomalySeriesKey.tag(key)
  end

  defp decoded_series_component(row, key) do
    row
    |> series_key()
    |> AnomalySeriesKey.decode()
    |> AnomalySeriesKey.component(key)
  end

  defp source_identity_tag(row, key) do
    first_present(row, [
      ["source_identity", "tags", key],
      ["metadata", "source_identity", "tags", key],
      ["metadata", "service_radar", "source_identity", "tags", key],
      ["metadata", "anomaly", "source_identity", "tags", key],
      ["metadata", "detection_finding", "source_identity", "tags", key],
      ["raw_data", "source_identity", "tags", key],
      ["unmapped", "source_identity", "tags", key]
    ])
  end

  defp series_resource_label(row) do
    mount_point = source_identity_tag(row, "mount_point") || decoded_series_tag(row, "mount_point")
    core_id = source_identity_tag(row, "core_id") || decoded_series_tag(row, "core_id")
    label = source_identity_tag(row, "label") || decoded_series_tag(row, "label")

    cond do
      present?(mount_point) ->
        "mount #{mount_point}"

      present?(label) and present?(core_id) ->
        "#{label} (core #{core_id})"

      present?(label) ->
        label

      present?(core_id) ->
        "core #{core_id}"

      true ->
        nil
    end
  end

  defp source_device_uid(row) do
    first_present(row, [
      ["source_device_uid"],
      ["device_uid"],
      ["metadata", "service_radar", "device_uid"],
      ["metadata", "source_identity", "device_uid"],
      ["raw_data", "device_uid"],
      ["unmapped", "device_uid"]
    ])
  end

  defp related_finding_uid(row) do
    first_present(row, [
      ["related_finding_uid"],
      ["clears_finding_uid"],
      ["trigger_finding_uid"],
      ["metadata", "capacity_forecast", "clears_finding_uid"],
      ["unmapped", "capacity_forecast", "clears_finding_uid"],
      ["metadata", "finding_info", "group_uid"],
      ["metadata", "finding_info", "uid"],
      ["finding_uid"]
    ])
  end

  defp source_device_label(row, device_uid, device_display_name) do
    row
    |> source_device_uid()
    |> friendly_device_label(device_uid, device_display_name)
  end

  defp source_device_title(row, device_uid, device_display_name) do
    row
    |> source_device_uid()
    |> friendly_device_title(device_uid, device_display_name)
  end

  defp metric_class_label(row) do
    if capacity_notice?(row) do
      "Capacity"
    else
      row
      |> metric_class()
      |> case do
        "cpu" -> "CPU"
        "memory" -> "Memory"
        "disk" -> "Disk"
        "interface" -> "Interfaces"
        "other" -> "Other signals"
        "red" -> "Other signals"
        "snmp" -> "SNMP"
        other -> other
      end
    end
  end

  defp capacity_notice?(row) do
    text =
      [
        finding_info_title(row),
        value(row, "finding_title"),
        value(row, "message"),
        first_present(row, [["reason"], ["metadata", "service_radar", "reason"], ["metadata", "anomaly", "reason"]]),
        finding_metric_name(row)
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
      |> normalize_text()

    String.contains?(text, "capacity forecast")
  end

  defp cleared_capacity_notice?(row) do
    status = normalize_text(value(row, "status"))
    text = normalize_text(finding_title(row) || finding_reason(row))

    status in ["inactive", "cleared", "resolved", "closed"] or String.contains?(text, "cleared")
  end

  defp metric_class(row) do
    row
    |> first_present([
      ["metric_class"],
      ["metadata", "service_radar", "metric_class"],
      ["metadata", "anomaly", "metric_class"],
      ["metadata", "detection_finding", "metric_class"],
      ["unmapped", "metric_class"],
      ["raw_data", "metric_class"]
    ])
    |> normalize_text()
    |> case do
      "cpu_metrics" -> "cpu"
      "memory_metrics" -> "memory"
      "disk_metrics" -> "disk"
      "interface_metrics" -> "interface"
      "" -> "other"
      "red" -> "other"
      class -> class
    end
  end

  defp resource_label(row, device_uid, device_display_name) do
    value(row, "resource_label") ||
      friendly_device_label(value(row, "resource_id"), device_uid, device_display_name) ||
      value(row, "resource_key") ||
      value(row, "resource_id") ||
      "resource"
  end

  defp resource_title(row, device_uid, device_display_name) do
    [
      value(row, "resource_label"),
      friendly_device_title(value(row, "resource_id"), device_uid, device_display_name),
      value(row, "resource_key")
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" | ")
  end

  defp capacity_metric_label(row) do
    value(row, "metric_name") || value(row, "metric_class") || "metric"
  end

  defp capacity_metric_title(row) do
    [
      value(row, "metric_name"),
      value(row, "metric_class"),
      capacity_unit(row)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" | ")
  end

  defp capacity_threshold_label(row) do
    case value(row, "exhaustion_threshold") do
      nil -> nil
      threshold -> format_metric_value(threshold, row)
    end
  end

  defp capacity_headroom_label(row) do
    with threshold when not is_nil(threshold) <- numeric_value(value(row, "exhaustion_threshold")),
         current when not is_nil(current) <- numeric_value(value(row, "current_value")) do
      format_metric_value(threshold - current, row)
    else
      _ -> nil
    end
  end

  defp capacity_horizon_label(row) do
    case numeric_value(value(row, "horizon_seconds")) do
      nil -> nil
      seconds when seconds >= 86_400 -> "#{Float.round(seconds / 86_400, 1)}d"
      seconds when seconds >= 3_600 -> "#{Float.round(seconds / 3_600, 1)}h"
      seconds -> "#{round(seconds)}s"
    end
  end

  defp format_metric_value(value, row) do
    unit = capacity_unit(row)
    formatted = format_number(value)

    cond do
      formatted == "n/a" -> formatted
      unit == "%" -> "#{formatted}%"
      unit == "" -> formatted
      true -> "#{formatted} #{unit}"
    end
  end

  defp capacity_unit(row) do
    explicit =
      first_present(row, [
        ["unit"],
        ["metadata", "unit"],
        ["metadata", "capacity", "unit"],
        ["raw_data", "unit"],
        ["unmapped", "unit"]
      ])

    metric = normalize_text(value(row, "metric_name") || value(row, "metric_class"))

    cond do
      present?(explicit) -> to_string(explicit)
      String.contains?(metric, "percent") or String.contains?(metric, "_pct") -> "%"
      String.contains?(metric, "bytes") -> "bytes"
      true -> ""
    end
  end

  defp detail_kind_label("capacity"), do: "Capacity forecast"
  defp detail_kind_label("capacity_notice"), do: "Capacity notice"
  defp detail_kind_label(_), do: "Anomaly finding"

  defp detail_title(detail, device_uid, device_display_name)

  defp detail_title(%{kind: "capacity", row: row}, device_uid, device_display_name) do
    resource_label(row, device_uid, device_display_name)
  end

  defp detail_title(%{kind: "capacity_notice", row: row}, _device_uid, _device_display_name) do
    finding_title(row)
  end

  defp detail_title(%{kind: "anomaly", row: row}, _device_uid, _device_display_name) do
    if resolved_anomaly?(row) do
      "Resolved: #{finding_metric_name(row) || metric_class_label(row) || "anomaly episode"}"
    else
      finding_title(row)
    end
  end

  defp detail_title(%{row: row}, _device_uid, _device_display_name), do: finding_title(row)
  defp detail_title(_detail, _device_uid, _device_display_name), do: "Detail"

  defp detail_metric(%{kind: "capacity", row: row}), do: capacity_metric_title(row)
  defp detail_metric(%{kind: "capacity_notice", row: row}), do: finding_metric_name(row) || metric_class_label(row)
  defp detail_metric(%{row: row}), do: finding_metric_name(row) || metric_class_label(row)
  defp detail_metric(_), do: nil

  defp detail_finding_uid(%{row: row}) do
    first_present(row, [
      ["finding_uid"],
      ["metadata", "finding_info", "uid"],
      ["metadata", "security_signal", "finding_uid"],
      ["id"]
    ])
  end

  defp detail_finding_uid(_), do: nil

  defp detail_severity(%{kind: "capacity"}), do: nil

  defp detail_severity(%{row: row}) do
    value(row, "effective_severity") || value(row, "severity")
  end

  defp detail_severity(_), do: nil

  defp detail_lifecycle(%{kind: "capacity", row: row}), do: value(row, "status")

  defp detail_lifecycle(%{row: row}) do
    finding_state_label(row) || value(row, "status") || value(row, "disposition")
  end

  defp detail_lifecycle(_), do: nil

  defp detail_interface(%{row: row}), do: interface_label(row)
  defp detail_interface(_), do: nil

  defp detail_value_score(%{kind: "capacity", row: row}) do
    [
      "current #{format_metric_value(value(row, "current_value"), row)}",
      "projected #{format_metric_value(value(row, "projected_value"), row)}",
      capacity_threshold_label(row) && "threshold #{capacity_threshold_label(row)}",
      capacity_headroom_label(row) && "headroom #{capacity_headroom_label(row)}"
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" | ")
  end

  defp detail_value_score(%{kind: "capacity_notice", row: row}) do
    [
      anomaly_value_label(row),
      anomaly_score_label(row),
      value(row, "threshold_value") && "threshold #{format_number(value(row, "threshold_value"))}"
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" | ")
  end

  defp detail_value_score(%{row: row}) do
    [
      anomaly_value_label(row),
      anomaly_score_label(row)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" | ")
  end

  defp detail_value_score(_), do: nil

  defp detail_resource(detail, device_uid, device_display_name)

  defp detail_resource(%{kind: "capacity", row: row}, device_uid, device_display_name) do
    resource_title(row, device_uid, device_display_name)
  end

  defp detail_resource(%{kind: "capacity_notice", row: row}, device_uid, device_display_name) do
    series_resource_label(row) ||
      source_device_title(row, device_uid, device_display_name) ||
      source_device_uid(row) ||
      value(row, "resource_id") ||
      value(row, "resource_key")
  end

  defp detail_resource(%{row: row}, device_uid, device_display_name) do
    series_resource_label(row) ||
      source_device_title(row, device_uid, device_display_name) ||
      source_device_uid(row)
  end

  defp detail_resource(_detail, _device_uid, _device_display_name), do: nil

  defp detail_series(%{kind: "capacity", row: row}), do: value(row, "resource_key")

  defp detail_series(%{kind: "capacity_notice", row: row}) do
    decoded_series_display(row) || series_key(row) || value(row, "resource_key")
  end

  defp detail_series(%{row: row}), do: decoded_series_display(row) || series_key(row)
  defp detail_series(_), do: nil

  defp detail_series_title(%{kind: "capacity", row: row}), do: value(row, "resource_key")
  defp detail_series_title(%{row: row}), do: series_key(row)
  defp detail_series_title(_), do: nil

  defp detail_time_label(%{kind: "capacity"}), do: "Forecasted"
  defp detail_time_label(%{kind: "capacity_notice"}), do: "Event time"

  defp detail_time_label(%{kind: "anomaly", row: row}) do
    if resolved_anomaly?(row), do: "Resolved", else: "Observed"
  end

  defp detail_time_label(_), do: "Observed"

  defp detail_time(%{kind: "capacity", row: row}) do
    row
    |> first_present([["forecasted_at"], ["time"], ["timestamp"], ["window_ended_at"]])
    |> parse_timestamp()
  end

  defp detail_time(%{kind: "capacity_notice", row: row}) do
    row
    |> first_present([["time"], ["forecasted_at"], ["window_ended_at"]])
    |> parse_timestamp()
  end

  defp detail_time(%{kind: "anomaly", row: row}) do
    timestamp =
      if resolved_anomaly?(row) do
        first_present(row, [["window_ended_at"], ["cleared_at"], ["time"]])
      else
        value(row, "time")
      end

    parse_timestamp(timestamp)
  end

  defp detail_time(%{row: row}), do: parse_timestamp(value(row, "time"))
  defp detail_time(_), do: nil

  defp detail_projected_crossing(%{kind: "capacity", row: row}) do
    row
    |> first_present([["projected_exhaustion_at"], ["horizon_ends_at"]])
    |> parse_timestamp()
  end

  defp detail_projected_crossing(%{kind: "capacity_notice", row: row}) do
    row
    |> first_present([["projected_exhaustion_at"], ["horizon_ends_at"]])
    |> parse_timestamp()
  end

  defp detail_projected_crossing(_), do: nil

  defp detail_confidence(%{row: row}), do: value(row, "confidence") && format_percent(value(row, "confidence"))
  defp detail_confidence(_), do: nil

  defp detail_related_query(%{kind: "capacity_notice", row: row}) do
    with true <- cleared_capacity_notice?(row),
         uid when is_binary(uid) <- related_finding_uid(row) do
      ~s|in:events source_type:capacity_forecasting finding_uid:"#{escape_query_value(uid)}" status:(projected,at_risk,exhaustion_projected) time:last_30d sort:time:desc|
    else
      _ -> nil
    end
  end

  defp detail_related_query(_detail), do: nil

  defp detail_related_label(%{kind: "capacity_notice", row: row}) do
    uid = related_finding_uid(row)
    "This clear event resolves the prior projection for #{short_uid(uid)}."
  end

  defp detail_related_label(_detail), do: "Open related finding."

  defp detail_marker_label(%{kind: "capacity_notice", row: row}) do
    if cleared_capacity_notice?(row), do: "Capacity clear event", else: "Capacity projection event"
  end

  defp detail_marker_label(%{kind: "capacity"}), do: "Capacity forecast"
  defp detail_marker_label(_detail), do: "Selected anomaly finding"

  defp detail_marker_description(%{kind: "capacity_notice", row: row}) do
    if cleared_capacity_notice?(row) do
      "The vertical marker is when ServiceRadar emitted the clear event. Use the related finding link to open the projection that originally triggered this capacity finding."
    else
      "The vertical marker is when ServiceRadar emitted this capacity projection. The future crossing or exhaustion time is shown in the details above when available."
    end
  end

  defp detail_marker_description(%{kind: "capacity"}) do
    "The vertical marker is the forecast event time. The projected crossing or exhaustion time is shown in the details above."
  end

  defp detail_marker_description(_detail) do
    "The vertical marker is the selected anomaly finding time. Shaded bands mark detection windows when the engine provides start and end timestamps."
  end

  defp detail_reason(%{kind: "capacity", row: row}) do
    first_present(row, [
      ["skip_reason"],
      ["metadata", "reason"],
      ["raw_data", "reason"],
      ["unmapped", "reason"]
    ])
  end

  defp detail_reason(%{kind: "capacity_notice", row: row}), do: finding_reason(row)

  defp detail_reason(%{kind: "anomaly", row: row}) do
    if resolved_anomaly?(row) do
      resolution_reason_copy(row)
    else
      finding_reason(row)
    end
  end

  defp detail_reason(%{row: row}), do: finding_reason(row)
  defp detail_reason(_), do: nil

  defp detail_reason_label(%{kind: "anomaly", row: row}) do
    if resolved_anomaly?(row), do: "Resolution", else: "Detection trigger"
  end

  defp detail_reason_label(_), do: "Reason"

  defp detail_opening_reason(%{kind: "anomaly", row: row}) do
    if resolved_anomaly?(row) do
      first_present(row, [
        ["opening_reason"],
        ["metadata", "anomaly", "opening_reason"],
        ["metadata", "finding_info", "dimensions", "opening_reason"]
      ])
    end
  end

  defp detail_opening_reason(_), do: nil

  defp detail_lifecycle_notice(%{kind: "anomaly", row: row}) do
    if resolved_anomaly?(row) do
      if flap_merged_reason?(resolution_reason(row)) do
        %{
          title: "Resolved episode with a merged brief recurrence",
          body:
            "The signal briefly cleared and reopened inside the flap window, so ServiceRadar kept those transitions in one incident. This episode is now resolved."
        }
      else
        %{
          title: "This anomaly episode is resolved",
          body: resolution_reason_copy(row)
        }
      end
    end
  end

  defp detail_lifecycle_notice(_), do: nil

  defp resolved_anomaly?(row) do
    finding_state(row) == "cleared" or normalize_text(value(row, "status")) in ["cleared", "stale_closed"]
  end

  defp resolution_reason(row) do
    first_present(row, [
      ["resolution_reason"],
      ["metadata", "anomaly", "resolution_reason"],
      ["metadata", "anomaly", "reason"],
      ["reason"],
      ["message"]
    ])
  end

  defp resolution_reason_copy(row) do
    reason = resolution_reason(row)

    cond do
      flap_merged_reason?(reason) ->
        "Resolved after a brief clear and reopen were grouped into the same anomaly episode."

      normalize_text(reason) in ["recovered", "anomaly cleared: recovered"] ->
        "Resolved after the signal returned to its expected range."

      normalize_text(reason) in ["adopted", "anomaly cleared: adopted"] ->
        "Resolved after the sustained new level was adopted as the baseline."

      normalize_text(reason) in ["stale", "stale_closed", "anomaly cleared: stale"] ->
        "Resolved because no fresh producer update arrived before the stale-close window."

      present?(reason) ->
        to_string(reason)

      true ->
        "The signal no longer meets the anomaly criteria."
    end
  end

  defp flap_merged_reason?(reason) do
    reason
    |> normalize_text()
    |> String.replace("_", " ")
    |> String.contains?("flap merged")
  end

  defp status_badge_variant(status) do
    case normalize_text(status) do
      "projected" -> "warning"
      "at_risk" -> "error"
      "exhausted" -> "error"
      "exhaustion_projected" -> "error"
      "healthy" -> "success"
      "skipped" -> "ghost"
      _ -> "outline"
    end
  end

  defp severity_badge_variant(severity) do
    case normalize_text(severity) do
      "critical" -> "error"
      "high" -> "warning"
      "medium" -> "info"
      "low" -> "ghost"
      _ -> "outline"
    end
  end

  defp anomaly_badge_variant("active"), do: "warning"
  defp anomaly_badge_variant("confirmed"), do: "error"
  defp anomaly_badge_variant("pending"), do: "warning"
  defp anomaly_badge_variant("open"), do: "warning"
  defp anomaly_badge_variant("anomaly_open"), do: "warning"
  defp anomaly_badge_variant("suppressed"), do: "ghost"
  defp anomaly_badge_variant(_), do: "success"

  defp format_number(value) when is_integer(value), do: value |> Kernel.*(1.0) |> format_number()

  defp format_number(value) when is_float(value) do
    cond do
      abs(value) >= 1_000_000 -> "#{Float.round(value / 1_000_000, 1)}M"
      abs(value) >= 1_000 -> "#{Float.round(value / 1_000, 1)}k"
      true -> :erlang.float_to_binary(value, decimals: 2)
    end
  end

  defp format_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _} -> format_number(number)
      :error -> value
    end
  end

  defp format_number(_), do: "n/a"

  defp numeric_value(value) when is_integer(value), do: value * 1.0
  defp numeric_value(value) when is_float(value), do: value

  defp numeric_value(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _} -> number
      :error -> nil
    end
  end

  defp numeric_value(_), do: nil

  defp integer_value(value) when is_integer(value) and value >= 0, do: value
  defp integer_value(value) when is_float(value) and value >= 0, do: trunc(value)

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} when number >= 0 -> number
      _ -> nil
    end
  end

  defp integer_value(_), do: nil

  defp short_uid(value) when is_binary(value) do
    if String.length(value) > 12, do: String.slice(value, 0, 8), else: value
  end

  defp short_uid(_), do: "finding"

  defp escape_query_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp escape_query_value(value), do: value |> to_string() |> escape_query_value()

  defp format_percent(value) when is_integer(value), do: format_percent(value * 1.0)

  defp format_percent(value) when is_float(value) do
    value =
      if value <= 1.0 do
        value * 100.0
      else
        value
      end

    "#{Float.round(value, 1)}%"
  end

  defp format_percent(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _} -> format_percent(number)
      :error -> value
    end
  end

  defp format_percent(_), do: "n/a"

  defp parse_timestamp(nil), do: nil
  defp parse_timestamp(""), do: nil
  defp parse_timestamp(%DateTime{} = dt), do: dt

  defp parse_timestamp(%NaiveDateTime{} = ndt) do
    DateTime.from_naive!(ndt, "Etc/UTC")
  end

  defp parse_timestamp(value) when is_binary(value) do
    with {:error, _} <- DateTime.from_iso8601(value),
         {:ok, ndt} <- NaiveDateTime.from_iso8601(value) do
      DateTime.from_naive!(ndt, "Etc/UTC")
    else
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  defp parse_timestamp(_), do: nil

  defp timestamp_row_id(prefix, row, index) do
    identity =
      first_present(row, [
        ["finding_uid"],
        ["episode_uid"],
        ["id"],
        ["resource_key"],
        ["series_key"],
        ["time"],
        ["projected_exhaustion_at"]
      ]) || index

    "#{prefix}-#{dom_id_segment(identity, index)}-time"
  end

  defp dom_id_segment(value, fallback) do
    segment =
      value
      |> to_string()
      |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 96)

    if segment == "", do: to_string(fallback), else: segment
  end

  defp first_present(row, paths) do
    Enum.find_value(paths, &nested_value(row, &1))
  end

  defp nested_value(value, []), do: value

  defp nested_value(%{} = row, [key | rest]) do
    row
    |> value(key)
    |> nested_value(rest)
  end

  defp nested_value(_row, _path), do: nil

  defp value(%{} = row, key), do: clean_value(Map.get(row, key) || Map.get(row, known_atom_key(key)))
  defp value(_row, _key), do: nil

  defp clean_value(value) when is_binary(value) do
    case normalize_text(value) do
      "nil" -> nil
      "null" -> nil
      "" -> nil
      _ -> value
    end
  end

  defp clean_value(value), do: value

  defp known_atom_key("anomaly_score"), do: :anomaly_score
  defp known_atom_key("anomaly_value"), do: :anomaly_value
  defp known_atom_key("confidence"), do: :confidence
  defp known_atom_key("capacity_forecast"), do: :capacity_forecast
  defp known_atom_key("clears_finding_uid"), do: :clears_finding_uid
  defp known_atom_key("core_id"), do: :core_id
  defp known_atom_key("current_value"), do: :current_value
  defp known_atom_key("detection_finding"), do: :detection_finding
  defp known_atom_key("device_label"), do: :device_label
  defp known_atom_key("exhaustion_threshold"), do: :exhaustion_threshold
  defp known_atom_key("finding_uid"), do: :finding_uid
  defp known_atom_key("finding_info"), do: :finding_info
  defp known_atom_key("finding_title"), do: :finding_title
  defp known_atom_key("forecasted_at"), do: :forecasted_at
  defp known_atom_key("horizon_seconds"), do: :horizon_seconds
  defp known_atom_key("horizon_ends_at"), do: :horizon_ends_at
  defp known_atom_key("id"), do: :id
  defp known_atom_key("if_index"), do: :if_index
  defp known_atom_key("if_name"), do: :if_name
  defp known_atom_key("interface_uid"), do: :interface_uid
  defp known_atom_key("interface_name"), do: :interface_name
  defp known_atom_key("label"), do: :label
  defp known_atom_key("message"), do: :message
  defp known_atom_key("metadata"), do: :metadata
  defp known_atom_key("metric_class"), do: :metric_class
  defp known_atom_key("metric_name"), do: :metric_name
  defp known_atom_key("metric_value"), do: :metric_value
  defp known_atom_key("model"), do: :model
  defp known_atom_key("mount_point"), do: :mount_point
  defp known_atom_key("name"), do: :name
  defp known_atom_key("projected_exhaustion_at"), do: :projected_exhaustion_at
  defp known_atom_key("projected_value"), do: :projected_value
  defp known_atom_key("raw_data"), do: :raw_data
  defp known_atom_key("resource_id"), do: :resource_id
  defp known_atom_key("resource_key"), do: :resource_key
  defp known_atom_key("resource_label"), do: :resource_label
  defp known_atom_key("resource_type"), do: :resource_type
  defp known_atom_key("related_finding_uid"), do: :related_finding_uid
  defp known_atom_key("sample_count"), do: :sample_count
  defp known_atom_key("score"), do: :score
  defp known_atom_key("service_radar"), do: :service_radar
  defp known_atom_key("series_key"), do: :series_key
  defp known_atom_key("severity"), do: :severity
  defp known_atom_key("skip_reason"), do: :skip_reason
  defp known_atom_key("source_device_uid"), do: :source_device_uid
  defp known_atom_key("source_identity"), do: :source_identity
  defp known_atom_key("status"), do: :status
  defp known_atom_key("state"), do: :state
  defp known_atom_key("tags"), do: :tags
  defp known_atom_key("threshold_value"), do: :threshold_value
  defp known_atom_key("time"), do: :time
  defp known_atom_key("trigger_finding_uid"), do: :trigger_finding_uid
  defp known_atom_key("unmapped"), do: :unmapped
  defp known_atom_key("unit"), do: :unit
  defp known_atom_key("verdict"), do: :verdict
  defp known_atom_key(_), do: nil

  defp friendly_device_label(value, device_uid, device_display_name) do
    if same_device?(value, device_uid) and present?(device_display_name) and device_display_name != device_uid do
      device_display_name
    end
  end

  defp friendly_device_title(value, device_uid, device_display_name) do
    cond do
      same_device?(value, device_uid) and present?(device_display_name) and device_display_name != device_uid ->
        "#{device_display_name} (#{device_uid})"

      present?(value) ->
        to_string(value)

      true ->
        nil
    end
  end

  defp same_device?(value, device_uid) do
    present?(value) and present?(device_uid) and to_string(value) == device_uid
  end

  defp present?(value), do: not blank?(value)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: normalize_text(value) in ["", "nil", "null"]
  defp blank?(_), do: false

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_text(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_text()
  defp normalize_text(value) when is_number(value), do: value |> to_string() |> normalize_text()
  defp normalize_text(_), do: ""
end
