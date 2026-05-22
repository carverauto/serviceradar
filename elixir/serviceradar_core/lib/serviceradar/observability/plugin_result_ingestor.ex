defmodule ServiceRadar.Observability.PluginResultIngestor do
  @moduledoc """
  Ingests plugin results (`serviceradar.plugin_result.v1`) into service_status
  and timeseries_metrics.
  """

  alias Ash.Error.Query.NotFound
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.EventIngestor
  alias ServiceRadar.Camera.InventoryIngestor
  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.Inventory.DeviceDiscoveryIngestor
  alias ServiceRadar.Inventory.HypervisorEnrichmentIngestor
  alias ServiceRadar.Inventory.ProxmoxEnrichmentIngestor
  alias ServiceRadar.Monitoring.CheckInstance
  alias ServiceRadar.Monitoring.LatestCheckState
  alias ServiceRadar.Observability.ServiceIdentity
  alias ServiceRadar.Observability.ServiceStateRegistry
  alias ServiceRadar.Observability.ServiceStatus
  alias ServiceRadar.Observability.StatefulAlertEngine
  alias ServiceRadar.Observability.ThreatIntelPluginIngestor
  alias ServiceRadar.Observability.TimeseriesMetric
  alias ServiceRadar.Observability.TimeseriesSeriesKey
  alias ServiceRadar.WifiMap.BatchIngestor

  require Ash.Query
  require Logger

  @spec ingest(map() | list(), map()) :: :ok | {:error, term()}
  def ingest(payload, status) when is_map(payload) do
    actor = SystemActor.system(:plugin_result_ingestor)
    created_at = DateTime.truncate(DateTime.utc_now(), :microsecond)
    observed_at = resolve_observed_at(payload, status)
    summary = resolve_summary(payload)
    status_label = fetch_string(payload, ["status"])
    available = resolve_available(status, status_label)

    status_row =
      build_status_row(
        payload,
        status,
        observed_at,
        created_at,
        summary,
        available
      )

    with :ok <- insert_status(status_row, actor),
         :ok <- upsert_current_state(status_row),
         :ok <- insert_metrics(payload, status, observed_at, created_at, actor),
         :ok <-
           upsert_target_check_state(
             payload,
             status,
             observed_at,
             summary,
             status_label,
             available,
             actor
           ) do
      ingest_registered_handlers(payload, status, observed_at, actor)
    end
  rescue
    e ->
      Logger.error("Plugin result ingest failed: #{inspect(CredentialRedactor.redact(e))}")
      {:error, e}
  end

  def ingest(payload, status) when is_list(payload) do
    payload
    |> Enum.filter(&is_map/1)
    |> case do
      [] ->
        {:error, :invalid_payload}

      entries ->
        Enum.reduce_while(entries, :ok, fn entry, :ok ->
          case ingest(entry, status) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  def ingest(_payload, _status), do: {:error, :invalid_payload}

  defp insert_status(row, actor) do
    case Ash.create(ServiceStatus, row,
           actor: actor,
           domain: ServiceRadar.Observability,
           return_records?: false
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
      other -> {:error, other}
    end
  end

  defp upsert_current_state(row) when is_map(row) do
    ServiceStateRegistry.upsert_from_status(%{
      agent_id: Map.get(row, :agent_id),
      gateway_id: Map.get(row, :gateway_id),
      partition: Map.get(row, :partition),
      service_type: Map.get(row, :service_type),
      service_name: Map.get(row, :service_name),
      available: Map.get(row, :available),
      message: Map.get(row, :details) || Map.get(row, :message),
      timestamp: Map.get(row, :timestamp)
    })
  end

  defp resolve_observed_at(payload, status) do
    FieldParser.parse_timestamp(
      fetch_value(payload, ["observed_at", "observedAt"]) ||
        status[:agent_timestamp] ||
        status[:timestamp]
    )
  end

  defp resolve_summary(payload) do
    fetch_string(payload, ["summary", "message"]) ||
      fetch_string(payload, ["status"])
  end

  defp resolve_available(status, status_label) do
    case status[:available] do
      true -> true
      false -> false
      _ -> plugin_status_available(status_label)
    end
  end

  defp resolve_service_name(status) do
    case status[:service_name] do
      name when is_binary(name) and name != "" -> name
      _ -> "plugin"
    end
  end

  defp resolve_service_type(status) do
    case status[:service_type] do
      type when is_binary(type) and type != "" -> type
      _ -> "plugin"
    end
  end

  defp resolve_gateway_id(status) do
    case status[:gateway_id] do
      id when is_binary(id) and id != "" -> id
      _ -> "unknown"
    end
  end

  defp build_status_row(payload, status, observed_at, created_at, summary, available) do
    gateway_id = resolve_gateway_id(status)
    service_name = resolve_service_name(status)
    service_type = resolve_service_type(status)
    partition = status[:partition] || "default"

    service_id =
      ServiceIdentity.service_id(%{
        agent_id: status[:agent_id],
        gateway_id: gateway_id,
        partition: partition,
        service_type: service_type,
        service_name: service_name
      })

    %{
      timestamp: observed_at,
      gateway_id: gateway_id,
      agent_id: status[:agent_id],
      service_id: service_id,
      service_name: service_name,
      service_type: service_type,
      available: available,
      message: summary,
      details: FieldParser.encode_json(CredentialRedactor.redact(payload)),
      partition: partition,
      created_at: created_at
    }
  end

  defp insert_metrics(payload, status, observed_at, created_at, actor) do
    rows =
      payload
      |> extract_metrics()
      |> Enum.map(&build_metric_row(&1, payload, status, observed_at, created_at))
      |> Enum.reject(&is_nil/1)
      |> TimeseriesSeriesKey.dedupe_rows()

    if Enum.empty?(rows) do
      :ok
    else
      case Ash.bulk_create(rows, TimeseriesMetric, :create,
             actor: actor,
             domain: ServiceRadar.Observability,
             return_records?: false,
             return_errors?: true,
             stop_on_error?: false,
             upsert?: true,
             upsert_identity: :unique_timeseries_metric,
             upsert_fields: []
           ) do
        %Ash.BulkResult{status: :success} ->
          evaluate_metric_alerts(rows)
          :ok

        %Ash.BulkResult{errors: errors} = result ->
          {:error, errors || result}
      end
    end
  end

  defp upsert_target_check_state(
         payload,
         status,
         observed_at,
         summary,
         status_label,
         available,
         actor
       ) do
    case target_check_instance_id(payload) do
      nil ->
        :ok

      check_instance_id ->
        with {:ok, check_instance} <- load_check_instance(check_instance_id, actor),
             {:ok, previous_state} <- load_previous_check_state(check_instance.id, actor),
             {:ok, _state} <-
               LatestCheckState.record_state(
                 target_check_state_attrs(
                   check_instance,
                   previous_state,
                   payload,
                   status,
                   observed_at,
                   summary,
                   status_label,
                   available
                 ),
                 actor: actor
               ) do
          :ok
        else
          {:error, :check_instance_not_found} ->
            Logger.warning(
              "Plugin result referenced unknown check_instance_id=#{check_instance_id}"
            )

            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp load_check_instance(check_instance_id, actor) do
    case CheckInstance.get_by_id(check_instance_id, actor: actor) do
      {:ok, %CheckInstance{} = check_instance} -> {:ok, check_instance}
      {:ok, nil} -> {:error, :check_instance_not_found}
      {:error, %NotFound{}} -> {:error, :check_instance_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_previous_check_state(check_instance_id, actor) do
    LatestCheckState
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(check_instance_id == ^check_instance_id)
    |> Ash.Query.limit(1)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, %LatestCheckState{} = state} -> {:ok, state}
      {:ok, nil} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp target_check_state_attrs(
         %CheckInstance{} = check_instance,
         previous_state,
         payload,
         status,
         observed_at,
         summary,
         status_label,
         available
       ) do
    state = check_status(status_label, available)
    previous_status = previous_state && previous_state.status

    %{
      check_instance_id: check_instance.id,
      monitored_service_id: check_instance.monitored_service_id,
      monitoring_binding_id: check_instance.monitoring_binding_id,
      device_uid: check_instance.device_uid,
      agent_id: check_instance.agent_id,
      vantage_kind: check_instance.vantage_kind,
      vantage_id: check_instance.vantage_id || status[:agent_id],
      status: state,
      previous_status: previous_status,
      status_changed_at: status_changed_at(previous_state, previous_status, state, observed_at),
      last_observed_at: observed_at,
      response_time_ms: response_time_ms(payload, status),
      summary: summary,
      details: target_check_details(payload, status),
      metrics: target_check_metrics(payload),
      consecutive_failures: consecutive_failures(previous_state, state)
    }
  end

  defp target_check_instance_id(payload) do
    payload
    |> fetch_string(["check_instance_id", "checkInstanceId"])
    |> normalize_identifier()
    |> case do
      nil ->
        payload
        |> fetch_value(["labels", "label"])
        |> case do
          labels when is_map(labels) ->
            labels
            |> fetch_string(["check_instance_id", "checkInstanceId"])
            |> normalize_identifier()

          _ ->
            nil
        end

      value ->
        value
    end
  end

  defp check_status(status_label, available) do
    case status_label && String.upcase(to_string(status_label)) do
      "OK" -> :ok
      "WARNING" -> :warning
      "CRITICAL" -> :critical
      "UNKNOWN" -> :unknown
      _ when available == true -> :ok
      _ when available == false -> :critical
      _ -> :unknown
    end
  end

  defp status_changed_at(nil, _previous_status, _state, observed_at), do: observed_at

  defp status_changed_at(_previous_state, previous_status, state, observed_at)
       when previous_status != state,
       do: observed_at

  defp status_changed_at(previous_state, _previous_status, _state, _observed_at),
    do: previous_state.status_changed_at || previous_state.last_observed_at

  defp response_time_ms(payload, status) do
    payload
    |> fetch_value([
      "response_time_ms",
      "responseTimeMs",
      "duration_ms",
      "durationMs",
      "latency_ms",
      "latencyMs"
    ])
    |> parse_integer()
    |> case do
      nil -> parse_integer(status[:response_time])
      value -> value
    end
  end

  defp target_check_details(payload, status) do
    %{
      "payload" => CredentialRedactor.redact(payload),
      "assignment_id" => label_value(payload, "assignment_id"),
      "plugin_id" => label_value(payload, "plugin_id"),
      "agent_id" => status[:agent_id],
      "gateway_id" => status[:gateway_id],
      "partition" => status[:partition]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp target_check_metrics(payload) do
    case fetch_value(payload, ["metrics"]) do
      metrics when is_list(metrics) -> %{"items" => CredentialRedactor.redact(metrics)}
      metrics when is_map(metrics) -> CredentialRedactor.redact(metrics)
      _ -> %{}
    end
  end

  defp label_value(payload, key) do
    payload
    |> fetch_value(["labels", "label"])
    |> case do
      labels when is_map(labels) -> fetch_string(labels, [key])
      _ -> nil
    end
  end

  defp normalize_identifier(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      "nil" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_identifier(_value), do: nil

  defp consecutive_failures(_previous_state, :ok), do: 0

  defp consecutive_failures(%LatestCheckState{consecutive_failures: count}, _state)
       when is_integer(count) and count >= 0,
       do: count + 1

  defp consecutive_failures(_previous_state, _state), do: 1

  defp evaluate_metric_alerts(rows) do
    case StatefulAlertEngine.evaluate_metrics(rows) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Metric alert evaluation failed: #{inspect(reason)}")
        :ok
    end
  end

  defp extract_metrics(%{"metrics" => metrics}) when is_list(metrics), do: metrics
  defp extract_metrics(%{metrics: metrics}) when is_list(metrics), do: metrics
  defp extract_metrics(_), do: []

  defp build_metric_row(metric, payload, status, observed_at, created_at) when is_map(metric) do
    name = fetch_string(metric, ["name", "metric", "metric_name", "metricName"])

    case parse_metric_value(fetch_value(metric, ["value", "val", "metric_value", "metricValue"])) do
      {:ok, value} when is_binary(name) and name != "" ->
        unit = fetch_string(metric, ["unit", "u"])
        tags = build_tags(payload)
        metadata = build_metadata(metric, payload)

        row = %{
          timestamp: observed_at,
          gateway_id: status[:gateway_id] || "unknown",
          agent_id: status[:agent_id],
          metric_name: name,
          metric_type: "plugin",
          value: FieldParser.parse_value(value),
          unit: unit,
          tags: tags,
          partition: status[:partition],
          metadata: metadata,
          created_at: created_at
        }

        Map.put(row, :series_key, TimeseriesSeriesKey.build(row))

      _ ->
        nil
    end
  end

  defp build_metric_row(_metric, _payload, _status, _observed_at, _created_at), do: nil

  defp build_tags(payload) do
    payload
    |> fetch_value(["labels", "label"])
    |> normalize_labels()
  end

  defp build_metadata(metric, payload) do
    %{}
    |> maybe_put("warn", parse_metric_number(fetch_value(metric, ["warn", "warning"])))
    |> maybe_put("crit", parse_metric_number(fetch_value(metric, ["crit", "critical"])))
    |> maybe_put("min", parse_metric_number(fetch_value(metric, ["min"])))
    |> maybe_put("max", parse_metric_number(fetch_value(metric, ["max"])))
    |> maybe_put("perfdata", fetch_string(payload, ["perfdata"]))
  end

  defp normalize_labels(nil), do: %{}

  defp normalize_labels(labels) when is_map(labels) do
    Enum.reduce(labels, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), value)
    end)
  end

  defp normalize_labels(_), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fetch_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key) || Map.get(map, to_string(key))
    end)
  end

  defp fetch_value(_map, _keys), do: nil

  defp fetch_string(map, keys) do
    case fetch_value(map, keys) do
      value when is_binary(value) -> String.trim(value)
      value when is_atom(value) -> Atom.to_string(value)
      value when is_integer(value) -> Integer.to_string(value)
      value when is_float(value) -> Float.to_string(value)
      _ -> nil
    end
  end

  defp parse_integer(nil), do: nil
  defp parse_integer(value) when is_integer(value), do: value
  defp parse_integer(value) when is_float(value), do: round(value)

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp parse_metric_value(nil), do: :error
  defp parse_metric_value(value) when is_number(value), do: {:ok, value / 1}

  defp parse_metric_value(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> {:ok, parsed}
      :error -> :error
    end
  end

  defp parse_metric_value(_), do: :error

  defp parse_metric_number(nil), do: nil
  defp parse_metric_number(value) when is_number(value), do: value / 1

  defp parse_metric_number(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp parse_metric_number(_), do: nil

  defp ingest_registered_handlers(payload, status, observed_at, actor) do
    Enum.each(plugin_result_handlers(), fn handler ->
      if handler_supports?(handler, payload, status) do
        case ingest_handler(handler, payload, status, observed_at, actor) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Plugin result handler #{inspect(handler_module(handler))} failed: #{inspect(reason)}"
            )
        end
      end
    end)

    :ok
  end

  defp handler_supports?({handler, _opts}, payload, status) when is_atom(handler) do
    handler_supports?(handler, payload, status)
  end

  defp handler_supports?(handler, payload, status) when is_atom(handler) do
    cond do
      function_exported?(handler, :supports?, 2) ->
        handler.supports?(payload, status)

      function_exported?(handler, :supports?, 1) ->
        handler.supports?(payload)

      true ->
        true
    end
  rescue
    e ->
      Logger.warning(
        "Plugin result handler #{inspect(handler)} support check failed: #{inspect(e)}"
      )

      false
  end

  defp handler_supports?(_handler, _payload, _status), do: false

  defp ingest_handler(handler, payload, status, observed_at, actor) when is_atom(handler) do
    handler.ingest(payload, status, actor: actor, observed_at: observed_at)
  rescue
    e ->
      {:error, e}
  end

  defp ingest_handler({handler, opts}, payload, status, observed_at, actor)
       when is_atom(handler) do
    handler.ingest(payload, status, Keyword.merge(opts, actor: actor, observed_at: observed_at))
  rescue
    e ->
      {:error, e}
  end

  defp ingest_handler(handler, _payload, _status, _observed_at, _actor) do
    {:error, {:invalid_handler, handler}}
  end

  defp handler_module({handler, _opts}), do: handler
  defp handler_module(handler), do: handler

  defp plugin_result_handlers do
    Application.get_env(
      :serviceradar_core,
      :plugin_result_handlers,
      platform_contract_handlers()
    )
  end

  defp platform_contract_handlers do
    [
      DeviceDiscoveryIngestor,
      HypervisorEnrichmentIngestor,
      ProxmoxEnrichmentIngestor,
      BatchIngestor,
      ThreatIntelPluginIngestor,
      EventIngestor,
      InventoryIngestor
    ]
  end

  defp plugin_status_available(nil), do: false

  defp plugin_status_available(status) do
    case String.upcase(to_string(status)) do
      "OK" -> true
      "WARNING" -> true
      "CRITICAL" -> false
      "UNKNOWN" -> false
      _ -> false
    end
  end
end
