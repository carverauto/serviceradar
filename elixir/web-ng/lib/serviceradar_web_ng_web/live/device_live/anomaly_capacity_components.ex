defmodule ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityComponents do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  attr :overview, :map, required: true

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
              <article :for={row <- Enum.take(@overview.anomaly_rows, 5)} class="min-w-0 px-4 py-3">
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0">
                    <div class="max-w-full break-words text-sm font-medium [overflow-wrap:anywhere]">
                      {finding_title(row)}
                    </div>
                    <div class="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-xs text-base-content/60">
                      <span>{metric_class_label(row)}</span>
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
                    <th>Projected</th>
                    <th>Exhaustion</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :if={@overview.capacity_rows == []}>
                    <td colspan="5" class="py-8 text-center text-base-content/60">
                      No capacity forecasts found for this device yet.
                    </td>
                  </tr>
                  <tr :for={row <- Enum.take(@overview.capacity_rows, 8)}>
                    <td class="max-w-48 truncate">{resource_label(row)}</td>
                    <td>{value(row, "metric_name") || value(row, "metric_class") || "metric"}</td>
                    <td>
                      <span class={["badge badge-sm", status_badge_class(value(row, "status"))]}>
                        {value(row, "status") || "unknown"}
                      </span>
                    </td>
                    <td>
                      <div class="whitespace-nowrap">
                        {format_number(value(row, "projected_value"))}
                      </div>
                      <div class="text-xs text-base-content/50">
                        now {format_number(value(row, "current_value"))}
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
      value(row, "message") ||
      nested_value(row, ["metadata", "finding_info", "title"]) ||
      nested_value(row, ["metadata", "detection_finding", "title"]) ||
      "Anomaly finding"
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
  defp known_atom_key("finding_info"), do: :finding_info
  defp known_atom_key("finding_title"), do: :finding_title
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
  defp known_atom_key("status"), do: :status
  defp known_atom_key("time"), do: :time
  defp known_atom_key("unmapped"), do: :unmapped
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
