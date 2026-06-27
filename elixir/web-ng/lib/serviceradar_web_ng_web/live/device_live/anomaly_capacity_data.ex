defmodule ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityData do
  @moduledoc false

  alias ServiceRadarWebNGWeb.DeviceLive.QueryData

  require Logger

  @metric_classes ~w(cpu memory disk interface snmp other)
  @anomaly_limit 20
  @capacity_limit 12
  @query_timeout_ms 5_000

  def empty(status \\ :ok) do
    %{
      status: status,
      anomaly_rows: [],
      capacity_rows: [],
      anomaly_query: nil,
      capacity_query: nil,
      anomaly_filter: nil,
      capacity_filter: nil,
      anomaly_error: nil,
      capacity_error: nil,
      metric_statuses: metric_statuses([])
    }
  end

  def load(_srql_module, identity, _scope) when identity in [nil, %{}], do: empty()

  def load(srql_module, identity, scope) when is_map(identity) do
    anomaly_candidates = anomaly_filter_candidates(identity)
    capacity_candidates = capacity_filter_candidates(identity)

    if anomaly_candidates == [] and capacity_candidates == [] do
      empty()
    else
      anomaly_task =
        Task.Supervisor.async_nolink(ServiceRadarWebNG.TaskSupervisor, fn ->
          load_first(srql_module, anomaly_candidates, scope, &anomaly_query/1, &project_anomaly_row/1)
        end)

      capacity_task =
        Task.Supervisor.async_nolink(ServiceRadarWebNG.TaskSupervisor, fn ->
          load_first(srql_module, capacity_candidates, scope, &capacity_query/1, &project_capacity_row/1)
        end)

      anomaly = await_load_task(anomaly_task, "anomaly")
      capacity = await_load_task(capacity_task, "capacity")

      %{
        status: combined_status(anomaly, capacity),
        anomaly_rows: anomaly.rows,
        capacity_rows: capacity.rows,
        anomaly_query: anomaly.query,
        capacity_query: capacity.query,
        anomaly_filter: anomaly.filter,
        capacity_filter: capacity.filter,
        anomaly_error: anomaly.error,
        capacity_error: capacity.error,
        metric_statuses: metric_statuses(anomaly.rows)
      }
    end
  end

  defp await_load_task(task, label) do
    case Task.yield(task, @query_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        error = "#{label} SRQL task failed: #{Exception.format_exit(reason)}"
        Logger.warning(error)
        task_error_result(error)

      nil ->
        error = "#{label} SRQL query timed out after #{@query_timeout_ms}ms"
        Logger.warning(error)
        task_error_result(error)
    end
  end

  defp task_error_result(error) do
    %{rows: [], query: nil, filter: nil, error: error, status: :error}
  end

  defp load_first(srql_module, candidates, scope, query_fun, project_fun) do
    candidates
    |> Enum.reduce_while(nil, fn candidate, acc ->
      query = query_fun.(candidate)

      case srql_module.query(query, %{scope: scope}) do
        {:ok, %{"results" => rows}} when is_list(rows) ->
          rows =
            rows
            |> Enum.filter(&is_map/1)
            |> Enum.map(project_fun)
            |> Enum.reject(&is_nil/1)

          result = %{
            rows: rows,
            query: query,
            filter: Map.take(candidate, [:field, :label, :value]),
            error: nil,
            status: :ok
          }

          if result.rows == [] do
            {:cont, acc || result}
          else
            {:halt, result}
          end

        {:ok, other} ->
          error = "unexpected SRQL response: #{inspect(other)}"
          Logger.warning("Unexpected device anomaly/capacity SRQL response for #{query}: #{error}")
          {:cont, acc || error_result(candidate, query, error)}

        {:error, reason} ->
          error = "SRQL error: #{QueryData.format_error(reason)}"
          Logger.warning("Failed device anomaly/capacity SRQL query #{query}: #{error}")
          {:cont, acc || error_result(candidate, query, error)}
      end
    end)
    |> case do
      nil -> %{rows: [], query: nil, filter: nil, error: nil, status: :ok}
      result -> result
    end
  end

  defp error_result(candidate, query, error) do
    %{
      rows: [],
      query: query,
      filter: Map.take(candidate, [:field, :label, :value]),
      error: error,
      status: :error
    }
  end

  defp combined_status(%{status: :error}, _capacity), do: :error
  defp combined_status(_anomaly, %{status: :error}), do: :error
  defp combined_status(_anomaly, _capacity), do: :ok

  defp anomaly_filter_candidates(identity) do
    # Canonical device pages must not fall back to agent/host-scoped findings:
    # that is exactly how polled-device SNMP findings end up displayed on the
    # polling agent. Only use agent/host identities when there is no device uid.
    case candidate(identity, :device_uid, "service_radar_device_uid", "device") do
      nil ->
        Enum.reject(
          [
            candidate(identity, :agent_id, "service_radar_device_uid", "agent"),
            candidate(identity, :host_id, "service_radar_device_uid", "host")
          ],
          &is_nil/1
        )

      device ->
        [device]
    end
  end

  defp capacity_filter_candidates(identity) do
    Enum.reject(
      [
        candidate(identity, :device_uid, "resource_id", "device"),
        candidate(identity, :agent_id, "resource_id", "agent"),
        candidate(identity, :host_id, "resource_id", "host")
      ],
      &is_nil/1
    )
  end

  defp candidate(identity, key, field, label) do
    case Map.get(identity, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: %{field: field, label: label, value: value}

      _ ->
        nil
    end
  end

  defp anomaly_query(%{field: field, value: value}) do
    Enum.join(
      [
        "in:events",
        "class_uid:2004",
        # Anomaly findings carry source_type='anomaly_detection' in
        # metadata.service_radar; event_type is NULL on these rows. Filtering
        # source_type (not event_type) both returns the findings AND matches the
        # partial index idx_ocsf_events_sr_anomaly_device_time (class_uid=2004
        # AND source_type='anomaly_detection', keyed on device_uid,time) — turns
        # a 5s full-scan timeout into a sub-ms index scan.
        "source_type:anomaly_detection",
        ~s|#{field}:"#{QueryData.escape_value(value)}"|,
        "time:last_7d",
        "sort:time:desc",
        "limit:#{@anomaly_limit}"
      ],
      " "
    )
  end

  defp capacity_query(%{field: field, value: value}) do
    Enum.join(
      [
        "in:capacity_forecasts",
        "status:(projected,at_risk,exhaustion_projected)",
        "has_exhaustion:true",
        ~s|#{field}:"#{QueryData.escape_value(value)}"|,
        "time:last_24h",
        "sort:projected_exhaustion_at:asc",
        "limit:#{@capacity_limit}"
      ],
      " "
    )
  end

  defp project_anomaly_row(row) do
    projected =
      reject_nil_values(%{
        "id" => map_value(row, "id"),
        "finding_uid" => finding_uid(row),
        "time" => map_value(row, "time"),
        "finding_title" => finding_title(row),
        "message" => map_value(row, "message"),
        "metric_class" => metric_class(row),
        "metric_name" => metric_name(row),
        "metric_value" => metric_value(row),
        "sample_value" => sample_value(row),
        "threshold_value" => threshold_value(row),
        "score" => score_value(row),
        "series_key" => series_key(row),
        "interface_uid" => interface_uid(row),
        "if_index" => if_index(row),
        "device_label" => device_label(row),
        "severity" => map_value(row, "severity"),
        "status" => status_value(row),
        "consecutive_anomalous" => detection_value(row, "consecutive_anomalous"),
        "episode_started_at_unix_nano" => detection_value(row, "episode_started_at_unix_nano"),
        "episode_ended_at_unix_nano" => detection_value(row, "episode_ended_at_unix_nano"),
        "episode_peak_value" => detection_value(row, "episode_peak_value"),
        "episode_peak_at_unix_nano" => detection_value(row, "episode_peak_at_unix_nano"),
        "observed_at_unix_nano" => detection_value(row, "observed_at_unix_nano"),
        "signals" => detection_value(row, "signals"),
        "anomaly_disposition" => anomaly_disposition(row)
      })

    if operator_visible_anomaly_row?(projected), do: projected
  end

  defp project_capacity_row(row) do
    unit = capacity_value_unit(row)
    projected = row |> map_value("projected_value") |> number_value()

    if implausible_percent_projection?(projected, unit) do
      nil
    else
      reject_nil_values(%{
        "forecasted_at" => map_value(row, "forecasted_at"),
        "resource_type" => map_value(row, "resource_type"),
        "resource_label" => map_value(row, "resource_label"),
        "resource_key" => map_value(row, "resource_key"),
        "resource_id" => map_value(row, "resource_id"),
        "metric_name" => map_value(row, "metric_name"),
        "metric_class" => map_value(row, "metric_class"),
        "value_unit" => unit,
        "status" => map_value(row, "status"),
        "model" => map_value(row, "model"),
        "sample_count" => map_value(row, "sample_count"),
        "horizon_seconds" => map_value(row, "horizon_seconds"),
        "horizon_ends_at" => map_value(row, "horizon_ends_at"),
        "window_started_at" => map_value(row, "window_started_at"),
        "window_ended_at" => map_value(row, "window_ended_at"),
        "current_value" => map_value(row, "current_value"),
        "projected_value" => map_value(row, "projected_value"),
        "projected_exhaustion_at" => map_value(row, "projected_exhaustion_at"),
        "exhaustion_threshold" => map_value(row, "exhaustion_threshold"),
        "confidence" => map_value(row, "confidence"),
        "lower_bound" => map_value(row, "lower_bound"),
        "upper_bound" => map_value(row, "upper_bound")
      })
    end
  end

  defp finding_title(row) do
    first_present(row, [
      ["finding_title"],
      ["metadata", "finding_info", "title"],
      ["metadata", "detection_finding", "title"],
      ["message"]
    ])
  end

  defp finding_uid(row) do
    first_present(row, [
      ["finding_uid"],
      ["metadata", "finding_info", "uid"],
      ["metadata", "security_signal", "finding_uid"],
      ["metadata", "event_id"],
      ["metadata", "uid"],
      ["id"]
    ])
  end

  defp metric_name(row) do
    first_present(row, [
      ["metric_name"],
      ["metadata", "service_radar", "metric_name"],
      ["metadata", "anomaly", "metric_name"],
      ["metadata", "detection_finding", "metric_name"],
      ["unmapped", "metric_name"],
      ["raw_data", "metric_name"]
    ])
  end

  defp metric_value(row) do
    first_present(row, [
      ["metric_value"],
      ["metadata", "service_radar", "metric_value"],
      ["metadata", "anomaly", "value"],
      ["metadata", "anomaly", "sample_value"],
      ["metadata", "anomaly", "metric_value"],
      ["metadata", "detection_finding", "sample_value"],
      ["metadata", "finding_info", "dimensions", "sample_value"],
      ["unmapped", "metric_value"],
      ["raw_data", "metric_value"]
    ])
  end

  defp sample_value(row) do
    first_present(row, [
      ["sample_value"],
      ["metric_value"],
      ["metadata", "detection_finding", "sample_value"],
      ["metadata", "finding_info", "dimensions", "sample_value"],
      ["metadata", "anomaly", "sample_value"],
      ["metadata", "anomaly", "value"],
      ["raw_data", "anomaly", "sample_value"],
      ["raw_data", "anomaly", "value"]
    ])
  end

  defp threshold_value(row) do
    first_present(row, [
      ["threshold_value"],
      ["metadata", "service_radar", "threshold_value"],
      ["metadata", "anomaly", "threshold_value"],
      ["unmapped", "threshold_value"],
      ["raw_data", "threshold_value"]
    ])
  end

  defp score_value(row) do
    first_present(row, [
      ["score"],
      ["metadata", "service_radar", "score"],
      ["metadata", "anomaly", "score"],
      ["metadata", "anomaly", "z_score"],
      ["unmapped", "score"],
      ["raw_data", "score"]
    ])
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

  defp anomaly_disposition(row) do
    first_present(row, [
      ["anomaly_disposition"],
      ["metadata", "service_radar", "anomaly_disposition"],
      ["metadata", "serviceradar", "anomaly_disposition"],
      ["metadata", "diagnostics", "source", "source_anomaly_disposition"],
      ["metadata", "serviceradar", "diagnostics", "source", "source_anomaly_disposition"],
      ["unmapped", "anomaly_disposition"],
      ["raw_data", "anomaly_disposition"]
    ])
  end

  defp operator_visible_anomaly_row?(row) do
    status = status_value(row)
    disposition_action = row |> map_value("anomaly_disposition") |> map_value("action") |> normalize_text()

    not pending_or_warmup_status?(status) and disposition_action != "suppress"
  end

  defp pending_or_warmup_status?(status) do
    status = normalize_text(status)

    status in ["pending", "pending_anomaly", "pending_confirmation", "warming"] or
      String.contains?(status, "pending")
  end

  defp series_key(row) do
    first_present(row, [
      ["series_key"],
      ["metadata", "service_radar", "series_key"],
      ["metadata", "anomaly", "series_key"],
      ["metadata", "detection_finding", "dimensions", "series_key"],
      ["unmapped", "series_key"],
      ["raw_data", "series_key"]
    ])
  end

  defp interface_uid(row) do
    first_present(row, [
      ["interface_uid"],
      ["metadata", "service_radar", "interface_uid"],
      ["metadata", "anomaly", "interface_uid"],
      ["metadata", "detection_finding", "dimensions", "interface_uid"],
      ["unmapped", "interface_uid"],
      ["raw_data", "interface_uid"]
    ])
  end

  defp if_index(row) do
    first_present(row, [
      ["if_index"],
      ["metadata", "service_radar", "if_index"],
      ["metadata", "anomaly", "if_index"],
      ["metadata", "detection_finding", "dimensions", "if_index"],
      ["unmapped", "if_index"],
      ["raw_data", "if_index"]
    ])
  end

  defp device_label(row) do
    first_present(row, [
      ["device_label"],
      ["host"],
      ["source"],
      ["source_device_uid"],
      ["device", "hostname"],
      ["device", "name"],
      ["metadata", "service_radar", "device_label"],
      ["metadata", "service_radar", "source_device_uid"],
      ["metadata", "detection_finding", "dimensions", "device_uid"]
    ])
  end

  defp capacity_value_unit(row) do
    first_present(row, [
      ["value_unit"],
      ["unit"],
      ["metadata", "forecast_value_unit"],
      ["metadata", "raw_value_unit"],
      ["metadata", "unit"]
    ])
  end

  defp implausible_percent_projection?(projected, unit) when is_number(projected) do
    percent_unit?(unit) and (projected < 0.0 or projected > 100.0)
  end

  defp implausible_percent_projection?(_projected, _unit), do: false

  defp percent_unit?(unit) when is_binary(unit) do
    unit
    |> normalize_text()
    |> case do
      "%" -> true
      "percent" -> true
      "percentage" -> true
      _ -> false
    end
  end

  defp percent_unit?(_unit), do: false

  defp number_value(value) when is_integer(value), do: value * 1.0
  defp number_value(value) when is_float(value), do: value

  defp number_value(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp number_value(_), do: nil

  defp reject_nil_values(row) do
    Map.reject(row, fn {_key, value} -> is_nil(value) or value == "" end)
  end

  defp metric_statuses(rows) do
    counts =
      rows
      |> Enum.filter(&is_map/1)
      |> Enum.group_by(&metric_class/1)

    Enum.map(@metric_classes, fn class ->
      class_rows = Map.get(counts, class, [])
      status = anomaly_status(class_rows)

      %{
        class: class,
        label: metric_label(class),
        status: status,
        count: length(class_rows),
        latest: List.first(class_rows)
      }
    end)
  end

  defp anomaly_status([]), do: "normal"

  defp anomaly_status(rows) do
    if Enum.any?(rows, &(status_value(&1) == "suppressed")) do
      "suppressed"
    else
      "active"
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
    |> normalize_class()
  end

  defp status_value(row) do
    row
    |> first_present([
      ["status"],
      ["state"],
      ["metadata", "service_radar", "status"],
      ["metadata", "anomaly", "status"],
      ["metadata", "anomaly", "state"],
      ["metadata", "finding_info", "dimensions", "status"],
      ["metadata", "finding_info", "dimensions", "state"],
      ["metadata", "detection_finding", "status"],
      ["metadata", "detection_finding", "state"],
      ["unmapped", "status"],
      ["unmapped", "state"],
      ["raw_data", "status"],
      ["raw_data", "state"],
      ["raw_data", "anomaly", "status"],
      ["raw_data", "anomaly", "state"]
    ])
    |> normalize_text()
  end

  defp first_present(row, paths) do
    Enum.find_value(paths, &nested_value(row, &1))
  end

  defp nested_value(value, []), do: value

  defp nested_value(%{} = row, [key | rest]) do
    row
    |> map_value(key)
    |> nested_value(rest)
  end

  defp nested_value(_row, _path), do: nil

  defp map_value(%{} = row, key) do
    Map.get(row, key) || Map.get(row, known_atom_key(key))
  end

  defp map_value(_row, _key), do: nil

  defp known_atom_key("metadata"), do: :metadata
  defp known_atom_key("raw_data"), do: :raw_data
  defp known_atom_key("unmapped"), do: :unmapped
  defp known_atom_key("service_radar"), do: :service_radar
  defp known_atom_key("serviceradar"), do: :serviceradar
  defp known_atom_key("diagnostics"), do: :diagnostics
  defp known_atom_key("anomaly"), do: :anomaly
  defp known_atom_key("anomaly_disposition"), do: :anomaly_disposition
  defp known_atom_key("source_anomaly_disposition"), do: :source_anomaly_disposition
  defp known_atom_key("detection_finding"), do: :detection_finding
  defp known_atom_key("metric_class"), do: :metric_class
  defp known_atom_key("metric_name"), do: :metric_name
  defp known_atom_key("metric_value"), do: :metric_value
  defp known_atom_key("threshold_value"), do: :threshold_value
  defp known_atom_key("score"), do: :score
  defp known_atom_key("series_key"), do: :series_key
  defp known_atom_key("interface_uid"), do: :interface_uid
  defp known_atom_key("if_index"), do: :if_index
  defp known_atom_key("device_label"), do: :device_label
  defp known_atom_key("device"), do: :device
  defp known_atom_key("hostname"), do: :hostname
  defp known_atom_key("name"), do: :name
  defp known_atom_key("host"), do: :host
  defp known_atom_key("source"), do: :source
  defp known_atom_key("source_device_uid"), do: :source_device_uid
  defp known_atom_key("id"), do: :id
  defp known_atom_key("finding_uid"), do: :finding_uid
  defp known_atom_key("security_signal"), do: :security_signal
  defp known_atom_key("event_id"), do: :event_id
  defp known_atom_key("uid"), do: :uid
  defp known_atom_key("z_score"), do: :z_score
  defp known_atom_key("value"), do: :value
  defp known_atom_key("dimensions"), do: :dimensions
  defp known_atom_key("forecasted_at"), do: :forecasted_at
  defp known_atom_key("resource_type"), do: :resource_type
  defp known_atom_key("resource_label"), do: :resource_label
  defp known_atom_key("resource_key"), do: :resource_key
  defp known_atom_key("resource_id"), do: :resource_id
  defp known_atom_key("value_unit"), do: :value_unit
  defp known_atom_key("unit"), do: :unit
  defp known_atom_key("model"), do: :model
  defp known_atom_key("sample_count"), do: :sample_count
  defp known_atom_key("horizon_seconds"), do: :horizon_seconds
  defp known_atom_key("horizon_ends_at"), do: :horizon_ends_at
  defp known_atom_key("window_started_at"), do: :window_started_at
  defp known_atom_key("window_ended_at"), do: :window_ended_at
  defp known_atom_key("current_value"), do: :current_value
  defp known_atom_key("projected_value"), do: :projected_value
  defp known_atom_key("projected_exhaustion_at"), do: :projected_exhaustion_at
  defp known_atom_key("exhaustion_threshold"), do: :exhaustion_threshold
  defp known_atom_key("confidence"), do: :confidence
  defp known_atom_key("lower_bound"), do: :lower_bound
  defp known_atom_key("upper_bound"), do: :upper_bound
  defp known_atom_key("forecast_value_unit"), do: :forecast_value_unit
  defp known_atom_key("raw_value_unit"), do: :raw_value_unit
  defp known_atom_key("status"), do: :status
  defp known_atom_key("state"), do: :state
  defp known_atom_key(_), do: nil

  defp normalize_class(value) do
    value
    |> normalize_text()
    |> case do
      "memory_metrics" -> "memory"
      "cpu_metrics" -> "cpu"
      "disk_metrics" -> "disk"
      "interface_metrics" -> "interface"
      "snmp" <> _ -> "snmp"
      class when class in @metric_classes -> class
      _ -> "other"
    end
  end

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_text(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_text()
  defp normalize_text(value) when is_number(value), do: value |> to_string() |> normalize_text()
  defp normalize_text(_), do: ""

  defp metric_label("cpu"), do: "CPU"
  defp metric_label("memory"), do: "Memory"
  defp metric_label("disk"), do: "Disk"
  defp metric_label("interface"), do: "Interfaces"
  defp metric_label("snmp"), do: "SNMP"
  defp metric_label("other"), do: "Other signals"
  defp metric_label(class), do: class
end
