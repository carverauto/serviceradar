defmodule ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityComponents do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  attr :overview, :map, required: true
  attr :selected_detail, :map, default: nil

  def anomaly_capacity_section(assigns) do
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
              <article
                :for={{row, index} <- @overview.anomaly_rows |> Enum.take(5) |> Enum.with_index()}
                class="min-w-0 cursor-pointer px-4 py-3 transition hover:bg-base-200/50 focus:bg-base-200/50 focus:outline-none"
                role="button"
                tabindex="0"
                phx-click="open_anomaly_capacity_detail"
                phx-value-kind="anomaly"
                phx-value-index={index}
                title={detail_identity(row)}
              >
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0">
                    <div class="max-w-full break-words text-sm font-medium [overflow-wrap:anywhere]">
                      {finding_title(row)}
                    </div>
                    <div
                      :if={secondary_message(row)}
                      class="mt-1 max-w-full truncate text-xs text-base-content/70"
                    >
                      {secondary_message(row)}
                    </div>
                    <div class="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-xs text-base-content/60">
                      <span>{metric_name_label(row)}</span>
                      <span :if={value(row, "metric_value")}>
                        value {format_number(value(row, "metric_value"))}
                      </span>
                      <span :if={value(row, "score")}>
                        score {format_number(value(row, "score"))}
                      </span>
                      <span>{format_timestamp(value(row, "time"))}</span>
                    </div>
                  </div>
                  <div class="flex shrink-0 flex-col items-end gap-1">
                    <span class={[
                      "badge badge-sm",
                      severity_badge_class(value(row, "severity"))
                    ]}>
                      {value(row, "severity") || "Unknown"}
                    </span>
                    <span class={[
                      "badge badge-sm",
                      anomaly_badge_class(value(row, "status"))
                    ]}>
                      {value(row, "status") || "unknown"}
                    </span>
                  </div>
                </div>
              </article>
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
                    <th>Forecast</th>
                    <th>Exhaustion</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :if={@overview.capacity_rows == []}>
                    <td colspan="5" class="py-8 text-center text-base-content/60">
                      No capacity forecasts found for this device yet.
                    </td>
                  </tr>
                  <tr
                    :for={
                      {row, index} <- @overview.capacity_rows |> Enum.take(8) |> Enum.with_index()
                    }
                    class="cursor-pointer hover:bg-base-200/50"
                    phx-click="open_anomaly_capacity_detail"
                    phx-value-kind="capacity"
                    phx-value-index={index}
                    title={detail_identity(row)}
                  >
                    <td class="max-w-48 truncate" title={resource_identity(row)}>
                      {resource_label(row)}
                    </td>
                    <td>
                      <div class="whitespace-nowrap">
                        {value(row, "metric_name") || value(row, "metric_class") || "metric"}
                      </div>
                      <div :if={value(row, "value_unit")} class="text-xs text-base-content/50">
                        {value(row, "value_unit")}
                      </div>
                    </td>
                    <td>
                      <span class={["badge badge-sm", status_badge_class(value(row, "status"))]}>
                        {value(row, "status") || "unknown"}
                      </span>
                    </td>
                    <td>
                      <div class="whitespace-nowrap">
                        {capacity_forecast_value(row)}
                      </div>
                      <div class="text-xs text-base-content/50">
                        current {format_value(row, "current_value")}
                      </div>
                      <div :if={capacity_margin(row)} class="text-xs text-base-content/50">
                        {capacity_margin(row)}
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

      <.anomaly_capacity_detail_modal detail={@selected_detail} />
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

  attr :detail, :map, default: nil

  defp anomaly_capacity_detail_modal(%{detail: nil} = assigns), do: ~H""

  defp anomaly_capacity_detail_modal(assigns) do
    assigns =
      assigns
      |> assign(:kind, Map.get(assigns.detail, :kind))
      |> assign(:row, Map.get(assigns.detail, :row, %{}))

    ~H"""
    <div
      id="anomaly-capacity-detail-modal"
      class="modal modal-open"
      tabindex="0"
      phx-window-keydown="close_anomaly_capacity_detail"
      phx-key="escape"
    >
      <div class="modal-box max-w-3xl">
        <div class="flex items-start justify-between gap-4">
          <div class="min-w-0">
            <h3 class="break-words text-base font-semibold [overflow-wrap:anywhere]">
              {detail_title(@kind, @row)}
            </h3>
            <p class="mt-1 text-xs text-base-content/60">
              {detail_subtitle(@kind, @row)}
            </p>
          </div>
          <button
            type="button"
            class="btn btn-xs btn-ghost"
            phx-click="close_anomaly_capacity_detail"
            aria-label="Close detail"
          >
            Close
          </button>
        </div>

        <div :if={@kind == "anomaly"} class="mt-5 grid gap-3 sm:grid-cols-2">
          <.detail_fact label="Severity" value={value(@row, "severity") || "unknown"} />
          <.detail_fact label="Status" value={value(@row, "status") || "unknown"} />
          <.detail_fact label="Metric" value={metric_name_label(@row)} />
          <.detail_fact label="Value" value={format_number(value(@row, "metric_value"))} mono />
          <.detail_fact label="Score" value={format_number(value(@row, "score"))} mono />
          <.detail_fact label="Threshold" value={format_number(value(@row, "threshold_value"))} mono />
          <.detail_fact label="Series" value={value(@row, "series_key")} mono wide />
          <.detail_fact label="Interface" value={interface_identity(@row)} mono />
          <.detail_fact label="Device" value={value(@row, "device_label")} mono />
          <.detail_fact
            label="Finding UID"
            value={value(@row, "finding_uid") || value(@row, "id")}
            mono
            wide
          />
          <.detail_fact label="Observed" value={format_timestamp(value(@row, "time"))} />
        </div>

        <div :if={@kind == "capacity"} class="mt-5 grid gap-3 sm:grid-cols-2">
          <.detail_fact label="Resource" value={resource_label(@row)} mono wide />
          <.detail_fact label="Resource ID" value={value(@row, "resource_id")} mono wide />
          <.detail_fact label="Metric" value={capacity_metric_label(@row)} />
          <.detail_fact label="Status" value={value(@row, "status") || "unknown"} />
          <.detail_fact label="Current" value={format_value(@row, "current_value")} mono />
          <.detail_fact
            label="Projected at Horizon"
            value={capacity_forecast_value(@row)}
            mono
          />
          <.detail_fact label="Threshold" value={format_value(@row, "exhaustion_threshold")} mono />
          <.detail_fact label="Threshold Margin" value={capacity_margin(@row) || "n/a"} mono />
          <.detail_fact
            label="Exhaustion"
            value={format_timestamp(value(@row, "projected_exhaustion_at"))}
          />
          <.detail_fact label="Confidence" value={format_percent(value(@row, "confidence"))} />
          <.detail_fact label="Bounds" value={capacity_bounds(@row)} mono />
          <.detail_fact label="Window" value={capacity_window(@row)} />
          <.detail_fact label="Model" value={value(@row, "model")} />
          <.detail_fact label="Samples" value={value(@row, "sample_count")} mono />
        </div>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_anomaly_capacity_detail">close</button>
      </form>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :mono, :boolean, default: false
  attr :wide, :boolean, default: false

  defp detail_fact(assigns) do
    ~H"""
    <div class={["rounded-lg border border-base-200 bg-base-100 p-3", @wide && "sm:col-span-2"]}>
      <div class="text-xs font-semibold uppercase tracking-normal text-base-content/50">
        {@label}
      </div>
      <div class={[
        "mt-1 break-words text-sm text-base-content [overflow-wrap:anywhere]",
        @mono && "font-mono text-xs"
      ]}>
        {empty_label(@value)}
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

  defp finding_title(row) do
    value(row, "finding_title") ||
      nested_value(row, ["metadata", "finding_info", "title"]) ||
      nested_value(row, ["metadata", "detection_finding", "title"]) ||
      value(row, "message") ||
      "Anomaly finding"
  end

  defp secondary_message(row) do
    message = value(row, "message")
    title = finding_title(row)

    if present?(message) and message != title, do: message
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

  defp metric_name_label(row) do
    metric_name = value(row, "metric_name")
    metric_class = metric_class_label(row)

    cond do
      present?(metric_name) and present?(metric_class) -> "#{metric_class} / #{metric_name}"
      present?(metric_name) -> metric_name
      true -> metric_class
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

  defp resource_identity(row) do
    Enum.find_value(
      [
        value(row, "resource_key"),
        value(row, "resource_id"),
        value(row, "series_key")
      ],
      &present_value/1
    ) || resource_label(row)
  end

  defp detail_identity(row) do
    Enum.find_value(
      [
        value(row, "finding_uid"),
        value(row, "id"),
        value(row, "resource_key"),
        value(row, "resource_id"),
        value(row, "series_key")
      ],
      &present_value/1
    ) || "Open detail"
  end

  defp detail_title("capacity", row), do: resource_label(row)
  defp detail_title(_kind, row), do: finding_title(row)

  defp detail_subtitle("capacity", row) do
    [
      capacity_metric_label(row),
      value(row, "status"),
      format_timestamp(value(row, "projected_exhaustion_at"))
    ]
    |> Enum.filter(&present?/1)
    |> Enum.join(" - ")
  end

  defp detail_subtitle(_kind, row) do
    [
      metric_name_label(row),
      value(row, "status"),
      format_timestamp(value(row, "time"))
    ]
    |> Enum.filter(&present?/1)
    |> Enum.join(" - ")
  end

  defp capacity_metric_label(row) do
    metric = value(row, "metric_name") || value(row, "metric_class") || "metric"

    case unit_label(value(row, "value_unit")) do
      nil -> metric
      unit -> "#{metric} (#{unit})"
    end
  end

  defp interface_identity(row) do
    case {value(row, "interface_uid"), value(row, "if_index")} do
      {uid, index} when is_binary(uid) and uid != "" and not is_nil(index) -> "#{uid} / ifIndex #{index}"
      {uid, _index} when is_binary(uid) and uid != "" -> uid
      {_uid, index} when not is_nil(index) -> "ifIndex #{index}"
      _ -> nil
    end
  end

  defp capacity_bounds(row) do
    lower = format_value(row, "lower_bound")
    upper = format_value(row, "upper_bound")

    case {lower, upper} do
      {"n/a", "n/a"} -> nil
      {"n/a", upper} -> upper
      {lower, "n/a"} -> lower
      {lower, upper} -> "#{lower} - #{upper}"
    end
  end

  defp capacity_window(row) do
    started = value(row, "window_started_at")
    ended = value(row, "window_ended_at")

    cond do
      present?(started) and present?(ended) ->
        "#{format_timestamp(started)} - #{format_timestamp(ended)}"

      present?(value(row, "horizon_seconds")) ->
        "horizon #{value(row, "horizon_seconds")}s"

      true ->
        nil
    end
  end

  defp format_value(row, key) do
    formatted = format_number(value(row, key))

    case {formatted, unit_label(value(row, "value_unit"))} do
      {"n/a", _unit} -> "n/a"
      {value, nil} -> value
      {value, "%"} -> "#{value}%"
      {value, unit} -> "#{value} #{unit}"
    end
  end

  defp capacity_forecast_value(row) do
    if bounded_percent_projection_out_of_range?(row) do
      case format_value(row, "exhaustion_threshold") do
        "n/a" -> "trend outside 0-100%"
        threshold -> "crosses #{threshold}"
      end
    else
      format_value(row, "projected_value")
    end
  end

  defp capacity_margin(row) do
    threshold = number_value(value(row, "exhaustion_threshold"))
    current = number_value(value(row, "current_value"))
    projected = number_value(value(row, "projected_value"))
    basis = if bounded_percent_projection_out_of_range?(row), do: current, else: projected || current

    if threshold && basis do
      margin = threshold - basis
      formatted = format_unit_value(abs(margin), value(row, "value_unit"))
      qualifier = if bounded_percent_projection_out_of_range?(row), do: "current ", else: ""

      if margin < 0 do
        "#{qualifier}over threshold #{formatted}"
      else
        "#{qualifier}remaining #{formatted}"
      end
    end
  end

  defp bounded_percent_projection_out_of_range?(row) do
    case number_value(value(row, "projected_value")) do
      projected when is_float(projected) ->
        unit_label(value(row, "value_unit")) == "%" and (projected < 0.0 or projected > 100.0)

      _ ->
        false
    end
  end

  defp format_unit_value(value, unit) do
    formatted = format_number(value)

    case unit_label(unit) do
      nil -> formatted
      "%" -> "#{formatted}%"
      unit -> "#{formatted} #{unit}"
    end
  end

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

  defp unit_label(nil), do: nil
  defp unit_label(""), do: nil
  defp unit_label("%"), do: "%"
  defp unit_label("percent"), do: "%"
  defp unit_label("percentage"), do: "%"
  defp unit_label(unit), do: to_string(unit)

  defp number_value(value) when is_integer(value), do: value * 1.0
  defp number_value(value) when is_float(value), do: value

  defp number_value(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp number_value(_), do: nil

  defp empty_label(nil), do: "n/a"
  defp empty_label(""), do: "n/a"
  defp empty_label(value), do: value

  defp present_value(value), do: if(present?(value), do: value)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?("n/a"), do: false
  defp present?(_), do: true

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

  defp known_atom_key("confidence"), do: :confidence
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
  defp known_atom_key("interface_uid"), do: :interface_uid
  defp known_atom_key("lower_bound"), do: :lower_bound
  defp known_atom_key("message"), do: :message
  defp known_atom_key("metadata"), do: :metadata
  defp known_atom_key("metric_class"), do: :metric_class
  defp known_atom_key("metric_name"), do: :metric_name
  defp known_atom_key("metric_value"), do: :metric_value
  defp known_atom_key("model"), do: :model
  defp known_atom_key("projected_exhaustion_at"), do: :projected_exhaustion_at
  defp known_atom_key("projected_value"), do: :projected_value
  defp known_atom_key("raw_data"), do: :raw_data
  defp known_atom_key("resource_id"), do: :resource_id
  defp known_atom_key("resource_key"), do: :resource_key
  defp known_atom_key("resource_label"), do: :resource_label
  defp known_atom_key("resource_type"), do: :resource_type
  defp known_atom_key("sample_count"), do: :sample_count
  defp known_atom_key("score"), do: :score
  defp known_atom_key("service_radar"), do: :service_radar
  defp known_atom_key("severity"), do: :severity
  defp known_atom_key("series_key"), do: :series_key
  defp known_atom_key("status"), do: :status
  defp known_atom_key("threshold_value"), do: :threshold_value
  defp known_atom_key("time"), do: :time
  defp known_atom_key("unmapped"), do: :unmapped
  defp known_atom_key("upper_bound"), do: :upper_bound
  defp known_atom_key("value_unit"), do: :value_unit
  defp known_atom_key("window_started_at"), do: :window_started_at
  defp known_atom_key("window_ended_at"), do: :window_ended_at
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
