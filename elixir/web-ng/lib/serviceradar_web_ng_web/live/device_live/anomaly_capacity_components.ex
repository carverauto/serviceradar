defmodule ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityComponents do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  @detail_chart_focus_side_seconds 2 * 60 * 60

  attr :overview, :map, required: true
  attr :detail, :map, default: nil
  attr :device_uid, :string, default: nil
  attr :device_display_name, :string, default: nil

  def anomaly_capacity_section(assigns) do
    ~H"""
    <div>
      <section class="rounded-lg border border-base-200 bg-base-100">
        <div class="flex flex-wrap items-start justify-between gap-3 border-b border-base-200 px-5 py-4">
          <div>
            <h2 class="text-base font-semibold">Anomaly &amp; Capacity</h2>
            <p class="text-xs text-base-content/60">
              Device-scoped anomaly status, recent findings, and forecast runway.
            </p>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <.link
              :if={@overview.anomaly_query}
              navigate={observability_href(@overview.anomaly_query)}
              class="btn btn-xs"
            >
              Open findings
            </.link>
            <.link navigate="/observability/health" class="btn btn-xs btn-ghost">
              Fleet health
            </.link>
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
            <div class="rounded-lg border border-base-200">
              <div class="flex items-center justify-between gap-3 border-b border-base-200 px-4 py-3">
                <div>
                  <h3 class="text-sm font-semibold">Recent Anomaly Findings</h3>
                  <p class="text-xs text-base-content/60">{filter_label(@overview.anomaly_filter)}</p>
                </div>
                <span class="badge badge-sm">{length(@overview.anomaly_rows)}</span>
              </div>

              <div class="divide-y divide-base-200">
                <div :if={@overview.anomaly_rows == []} class="p-4 text-sm text-base-content/60">
                  No anomaly findings found for this device in the last 7 days.
                </div>
                <button
                  :for={{row, index} <- indexed_rows(@overview.anomaly_rows, 5)}
                  type="button"
                  class="block w-full min-w-0 px-4 py-3 text-left hover:bg-base-200/60 focus:bg-base-200/60 focus:outline-none"
                  phx-click="open_anomaly_capacity_detail"
                  phx-value-kind="anomaly"
                  phx-value-index={index}
                >
                  <div class="flex items-start justify-between gap-3">
                    <div class="min-w-0">
                      <div
                        class="max-w-full break-words text-sm font-medium [overflow-wrap:anywhere]"
                        title={value(row, "finding_uid")}
                      >
                        {finding_title(row)}
                      </div>
                      <div
                        :if={finding_reason(row)}
                        class="mt-1 line-clamp-2 text-xs text-base-content/60"
                        title={finding_reason(row)}
                      >
                        {finding_reason(row)}
                      </div>
                      <div class="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-xs text-base-content/60">
                        <span title={finding_identity_title(row)}>
                          {finding_metric_name(row) || metric_class_label(row)}
                        </span>
                        <span :if={interface_label(row)} title={interface_label(row)}>
                          {interface_label(row)}
                        </span>
                        <span :if={anomaly_value_label(row)}>{anomaly_value_label(row)}</span>
                        <span :if={anomaly_score_label(row)}>{anomaly_score_label(row)}</span>
                        <span
                          :if={source_device_label(row, @device_uid, @device_display_name)}
                          title={source_device_title(row, @device_uid, @device_display_name)}
                        >
                          {source_device_label(row, @device_uid, @device_display_name)}
                        </span>
                        <span>{format_timestamp(value(row, "time"))}</span>
                      </div>
                    </div>
                    <span class={[
                      "badge badge-sm shrink-0",
                      severity_badge_class(value(row, "severity"))
                    ]}>
                      {value(row, "severity") || "Unknown"}
                    </span>
                  </div>
                </button>
              </div>
            </div>

            <div class="rounded-lg border border-base-200">
              <div class="flex items-center justify-between gap-3 border-b border-base-200 px-4 py-3">
                <div>
                  <h3 class="text-sm font-semibold">Capacity Runway</h3>
                  <p class="text-xs text-base-content/60">
                    {filter_label(@overview.capacity_filter)}
                  </p>
                </div>
                <.link
                  :if={@overview.capacity_query}
                  navigate={observability_href(@overview.capacity_query)}
                  class="btn btn-xs"
                >
                  Open SRQL
                </.link>
              </div>

              <div class="overflow-x-auto">
                <table class="table table-sm">
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
                      <td colspan="5" class="py-8 text-center text-base-content/60">
                        No projected capacity forecasts found for this device yet.
                      </td>
                    </tr>
                    <tr
                      :for={{row, index} <- projected_capacity_rows(@overview.capacity_rows)}
                      class="cursor-pointer hover:bg-base-200/60"
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
                        <div :if={capacity_threshold_label(row)} class="text-xs text-base-content/50">
                          threshold {capacity_threshold_label(row)}
                        </div>
                      </td>
                      <td>
                        <span class={["badge badge-sm", status_badge_class(value(row, "status"))]}>
                          {value(row, "status") || "unknown"}
                        </span>
                      </td>
                      <td>
                        <div class="whitespace-nowrap">
                          {format_projected_metric_value(row)}
                        </div>
                        <div class="text-xs text-base-content/50">
                          now {format_metric_value(value(row, "current_value"), row)}
                        </div>
                        <div :if={capacity_headroom_label(row)} class="text-xs text-base-content/50">
                          current remaining {capacity_headroom_label(row)}
                        </div>
                      </td>
                      <td class="whitespace-nowrap">
                        {format_timestamp(value(row, "projected_exhaustion_at"))}
                        <div :if={capacity_horizon_label(row)} class="text-xs text-base-content/50">
                          horizon {capacity_horizon_label(row)}
                        </div>
                        <div :if={value(row, "confidence")} class="text-xs text-base-content/50">
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
      />
    </div>
    """
  end

  attr :status, :map, required: true

  defp metric_status_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-200 bg-base-100 p-3">
      <div class="text-xs font-semibold uppercase tracking-normal text-base-content/60">
        {@status.label}
      </div>
      <div class="mt-2 flex items-center justify-between gap-2">
        <span class={["badge badge-sm", anomaly_badge_class(@status.status)]}>
          {@status.status}
        </span>
        <span class="text-xs text-base-content/60">{@status.count}</span>
      </div>
    </div>
    """
  end

  attr :detail, :map, default: nil
  attr :device_uid, :string, default: nil
  attr :device_display_name, :string, default: nil

  defp anomaly_capacity_detail_modal(%{detail: nil} = assigns) do
    ~H"""
    """
  end

  defp anomaly_capacity_detail_modal(assigns) do
    ~H"""
    <dialog id="anomaly-capacity-detail-modal" class="modal modal-open">
      <div class="modal-box max-w-3xl">
        <div class="flex items-start justify-between gap-4">
          <div class="min-w-0">
            <div class="text-xs font-semibold uppercase tracking-normal text-base-content/60">
              {detail_kind_label(@detail.kind)}
            </div>
            <h3 class="mt-1 break-words text-lg font-semibold [overflow-wrap:anywhere]">
              {detail_title(@detail, @device_uid, @device_display_name)}
            </h3>
          </div>
          <button
            type="button"
            class="btn btn-sm btn-ghost"
            phx-click="close_anomaly_capacity_detail"
          >
            Close
          </button>
        </div>

        <div class="mt-5 grid gap-3 sm:grid-cols-2">
          <.detail_item label="Finding UID" value={detail_finding_uid(@detail)} />
          <.detail_item label="Metric" value={detail_metric(@detail)} />
          <.detail_item label="Severity / Status" value={detail_status(@detail)} />
          <.detail_item label="Interface" value={detail_interface(@detail)} />
          <.detail_item label={detail_value_score_label(@detail)} value={detail_value_score(@detail)} />
          <.detail_item
            label="Resource"
            value={detail_resource(@detail, @device_uid, @device_display_name)}
          />
          <.detail_item label="Series" value={detail_series(@detail)} />
          <.detail_item label="Observed" value={detail_time(@detail)} />
          <.detail_item label="Confidence" value={detail_confidence(@detail)} />
        </div>

        <div :if={detail_reason(@detail)} class="mt-5 rounded-lg bg-base-200 p-3">
          <div class="text-xs font-semibold uppercase tracking-normal text-base-content/60">
            Reason
          </div>
          <p class="mt-1 whitespace-pre-wrap break-words text-sm [overflow-wrap:anywhere]">
            {detail_reason(@detail)}
          </p>
        </div>

        <.disposition_summary :if={@detail.kind != "capacity"} detail={@detail} />
        <.detection_evidence :if={@detail.kind != "capacity"} detail={@detail} />
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_anomaly_capacity_detail">close</button>
      </form>
    </dialog>
    """
  end

  attr :detail, :map, required: true

  defp disposition_summary(assigns) do
    assigns = assign(assigns, :disposition, detail_anomaly_disposition(assigns.detail))

    ~H"""
    <div :if={@disposition} class={["mt-5 alert alert-soft", disposition_alert_class(@disposition)]}>
      <div class="w-full">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <div class="text-xs font-semibold uppercase tracking-normal">
            Alert disposition
          </div>
          <span class={["badge badge-sm", disposition_badge_class(@disposition)]}>
            {disposition_action_label(@disposition)}
          </span>
        </div>

        <p class="mt-2 text-sm leading-relaxed">
          {disposition_explanation(@disposition)}
        </p>

        <div class="mt-3 grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
          <div
            :for={{label, value} <- disposition_facts(@disposition)}
            class="rounded-lg bg-base-100/60 p-2"
          >
            <div class="text-[0.65rem] font-semibold uppercase tracking-normal opacity-70">
              {label}
            </div>
            <div class="mt-1 break-words text-xs [overflow-wrap:anywhere]">{value}</div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :detail, :map, required: true

  defp detection_evidence(assigns) do
    assigns =
      assigns
      |> assign(:timeline, detail_timeline(assigns.detail))
      |> assign(:signals, detail_signals(assigns.detail))
      |> assign(:consecutive, detail_consecutive_anomalous(assigns.detail))
      |> assign(:confirmation_summary, detail_confirmation_summary(assigns.detail))
      |> assign(:detector_rule, detail_detector_rule(assigns.detail))

    ~H"""
    <div
      :if={@timeline != [] or @signals != [] or present?(@consecutive)}
      class="mt-5 rounded-lg border border-base-200 p-3"
    >
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="text-xs font-semibold uppercase tracking-normal text-base-content/60">
          Edge detector evidence
        </div>
        <span :if={present?(@consecutive)} class="badge badge-sm badge-outline">
          {@consecutive} consecutive slots
        </span>
      </div>

      <p class="mt-2 text-xs leading-relaxed text-base-content/60">
        This is the edge spike detector's evidence. Chart markers use the episode
        peak when the edge supplied one; the finding time below is when confirmation
        completed. The shaded chart window is the detector episode window when start
        and end timestamps are available. Seasonal or causal disposition is shown
        separately when trusted context is available.
      </p>
      <p
        :if={present?(@confirmation_summary)}
        class="mt-2 rounded-md bg-base-200/60 px-2 py-1.5 text-xs font-medium leading-relaxed text-base-content/80"
      >
        {@confirmation_summary}
      </p>
      <p :if={present?(@detector_rule)} class="mt-2 text-xs leading-relaxed text-base-content/70">
        {@detector_rule}
      </p>

      <div :if={@timeline != []} class="mt-3 grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
        <div :for={{label, value} <- @timeline} class="rounded-lg bg-base-200/60 p-2">
          <div class="text-[0.65rem] font-semibold uppercase tracking-normal text-base-content/50">
            {label}
          </div>
          <div class="mt-1 break-words text-xs [overflow-wrap:anywhere]">{value}</div>
        </div>
      </div>

      <div :if={@signals != []} class="mt-4 overflow-x-auto">
        <table class="table table-xs">
          <thead>
            <tr>
              <th>Signal</th>
              <th>State</th>
              <th>Score</th>
              <th>Baseline</th>
              <th>Reason</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={signal <- @signals}>
              <td class="whitespace-nowrap">{signal_name(signal)}</td>
              <td>
                <span class={["badge badge-xs", signal_badge_class(signal)]}>
                  {signal_state(signal)}
                </span>
              </td>
              <td class="whitespace-nowrap">{signal_score(signal)}</td>
              <td class="whitespace-nowrap">{signal_baseline(signal)}</td>
              <td class="max-w-64 truncate" title={signal_reason(signal)}>
                {signal_reason(signal)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, default: nil

  defp detail_item(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-200 p-3">
      <div class="text-xs font-semibold uppercase tracking-normal text-base-content/60">
        {@label}
      </div>
      <div class="mt-1 break-words text-sm [overflow-wrap:anywhere]" title={@value || "n/a"}>
        {@value || "n/a"}
      </div>
    </div>
    """
  end

  defp detail_panel_assigns(panel, chart_focus) do
    panel.assigns
    |> Map.put(:compact, true)
    |> maybe_put_detail_chart_focus(chart_focus)
  end

  defp maybe_put_detail_chart_focus(assigns, nil), do: assigns
  defp maybe_put_detail_chart_focus(assigns, focus), do: Map.put(assigns, :chart_focus, focus)

  defp detail_chart_focus(%{kind: kind, row: row}) when is_map(row) do
    case first_present(row, [["time"], ["timestamp"], ["window_ended_at"], ["projected_exhaustion_at"]]) do
      nil ->
        nil

      timestamp ->
        %{
          timestamp: timestamp,
          label: detail_title(%{kind: kind, row: row}, nil, nil),
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
    "/observability?" <> URI.encode_query(%{tab: "events", q: query, limit: 50})
  end

  defp filter_label(nil), do: "No device identity filter selected"

  defp filter_label(%{field: field, label: label, value: value}) do
    "#{label} #{field}=#{value}"
  end

  defp filter_label(_), do: "Device identity fallback"

  defp indexed_rows(rows, limit) when is_list(rows) do
    rows
    |> Enum.with_index()
    |> Enum.take(limit)
  end

  defp indexed_rows(_rows, _limit), do: []

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
      series_key(row),
      source_device_uid(row)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" | ")
  end

  defp interface_label(row) do
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
      ])

    cond do
      present?(interface_uid) and present?(if_index) -> "#{interface_uid} / ifIndex #{if_index}"
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

  defp anomaly_value(row) do
    first_present(row, [
      ["anomaly_value"],
      ["metric_value"],
      ["sample_value"],
      ["metadata", "anomaly", "value"],
      ["metadata", "anomaly", "sample_value"],
      ["metadata", "detection_finding", "value"],
      ["metadata", "detection_finding", "sample_value"],
      ["metadata", "finding_info", "dimensions", "sample_value"],
      ["metadata", "finding_info", "dimensions", "value"],
      ["raw_data", "anomaly", "value"],
      ["raw_data", "anomaly", "sample_value"],
      ["raw_data", "metric_value"],
      ["unmapped", "metric_value"],
      ["unmapped", "anomaly_value"]
    ])
  end

  defp anomaly_score(row) do
    first_present(row, [
      ["anomaly_score"],
      ["score"],
      ["metadata", "anomaly", "score"],
      ["metadata", "detection_finding", "score"],
      ["raw_data", "anomaly", "score"],
      ["raw_data", "score"],
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
    row
    |> metric_class()
    |> case do
      "cpu" -> "CPU"
      "memory" -> "Memory"
      "disk" -> "Disk"
      "interface" -> "Interfaces"
      "other" -> "Other signals"
      "snmp" -> "SNMP"
      other -> other
    end
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

  defp format_projected_metric_value(row) do
    projected = numeric_value(value(row, "projected_value"))
    threshold = numeric_value(value(row, "exhaustion_threshold"))

    if capacity_unit(row) == "%" and not is_nil(projected) and not is_nil(threshold) and
         (projected < 0.0 or projected > 100.0) do
      "crosses #{format_metric_value(threshold, row)}"
    else
      format_metric_value(value(row, "projected_value"), row)
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
  defp detail_kind_label(_), do: "Anomaly finding"

  defp detail_finding_uid(%{kind: "capacity"}), do: nil
  defp detail_finding_uid(%{row: row}), do: value(row, "finding_uid") || value(row, "id")
  defp detail_finding_uid(_), do: nil

  defp detail_title(detail, device_uid, device_display_name)

  defp detail_title(%{kind: "capacity", row: row}, device_uid, device_display_name) do
    resource_label(row, device_uid, device_display_name)
  end

  defp detail_title(%{row: row}, _device_uid, _device_display_name), do: finding_title(row)
  defp detail_title(_detail, _device_uid, _device_display_name), do: "Detail"

  defp detail_metric(%{kind: "capacity", row: row}), do: capacity_metric_title(row)

  defp detail_metric(%{row: row}) do
    [metric_class_label(row), finding_metric_name(row)]
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.join(" / ")
    |> case do
      "" -> nil
      label -> label
    end
  end

  defp detail_metric(_), do: nil

  defp detail_status(%{kind: "capacity", row: row}), do: value(row, "status")
  defp detail_status(%{row: row}), do: value(row, "severity")
  defp detail_status(_), do: nil

  defp detail_interface(%{row: row}), do: interface_label(row)
  defp detail_interface(_), do: nil

  defp detail_value_score_label(%{kind: "capacity"}), do: "Projection"
  defp detail_value_score_label(_), do: "Value / Score"

  defp detail_value_score(%{kind: "capacity", row: row}) do
    [
      "current #{format_metric_value(value(row, "current_value"), row)}",
      "projected #{format_projected_metric_value(row)}",
      capacity_threshold_label(row) && "threshold #{capacity_threshold_label(row)}",
      capacity_headroom_label(row) && "current remaining #{capacity_headroom_label(row)}"
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

  defp detail_resource(%{row: row}, device_uid, device_display_name) do
    source_device_title(row, device_uid, device_display_name) || source_device_uid(row)
  end

  defp detail_resource(_detail, _device_uid, _device_display_name), do: nil

  defp detail_series(%{kind: "capacity", row: row}), do: value(row, "resource_key")
  defp detail_series(%{row: row}), do: series_key(row)
  defp detail_series(_), do: nil

  defp detail_time(%{kind: "capacity", row: row}) do
    row
    |> first_present([["projected_exhaustion_at"], ["forecasted_at"], ["horizon_ends_at"]])
    |> format_timestamp()
  end

  defp detail_time(%{row: row}), do: format_timestamp(value(row, "time"))
  defp detail_time(_), do: nil

  defp detail_confidence(%{row: row}), do: value(row, "confidence") && format_percent(value(row, "confidence"))
  defp detail_confidence(_), do: nil

  defp detail_reason(%{kind: "capacity", row: row}) do
    first_present(row, [
      ["skip_reason"],
      ["metadata", "reason"],
      ["raw_data", "reason"],
      ["unmapped", "reason"]
    ])
  end

  defp detail_reason(%{row: row}), do: finding_reason(row)
  defp detail_reason(_), do: nil

  defp detail_timeline(%{row: row}) do
    Enum.reject(
      [
        {"Episode start", format_unix_nano(detection_value(row, "episode_started_at_unix_nano"))},
        {"Peak sample", peak_label(row)},
        {"Finding emitted",
         format_unix_nano(detection_value(row, "observed_at_unix_nano")) ||
           detail_time(%{row: row})},
        {"Episode clear", format_unix_nano(detection_value(row, "episode_ended_at_unix_nano"))}
      ],
      fn {_label, value} -> blank?(value) or value == "n/a" end
    )
  end

  defp detail_timeline(_), do: []

  defp peak_label(row) do
    value = detection_value(row, "episode_peak_value")
    at = row |> detection_value("episode_peak_at_unix_nano") |> format_unix_nano()

    cond do
      present?(value) and present?(at) -> "#{format_number(value)} at #{at}"
      present?(value) -> format_number(value)
      true -> nil
    end
  end

  defp detail_signals(%{row: row}) do
    case detection_value(row, "signals") do
      signals when is_list(signals) -> Enum.filter(signals, &is_map/1)
      _ -> []
    end
  end

  defp detail_signals(_), do: []

  defp detail_consecutive_anomalous(%{row: row}) do
    detection_value(row, "consecutive_anomalous")
  end

  defp detail_consecutive_anomalous(_), do: nil

  defp detail_confirmation_summary(%{row: row}) do
    consecutive = detail_consecutive_anomalous(%{row: row})
    required = detail_required_consecutive_slots(row)

    cond do
      present?(consecutive) and present?(required) ->
        "Opened because #{consecutive} of #{required} consecutive evaluation slots breached the detector."

      present?(consecutive) ->
        "Opened after #{consecutive} consecutive breached evaluation slots."

      true ->
        nil
    end
  end

  defp detail_confirmation_summary(_), do: nil

  defp detail_required_consecutive_slots(row) do
    detection_value(row, "confirm_slots") ||
      row
      |> finding_reason()
      |> required_slots_from_reason()
  end

  defp required_slots_from_reason(reason) when is_binary(reason) do
    case Regex.run(~r/after\s+\d+\/(\d+)\s+consecutive/i, reason) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp required_slots_from_reason(_), do: nil

  defp detail_detector_rule(%{row: row}) do
    case row |> value("metric_class") |> normalize_text() do
      "cpu" ->
        cpu_detector_rule()

      "sysmon.cpu" ->
        cpu_detector_rule()

      metric when metric in ["memory", "sysmon.memory"] ->
        "Memory findings require consecutive breached evaluation slots; a clean slot resets pending confirmation before it opens."

      metric when metric in ["disk", "sysmon.disk"] ->
        "Disk usage findings require consecutive breached evaluation slots, but long-horizon disk-full risk is handled separately by capacity forecasting."

      _ ->
        "A finding opens only after the configured number of consecutive breached evaluation slots; clean slots reset pending confirmation."
    end
  end

  defp detail_detector_rule(_), do: nil

  defp cpu_detector_rule do
    "CPU raw samples are max-aggregated into 30-second evaluation slots. A short high-CPU spike can be visible on the chart without opening a finding unless consecutive evaluation slots breach."
  end

  defp detail_anomaly_disposition(%{row: row}) do
    case value(row, "anomaly_disposition") do
      %{} = disposition when map_size(disposition) > 0 -> disposition
      _ -> nil
    end
  end

  defp detail_anomaly_disposition(_), do: nil

  defp disposition_action(disposition), do: disposition |> value("action") |> normalize_text()

  defp disposition_action_label(disposition) do
    case disposition_action(disposition) do
      "suppress" -> "suppressed"
      "escalate" -> "escalated"
      "pass_through" -> "passed through"
      action when is_binary(action) and action != "" -> String.replace(action, "_", " ")
      _ -> "not applied"
    end
  end

  defp disposition_alert_class(disposition) do
    case disposition_action(disposition) do
      "suppress" -> "alert-success"
      "escalate" -> "alert-error"
      "pass_through" -> "alert-info"
      _ -> "alert-info"
    end
  end

  defp disposition_badge_class(disposition) do
    case disposition_action(disposition) do
      "suppress" -> "badge-success"
      "escalate" -> "badge-error"
      "pass_through" -> "badge-info"
      _ -> "badge-outline"
    end
  end

  defp disposition_explanation(disposition) do
    case disposition_action(disposition) do
      "suppress" ->
        "Central seasonal context marked this edge spike as expected for this series and window, so the alert path suppresses it."

      "escalate" ->
        "Central seasonal context also found this series off baseline, so the edge spike stays visible and the alert path raises its effective severity."

      "pass_through" ->
        "No trusted seasonal disposition applied to this finding; ServiceRadar leaves the edge detector verdict unchanged."

      _ ->
        "ServiceRadar attached disposition context to this finding, but did not classify it into a known alert action."
    end
  end

  defp disposition_facts(disposition) do
    Enum.reject(
      [
        {"Seasonal disposition", value(disposition, "seasonal_disposition")},
        {"Seasonal status", value(disposition, "seasonal_status")},
        {"Seasonal score", disposition_score(disposition)},
        {"Reason", disposition_reason(disposition)},
        {"Window start", disposition |> value("seasonal_window_started_at") |> format_timestamp()},
        {"Window end", disposition |> value("seasonal_window_ended_at") |> format_timestamp()},
        {"Evaluated", disposition |> value("seasonal_evaluated_at") |> format_timestamp()}
      ],
      fn {_label, value} -> blank?(value) or value == "n/a" end
    )
  end

  defp disposition_score(disposition) do
    case value(disposition, "seasonal_score") do
      value when is_nil(value) or value == "" -> nil
      value -> format_number(value)
    end
  end

  defp disposition_reason(disposition) do
    disposition
    |> value("reason")
    |> case do
      reason when is_binary(reason) and reason != "" -> String.replace(reason, "_", " ")
      reason -> reason
    end
  end

  defp detection_value(row, key) do
    first_present(row, [
      [key],
      ["metadata", "finding_info", "dimensions", key],
      ["metadata", "detection_finding", key],
      ["metadata", "anomaly", key],
      ["raw_data", "anomaly", key],
      ["unmapped", "anomaly", key],
      ["anomaly", key]
    ])
  end

  defp signal_name(signal), do: signal_value(signal, "name") || "signal"

  defp signal_state(signal) do
    cond do
      truthy?(signal_value(signal, "breached")) -> "breached"
      truthy?(signal_value(signal, "ready")) -> "ready"
      truthy?(signal_value(signal, "enabled")) -> "warming"
      true -> "disabled"
    end
  end

  defp signal_badge_class(signal) do
    case signal_state(signal) do
      "breached" -> "badge-error"
      "ready" -> "badge-success"
      "warming" -> "badge-warning"
      _ -> "badge-ghost"
    end
  end

  defp signal_score(signal) do
    score = signal_value(signal, "score")
    threshold = signal_value(signal, "threshold")

    cond do
      present?(score) and present?(threshold) -> "#{format_number(score)} / #{format_number(threshold)}"
      present?(score) -> format_number(score)
      true -> "n/a"
    end
  end

  defp signal_baseline(signal) do
    [
      signal_value(signal, "sample_count") && "n=#{signal_value(signal, "sample_count")}",
      signal_value(signal, "mean") && "mean #{format_number(signal_value(signal, "mean"))}",
      signal_value(signal, "stddev") && "stddev #{format_number(signal_value(signal, "stddev"))}"
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" | ")
    |> case do
      "" -> "n/a"
      label -> label
    end
  end

  defp signal_reason(signal), do: signal_value(signal, "reason") || "n/a"

  defp signal_value(%{} = signal, key), do: value(signal, key)
  defp signal_value(_signal, _key), do: nil

  defp status_badge_class(status) do
    case normalize_text(status) do
      "projected" -> "badge-warning"
      "at_risk" -> "badge-error"
      "exhausted" -> "badge-error"
      "exhaustion_projected" -> "badge-error"
      "healthy" -> "badge-success"
      "skipped" -> "badge-ghost"
      _ -> "badge-outline"
    end
  end

  defp severity_badge_class(severity) do
    case normalize_text(severity) do
      "critical" -> "badge-error"
      "high" -> "badge-warning"
      "medium" -> "badge-info"
      "low" -> "badge-ghost"
      _ -> "badge-outline"
    end
  end

  defp anomaly_badge_class("active"), do: "badge-warning"
  defp anomaly_badge_class("open"), do: "badge-warning"
  defp anomaly_badge_class("anomaly_open"), do: "badge-warning"
  defp anomaly_badge_class("suppressed"), do: "badge-ghost"
  defp anomaly_badge_class(_), do: "badge-success"

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

  defp format_unix_nano(nil), do: nil

  defp format_unix_nano(value) when is_integer(value) and value > 0 do
    case DateTime.from_unix(div(value, 1_000_000_000), :second) do
      {:ok, dt} -> format_timestamp(dt)
      _ -> nil
    end
  end

  defp format_unix_nano(value) when is_float(value), do: value |> trunc() |> format_unix_nano()

  defp format_unix_nano(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> format_unix_nano(parsed)
      _ -> nil
    end
  end

  defp format_unix_nano(_), do: nil

  defp format_timestamp(nil), do: "n/a"
  defp format_timestamp(""), do: "n/a"

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end

  defp format_timestamp(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> format_timestamp()
  end

  defp format_timestamp(value) when is_binary(value) do
    with {:error, _} <- DateTime.from_iso8601(value),
         {:ok, ndt} <- NaiveDateTime.from_iso8601(value) do
      ndt
      |> DateTime.from_naive!("Etc/UTC")
      |> format_timestamp()
    else
      {:ok, dt, _offset} -> format_timestamp(dt)
      {:error, _} -> value
    end
  end

  defp format_timestamp(value), do: to_string(value)

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

  defp value(%{} = row, key), do: Map.get(row, key) || Map.get(row, known_atom_key(key))
  defp value(_row, _key), do: nil

  defp known_atom_key("anomaly_score"), do: :anomaly_score
  defp known_atom_key("anomaly_value"), do: :anomaly_value
  defp known_atom_key("action"), do: :action
  defp known_atom_key("anomaly"), do: :anomaly
  defp known_atom_key("anomaly_disposition"), do: :anomaly_disposition
  defp known_atom_key("baseline_count"), do: :baseline_count
  defp known_atom_key("breached"), do: :breached
  defp known_atom_key("confidence"), do: :confidence
  defp known_atom_key("confirm_slots"), do: :confirm_slots
  defp known_atom_key("consecutive_anomalous"), do: :consecutive_anomalous
  defp known_atom_key("current_value"), do: :current_value
  defp known_atom_key("detection_finding"), do: :detection_finding
  defp known_atom_key("device_label"), do: :device_label
  defp known_atom_key("dimensions"), do: :dimensions
  defp known_atom_key("enabled"), do: :enabled
  defp known_atom_key("episode_ended_at_unix_nano"), do: :episode_ended_at_unix_nano
  defp known_atom_key("episode_peak_at_unix_nano"), do: :episode_peak_at_unix_nano
  defp known_atom_key("episode_peak_value"), do: :episode_peak_value
  defp known_atom_key("episode_started_at_unix_nano"), do: :episode_started_at_unix_nano
  defp known_atom_key("exhaustion_threshold"), do: :exhaustion_threshold
  defp known_atom_key("finding_uid"), do: :finding_uid
  defp known_atom_key("finding_info"), do: :finding_info
  defp known_atom_key("finding_title"), do: :finding_title
  defp known_atom_key("forecasted_at"), do: :forecasted_at
  defp known_atom_key("horizon_seconds"), do: :horizon_seconds
  defp known_atom_key("horizon_ends_at"), do: :horizon_ends_at
  defp known_atom_key("id"), do: :id
  defp known_atom_key("if_index"), do: :if_index
  defp known_atom_key("interface_uid"), do: :interface_uid
  defp known_atom_key("message"), do: :message
  defp known_atom_key("mean"), do: :mean
  defp known_atom_key("metadata"), do: :metadata
  defp known_atom_key("metric_class"), do: :metric_class
  defp known_atom_key("metric_name"), do: :metric_name
  defp known_atom_key("metric_value"), do: :metric_value
  defp known_atom_key("model"), do: :model
  defp known_atom_key("name"), do: :name
  defp known_atom_key("observed_at_unix_nano"), do: :observed_at_unix_nano
  defp known_atom_key("projected_exhaustion_at"), do: :projected_exhaustion_at
  defp known_atom_key("projected_value"), do: :projected_value
  defp known_atom_key("raw_data"), do: :raw_data
  defp known_atom_key("ready"), do: :ready
  defp known_atom_key("reason"), do: :reason
  defp known_atom_key("resource_id"), do: :resource_id
  defp known_atom_key("resource_key"), do: :resource_key
  defp known_atom_key("resource_label"), do: :resource_label
  defp known_atom_key("resource_type"), do: :resource_type
  defp known_atom_key("sample_count"), do: :sample_count
  defp known_atom_key("score"), do: :score
  defp known_atom_key("service_radar"), do: :service_radar
  defp known_atom_key("seasonal_disposition"), do: :seasonal_disposition
  defp known_atom_key("seasonal_evaluated_at"), do: :seasonal_evaluated_at
  defp known_atom_key("seasonal_score"), do: :seasonal_score
  defp known_atom_key("seasonal_status"), do: :seasonal_status
  defp known_atom_key("seasonal_window_ended_at"), do: :seasonal_window_ended_at
  defp known_atom_key("seasonal_window_started_at"), do: :seasonal_window_started_at
  defp known_atom_key("series_key"), do: :series_key
  defp known_atom_key("severity"), do: :severity
  defp known_atom_key("skip_reason"), do: :skip_reason
  defp known_atom_key("source_device_uid"), do: :source_device_uid
  defp known_atom_key("source_identity"), do: :source_identity
  defp known_atom_key("status"), do: :status
  defp known_atom_key("stddev"), do: :stddev
  defp known_atom_key("signals"), do: :signals
  defp known_atom_key("threshold_value"), do: :threshold_value
  defp known_atom_key("threshold"), do: :threshold
  defp known_atom_key("time"), do: :time
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

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
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
