defmodule ServiceRadar.Observability.PluginResultIngestor do
  @moduledoc """
  Ingests plugin results (`serviceradar.plugin_result.v1`) into service_status
  and registered platform handlers.

  Numeric plugin metrics are published by the agent gateway to the shared
  JetStream metrics stream as `serviceradar.metric.v1` protobuf envelopes and
  persisted by event_writer. Plugin-result JSON payloads are not a metric
  ingestion path.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.EventIngestor
  alias ServiceRadar.Camera.InventoryIngestor
  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.Inventory.DeviceDiscoveryIngestor
  alias ServiceRadar.Inventory.HypervisorEnrichmentIngestor
  alias ServiceRadar.Inventory.ProxmoxEnrichmentIngestor
  alias ServiceRadar.Inventory.VulnerabilityAdvisoryIngestor
  alias ServiceRadar.Observability.ServiceIdentity
  alias ServiceRadar.Observability.ServiceStateRegistry
  alias ServiceRadar.Observability.ServiceStatus
  alias ServiceRadar.Observability.ThreatIntelPluginIngestor
  alias ServiceRadar.WifiMap.BatchIngestor

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
         :ok <- upsert_current_state(status_row) do
      ingest_registered_handlers(payload, status, observed_at, actor)
    end
  rescue
    e ->
      Logger.error("Plugin result ingest failed: #{inspect(e)}")
      {:error, e}
  end

  def ingest(payload, status) when is_list(payload) do
    payload
    |> Enum.find(&is_map/1)
    |> case do
      nil -> {:error, :invalid_payload}
      entry -> ingest(entry, status)
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
      details: FieldParser.encode_json(payload),
      partition: partition,
      created_at: created_at
    }
  end

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
      VulnerabilityAdvisoryIngestor,
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
