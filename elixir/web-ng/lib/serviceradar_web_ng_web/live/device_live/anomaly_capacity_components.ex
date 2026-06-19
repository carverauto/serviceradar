defmodule ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityComponents do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  attr :overview, :map, required: true

  def anomaly_capacity_section(assigns) do
    assigns =
      assign(
        assigns,
        :capacity_display_rows,
        capacity_display_rows(assigns.overview.capacity_rows)
      )

    ~H"""
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

        <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
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
                :for={{row, index} <- Enum.with_index(Enum.take(@overview.anomaly_rows, 5))}
                type="button"
                class="block w-full min-w-0 px-4 py-3 text-left transition hover:bg-base-200/50 focus:outline-none focus:ring-2 focus:ring-primary/40"
                phx-click="open_anomaly_capacity_row"
                phx-value-kind="anomaly"
                phx-value-uid={anomaly_row_uid(row, index)}
                phx-value-index={index}
                title={finding_title(row)}
              >
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0">
                    <div class="max-w-full break-words text-sm font-medium [overflow-wrap:anywhere]">
                      {finding_title(row)}
                    </div>
                    <div
                      :if={finding_reason(row)}
                      class="mt-1 max-w-full break-words text-xs text-base-content/50 [overflow-wrap:anywhere]"
                    >
                      {finding_reason(row)}
                    </div>
                    <div class="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-xs text-base-content/60">
                      <span>{metric_class_label(row)}</span>
                      <span>{finding_metric_name(row)}</span>
                      <span :if={interface_label(row)}>{interface_label(row)}</span>
                      <span :if={anomaly_value_label(row)}>{anomaly_value_label(row)}</span>
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
                <p class="text-xs text-base-content/60">{filter_label(@overview.capacity_filter)}</p>
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
                  <tr :if={@capacity_display_rows == []}>
                    <td colspan="5" class="py-8 text-center text-base-content/60">
                      No capacity forecasts found for this device yet.
                    </td>
                  </tr>
                  <tr
                    :for={{row, index} <- @capacity_display_rows}
                    class="cursor-pointer hover:bg-base-200/50"
                    phx-click="open_anomaly_capacity_row"
                    phx-value-kind="capacity"
                    phx-value-uid={capacity_row_uid(row, index)}
                    phx-value-index={index}
                    title={capacity_title(row)}
                  >
                    <td class="max-w-48 truncate" title={resource_title(row)}>
                      {resource_label(row)}
                    </td>
                    <td title={capacity_metric_title(row)}>
                      {capacity_metric_label(row)}
                    </td>
                    <td>
                      <span class={["badge badge-sm", status_badge_class(value(row, "status"))]}>
                        {value(row, "status") || "unknown"}
                      </span>
                    </td>
                    <td>
                      <div class="whitespace-nowrap">
                        {capacity_projected_label(row)}
                      </div>
                      <div class="text-xs text-base-content/50">
                        {capacity_current_label(row)}
                      </div>
                    </td>
                    <td class="whitespace-nowrap">
                      {format_timestamp(value(row, "projected_exhaustion_at"))}
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

  attr :selection, :map, default: nil

  def anomaly_capacity_detail_modal(assigns) do
    ~H"""
    <div :if={@selection} class="modal modal-open" role="dialog" aria-modal="true">
      <div class="modal-box max-w-3xl">
        <div class="flex items-start justify-between gap-4">
          <div class="min-w-0">
            <h2 class="break-words text-lg font-semibold">
              {selection_title(@selection)}
            </h2>
            <p class="mt-1 text-xs text-base-content/60">
              {selection_subtitle(@selection)}
            </p>
          </div>
          <button
            type="button"
            class="btn btn-ghost btn-sm btn-square"
            phx-click="close_anomaly_capacity_row"
            aria-label="Close details"
            title="Close details"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <div class="mt-4 grid gap-3 sm:grid-cols-2">
          <.detail_item
            :for={{label, value, subvalue} <- selection_details(@selection)}
            label={label}
            value={value}
            subvalue={subvalue}
          />
        </div>

        <div class="modal-action">
          <button type="button" class="btn btn-sm" phx-click="close_anomaly_capacity_row">
            Close
          </button>
        </div>
      </div>
      <button type="button" class="modal-backdrop" phx-click="close_anomaly_capacity_row">
        close
      </button>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :subvalue, :any, default: nil

  defp detail_item(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-200 bg-base-200/30 p-3">
      <div class="text-xs font-semibold uppercase tracking-normal text-base-content/50">
        {@label}
      </div>
      <div class="mt-1 break-words text-sm font-medium [overflow-wrap:anywhere]">
        {display_value(@value)}
      </div>
      <div
        :if={@subvalue}
        class="mt-1 break-words text-xs text-base-content/60 [overflow-wrap:anywhere]"
      >
        {@subvalue}
      </div>
    </div>
    """
  end

  defp observability_href(query) do
    "/observability?" <> URI.encode_query(%{tab: "events", q: query, limit: 50})
  end

  defp filter_label(nil), do: "No device identity filter selected"

  defp filter_label(%{field: field, label: label, value: value}) do
    "#{label} #{field}=#{value}"
  end

  defp filter_label(_), do: "Device identity fallback"

  defp capacity_display_rows(rows) when is_list(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reject(fn {row, _index} -> normalize_text(value(row, "status")) == "skipped" end)
    |> Enum.take(8)
  end

  defp capacity_display_rows(_rows), do: []

  defp selection_title(%{kind: "capacity", row: row}), do: resource_label(row)
  defp selection_title(%{kind: "anomaly", row: row}), do: finding_title(row)
  defp selection_title(_selection), do: "Details"

  defp selection_subtitle(%{kind: "capacity", row: row}) do
    compact_join(
      [capacity_metric_label(row), value(row, "status"), format_timestamp(value(row, "projected_exhaustion_at"))],
      " / "
    )
  end

  defp selection_subtitle(%{kind: "anomaly", row: row}) do
    compact_join([metric_class_label(row), finding_metric_name(row), format_timestamp(value(row, "time"))], " / ")
  end

  defp selection_subtitle(_selection), do: nil

  defp selection_details(%{kind: "capacity", row: row}) do
    [
      {"Resource", resource_label(row), resource_title(row)},
      {"Metric", capacity_metric_label(row), capacity_metric_title(row)},
      {"Status", value(row, "status"), value(row, "skip_reason")},
      {"Current", capacity_current_value(row), unit_label(row)},
      {"Projected", capacity_projected_value(row), projected_context(row)},
      {"Threshold", threshold_label(row), headroom_label(row)},
      {"Exhaustion", format_timestamp(value(row, "projected_exhaustion_at")), confidence_label(row)},
      {"Horizon", horizon_label(row), window_label(row)}
    ]
  end

  defp selection_details(%{kind: "anomaly", row: row}) do
    [
      {"Finding", finding_title(row), finding_uid(row)},
      {"Reason", finding_reason(row), nil},
      {"Metric", finding_metric_name(row), metric_class_label(row)},
      {"Interface", interface_label(row), interface_uid(row)},
      {"Value", anomaly_value(row), anomaly_score_label(row)},
      {"Severity", value(row, "severity") || "Unknown", status_label(row)},
      {"Series", series_key(row), source_type(row)},
      {"Device", device_identity(row), target_identity(row)},
      {"Time", format_timestamp(value(row, "time")), nil}
    ]
  end

  defp selection_details(_selection), do: []

  defp anomaly_row_uid(row, index) do
    finding_uid(row) || series_key(row) || "anomaly-#{index}"
  end

  defp capacity_row_uid(row, index) do
    compact_join(
      [
        value(row, "resource_id"),
        value(row, "metric_name"),
        value(row, "projected_exhaustion_at")
      ],
      "|"
    ) || "capacity-#{index}"
  end

  defp finding_title(row) do
    nested_value(row, ["finding_info", "title"]) ||
      nested_value(row, ["metadata", "finding_info", "title"]) ||
      value(row, "finding_title") ||
      nested_value(row, ["metadata", "detection_finding", "title"]) ||
      value(row, "message") ||
      "Anomaly finding"
  end

  defp finding_reason(row) do
    reason =
      first_present(row, [
        ["message"],
        ["metadata", "verdict", "reason"],
        ["metadata", "anomaly", "reason"],
        ["raw_data", "message"]
      ])

    if present?(reason) and reason != finding_title(row), do: reason
  end

  defp finding_uid(row) do
    first_present(row, [
      ["finding_info", "uid"],
      ["metadata", "finding_info", "uid"],
      ["metadata", "detection_finding", "uid"],
      ["uid"],
      ["id"]
    ])
  end

  defp finding_metric_name(row) do
    first_present(row, [
      ["metric_name"],
      ["source_identity", "metric_name"],
      ["metadata", "source_identity", "metric_name"],
      ["metadata", "service_radar", "metric_name"],
      ["metadata", "anomaly", "metric_name"],
      ["raw_data", "metric_name"]
    ]) || "metric"
  end

  defp interface_label(row) do
    if_index =
      first_present(row, [
        ["if_index"],
        ["source_identity", "if_index"],
        ["metadata", "source_identity", "if_index"],
        ["metadata", "anomaly", "if_index"],
        ["raw_data", "if_index"]
      ])

    interface_name =
      first_present(row, [
        ["interface_name"],
        ["source_identity", "interface_name"],
        ["metadata", "source_identity", "interface_name"],
        ["metadata", "source_identity", "if_name"],
        ["metadata", "tags", "ifName"],
        ["raw_data", "tags", "ifName"]
      ])

    cond do
      present?(interface_name) and present?(if_index) -> "#{interface_name} ifIndex #{if_index}"
      present?(interface_name) -> interface_name
      present?(if_index) -> "ifIndex #{if_index}"
      true -> nil
    end
  end

  defp interface_uid(row) do
    first_present(row, [
      ["interface_uid"],
      ["source_identity", "interface_uid"],
      ["metadata", "source_identity", "interface_uid"],
      ["metadata", "anomaly", "interface_uid"],
      ["raw_data", "interface_uid"]
    ])
  end

  defp anomaly_value_label(row) do
    case {anomaly_value(row), anomaly_score(row)} do
      {nil, nil} -> nil
      {value, nil} -> "value #{display_value(value)}"
      {nil, score} -> "score #{format_number(score)}"
      {value, score} -> "value #{display_value(value)} / score #{format_number(score)}"
    end
  end

  defp anomaly_value(row) do
    first_present(row, [
      ["anomaly", "value"],
      ["metadata", "anomaly", "value"],
      ["metadata", "service_radar", "value"],
      ["raw_data", "value"]
    ])
  end

  defp anomaly_score(row) do
    first_present(row, [
      ["anomaly", "score"],
      ["metadata", "anomaly", "score"],
      ["metadata", "service_radar", "score"],
      ["raw_data", "score"]
    ])
  end

  defp anomaly_score_label(row) do
    case anomaly_score(row) do
      nil -> nil
      score -> "score #{format_number(score)}"
    end
  end

  defp status_label(row) do
    case value(row, "status") do
      nil -> nil
      status -> "status #{status}"
    end
  end

  defp series_key(row) do
    first_present(row, [
      ["series_key"],
      ["source_identity", "series_key"],
      ["metadata", "source_identity", "series_key"],
      ["metadata", "anomaly", "series_key"],
      ["raw_data", "series_key"]
    ])
  end

  defp source_type(row) do
    first_present(row, [
      ["source_type"],
      ["metadata", "source_type"],
      ["metadata", "source_identity", "metric_type"],
      ["raw_data", "source_type"]
    ])
  end

  defp device_identity(row) do
    first_present(row, [
      ["device_uid"],
      ["device_uid_exact"],
      ["metadata", "service_radar", "device_uid"],
      ["metadata", "source_identity", "device_uid"],
      ["raw_data", "device_uid"]
    ])
  end

  defp target_identity(row) do
    first_present(row, [
      ["target_device_ip"],
      ["metadata", "anomaly", "target_device_ip"],
      ["metadata", "source_identity", "target_device_ip"],
      ["raw_data", "target_device_ip"]
    ])
  end

  defp metric_class_label(row) do
    row
    |> metric_class()
    |> case do
      "cpu" -> "CPU"
      "memory" -> "Memory"
      "disk" -> "Disk"
      "interface" -> "Interfaces"
      "red" -> "RED"
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
      "" -> "red"
      class -> class
    end
  end

  defp resource_label(row) do
    value(row, "resource_label") ||
      value(row, "resource_key") ||
      value(row, "resource_id") ||
      "resource"
  end

  defp resource_title(row) do
    compact_join(
      [
        value(row, "resource_id"),
        value(row, "resource_key")
      ],
      " / "
    )
  end

  defp capacity_title(row) do
    compact_join([resource_label(row), capacity_metric_label(row), capacity_projected_label(row)], " / ")
  end

  defp capacity_metric_label(row) do
    value(row, "metric_name") || value(row, "metric_class") || "metric"
  end

  defp capacity_metric_title(row) do
    compact_join([value(row, "metric_class"), unit_label(row), threshold_label(row)], " / ")
  end

  defp capacity_projected_label(row) do
    value = capacity_projected_value(row)
    unit = unit_label(row)

    compact_join([format_number(value), unit], " ")
  end

  defp capacity_current_label(row) do
    compact_join(["now", format_number(capacity_current_value(row)), unit_label(row)], " ")
  end

  defp capacity_current_value(row), do: value(row, "current_value")
  defp capacity_projected_value(row), do: value(row, "projected_value")

  defp threshold_label(row) do
    case first_present(row, [["exhaustion_threshold"], ["metadata", "exhaustion_threshold"]]) do
      nil -> nil
      threshold -> "threshold #{format_number(threshold)}#{unit_suffix(row)}"
    end
  end

  defp headroom_label(row) do
    with current when not is_nil(current) <- numeric_value(capacity_current_value(row)),
         threshold when not is_nil(threshold) <-
           numeric_value(first_present(row, [["exhaustion_threshold"], ["metadata", "exhaustion_threshold"]])) do
      "headroom #{format_number(threshold - current)}#{unit_suffix(row)}"
    else
      _ -> nil
    end
  end

  defp projected_context(row) do
    compact_join([threshold_label(row), horizon_label(row)], " / ")
  end

  defp confidence_label(row) do
    case value(row, "confidence") do
      nil -> nil
      confidence -> "confidence #{format_percent(confidence)}"
    end
  end

  defp horizon_label(row) do
    case first_present(row, [["horizon_seconds"], ["metadata", "horizon_seconds"]]) do
      nil -> nil
      seconds -> "horizon #{format_duration(seconds)}"
    end
  end

  defp window_label(row) do
    compact_join(
      [
        format_optional_time(first_present(row, [["window_started_at"], ["metadata", "window_started_at"]])),
        format_optional_time(first_present(row, [["window_ended_at"], ["metadata", "window_ended_at"]]))
      ],
      " to "
    )
  end

  defp unit_label(row) do
    first_present(row, [
      ["unit"],
      ["metadata", "unit"],
      ["metadata", "service_radar", "unit"],
      ["raw_data", "unit"]
    ])
  end

  defp unit_suffix(row) do
    case unit_label(row) do
      nil -> ""
      "" -> ""
      unit -> " #{unit}"
    end
  end

  defp status_badge_class(status) do
    case normalize_text(status) do
      "projected" -> "badge-warning"
      "at_risk" -> "badge-error"
      "exhausted" -> "badge-error"
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
  defp anomaly_badge_class("suppressed"), do: "badge-ghost"
  defp anomaly_badge_class(_), do: "badge-success"

  defp display_value(nil), do: "n/a"
  defp display_value(""), do: "n/a"
  defp display_value(value) when is_binary(value), do: value
  defp display_value(value) when is_number(value), do: to_string(value)
  defp display_value(value) when is_atom(value), do: Atom.to_string(value)
  defp display_value(value), do: inspect(value)

  defp present?(value), do: display_value(value) != "n/a"

  defp compact_join(values, joiner) do
    values
    |> Enum.map(&display_value/1)
    |> Enum.reject(&(&1 in ["", "n/a"]))
    |> Enum.join(joiner)
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp numeric_value(value) when is_integer(value), do: value * 1.0
  defp numeric_value(value) when is_float(value), do: value

  defp numeric_value(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _} -> number
      :error -> nil
    end
  end

  defp numeric_value(_value), do: nil

  defp format_duration(value) when is_integer(value), do: format_duration(value * 1.0)
  defp format_duration(value) when is_float(value) and value >= 86_400, do: "#{Float.round(value / 86_400, 1)}d"
  defp format_duration(value) when is_float(value) and value >= 3_600, do: "#{Float.round(value / 3_600, 1)}h"
  defp format_duration(value) when is_float(value) and value >= 60, do: "#{Float.round(value / 60, 1)}m"
  defp format_duration(value) when is_float(value), do: "#{Float.round(value, 0)}s"

  defp format_duration(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _} -> format_duration(number)
      :error -> value
    end
  end

  defp format_duration(value), do: display_value(value)

  defp format_optional_time(nil), do: nil
  defp format_optional_time(""), do: nil
  defp format_optional_time(value), do: format_timestamp(value)

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

  defp known_atom_key("anomaly"), do: :anomaly
  defp known_atom_key("confidence"), do: :confidence
  defp known_atom_key("current_value"), do: :current_value
  defp known_atom_key("device_uid"), do: :device_uid
  defp known_atom_key("device_uid_exact"), do: :device_uid_exact
  defp known_atom_key("detection_finding"), do: :detection_finding
  defp known_atom_key("exhaustion_threshold"), do: :exhaustion_threshold
  defp known_atom_key("finding_info"), do: :finding_info
  defp known_atom_key("finding_title"), do: :finding_title
  defp known_atom_key("horizon_seconds"), do: :horizon_seconds
  defp known_atom_key("id"), do: :id
  defp known_atom_key("if_index"), do: :if_index
  defp known_atom_key("if_name"), do: :if_name
  defp known_atom_key("ifName"), do: :ifName
  defp known_atom_key("interface_name"), do: :interface_name
  defp known_atom_key("interface_uid"), do: :interface_uid
  defp known_atom_key("message"), do: :message
  defp known_atom_key("metadata"), do: :metadata
  defp known_atom_key("metric_class"), do: :metric_class
  defp known_atom_key("metric_name"), do: :metric_name
  defp known_atom_key("projected_exhaustion_at"), do: :projected_exhaustion_at
  defp known_atom_key("projected_value"), do: :projected_value
  defp known_atom_key("raw_data"), do: :raw_data
  defp known_atom_key("resource_id"), do: :resource_id
  defp known_atom_key("resource_key"), do: :resource_key
  defp known_atom_key("resource_label"), do: :resource_label
  defp known_atom_key("service_radar"), do: :service_radar
  defp known_atom_key("severity"), do: :severity
  defp known_atom_key("series_key"), do: :series_key
  defp known_atom_key("skip_reason"), do: :skip_reason
  defp known_atom_key("source_identity"), do: :source_identity
  defp known_atom_key("source_type"), do: :source_type
  defp known_atom_key("status"), do: :status
  defp known_atom_key("tags"), do: :tags
  defp known_atom_key("target_device_ip"), do: :target_device_ip
  defp known_atom_key("time"), do: :time
  defp known_atom_key("unmapped"), do: :unmapped
  defp known_atom_key("unit"), do: :unit
  defp known_atom_key("uid"), do: :uid
  defp known_atom_key("value"), do: :value
  defp known_atom_key("window_ended_at"), do: :window_ended_at
  defp known_atom_key("window_started_at"), do: :window_started_at
  defp known_atom_key(_), do: nil

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_text(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_text()
  defp normalize_text(value) when is_number(value), do: value |> to_string() |> normalize_text()
  defp normalize_text(_), do: ""
end
