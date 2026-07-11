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
  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Observability.ServiceStateRegistry
  alias ServiceRadar.Observability.ServiceStatus
  alias ServiceRadar.Observability.ThreatIntelPluginIngestor
  alias ServiceRadar.WifiMap.BatchIngestor

  require Ash.Query
  require Logger

  @handler_error_max_bytes 1_000
  @handler_error_component_max_bytes 512
  @private_key_pattern ~r/-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----.*?-----END(?: [A-Z0-9]+)? PRIVATE KEY-----/su
  @bearer_value_pattern ~r/\b(Bearer)\s+[^\s,}\]]+/iu
  @sensitive_assignment_pattern ~r/((?:api[_ -]?(?:key|token)|access[_ -]?(?:key|token)|refresh[_ -]?token|bearer[_ -]?token|client[_ -]?secret|private[_ -]?key|credentials?|password|secret|token)\s*(?:=>|:|=)\s*)("[^"]*"|'[^']*'|[^\s,}\]]+)/iu
  @sensitive_quoted_value_pattern ~r/\b((?:private[_ -]?key|credentials?|token)\s+)("[^"]*"|'[^']*')/iu
  @sensitive_bare_value_pattern ~r/\b((?:private[_ -]?key|credentials?|token)\s+)([A-Za-z0-9_.\/+\-=:]{8,})/iu

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

    case insert_status(status_row, actor) do
      :ok ->
        case ingest_registered_handlers(payload, status, observed_at, actor) do
          :ok ->
            case persist_handler_success(status_row, payload, actor) do
              :ok ->
                :ok

              {:error, persistence_error} ->
                error_text = handler_error_text(persistence_error)
                Logger.error("Plugin result handler success persistence failed: #{error_text}")
                {:error, {:plugin_result_handler_success_persistence_failed, error_text}}
            end

          {:error, {:plugin_result_handlers_failed, errors}} = handler_error ->
            case persist_handler_failure(status_row, payload, errors, actor) do
              :ok ->
                handler_error

              {:error, persistence_error_text} ->
                {:error,
                 {:plugin_result_handler_failure_persistence_failed, errors,
                  persistence_error_text}}
            end
        end

      {:error, persistence_error} ->
        error_text = handler_error_text(persistence_error)
        Logger.error("Plugin result status persistence failed: #{error_text}")
        {:error, {:plugin_result_status_persistence_failed, error_text}}
    end
  rescue
    e ->
      error_text = handler_error_text(e)
      Logger.error("Plugin result ingest failed: #{error_text}")
      {:error, {:plugin_result_ingest_failed, error_text}}
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
    ServiceStatus
    |> Ash.Changeset.for_create(:insert_once, row, actor: actor)
    |> Ash.create(domain: ServiceRadar.Observability)
    |> case do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
      other -> {:error, other}
    end
  end

  defp upsert_current_state(row) when is_map(row) do
    state_registry().upsert_from_status_strict(%{
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
    errors =
      Enum.reduce(plugin_result_handlers(), [], fn handler, errors ->
        case handler_support(handler, payload, status) do
          {:ok, true} ->
            case ingest_handler(handler, payload, status, observed_at, actor) do
              :ok ->
                errors

              {:error, reason} ->
                add_handler_failure(errors, handler, reason)

              other ->
                add_handler_failure(errors, handler, {:unexpected_handler_result, other})
            end

          {:ok, false} ->
            errors

          {:error, reason} ->
            add_handler_failure(errors, handler, reason)
        end
      end)

    case Enum.reverse(errors) do
      [] -> :ok
      errors -> {:error, {:plugin_result_handlers_failed, errors}}
    end
  end

  defp add_handler_failure(errors, handler, reason) do
    error_text = handler_error_text(reason)
    log_handler_failure(handler, error_text)
    [{handler_module(handler), error_text} | errors]
  end

  defp log_handler_failure(handler, error_text) do
    Logger.warning(
      "Plugin result handler #{inspect(handler_module(handler))} failed: #{error_text}"
    )
  end

  defp persist_handler_failure(status_row, payload, errors, actor) do
    failure_row = handler_failure_status_row(status_row, payload, errors)

    with :ok <- insert_status(failure_row, actor),
         {:ok, success_recorded?} <- handler_success_recorded?(status_row, actor),
         :ok <- persist_failure_state(status_row, failure_row, payload, actor, success_recorded?) do
      :ok
    else
      {:error, reason} ->
        error_text = handler_error_text(reason)
        Logger.error("Plugin result handler failure status persistence failed: #{error_text}")

        {:error, error_text}
    end
  end

  defp persist_failure_state(status_row, _failure_row, payload, actor, true) do
    persist_handler_recovery(status_row, payload, actor)
  end

  defp persist_failure_state(_status_row, failure_row, _payload, _actor, false) do
    upsert_current_state(failure_row)
  end

  defp persist_handler_success(status_row, payload, actor) do
    with {:ok, failure_recorded?} <- handler_failure_recorded?(status_row, actor) do
      if failure_recorded? do
        persist_handler_recovery(status_row, payload, actor)
      else
        upsert_current_state(status_row)
      end
    end
  end

  defp persist_handler_recovery(status_row, payload, actor) do
    recovery_row = handler_recovery_status_row(status_row, payload)

    with :ok <- insert_status(recovery_row, actor) do
      upsert_current_state(recovery_row)
    end
  end

  defp handler_failure_status_row(status_row, payload, errors) do
    failed_at = handler_failure_timestamp(status_row.timestamp)
    handlers = Enum.map(errors, fn {handler, _error_text} -> handler_label(handler) end)
    message = "Plugin result downstream ingest failed: #{Enum.join(handlers, ", ")}"

    details =
      FieldParser.encode_json(%{
        "status" => "CRITICAL",
        "summary" => message,
        "reported_result" => payload,
        "downstream_ingest" => %{
          "status" => "failed",
          "handlers" =>
            Enum.map(errors, fn {handler, error_text} ->
              %{
                "handler" => handler_label(handler),
                "error" => error_text
              }
            end)
        }
      })

    %{
      status_row
      | timestamp: failed_at,
        created_at: failed_at,
        available: false,
        message: message,
        details: details
    }
  end

  defp handler_failure_timestamp(%DateTime{} = observed_at),
    do: DateTime.add(observed_at, 1, :microsecond)

  defp handler_recovery_status_row(status_row, payload) do
    recovered_at = handler_recovery_timestamp(status_row.timestamp)

    details =
      FieldParser.encode_json(%{
        "status" => fetch_string(payload, ["status"]),
        "summary" => status_row.message,
        "reported_result" => payload,
        "downstream_ingest" => %{
          "status" => "succeeded",
          "recovered_from_failure" => true
        }
      })

    %{
      status_row
      | timestamp: recovered_at,
        created_at: recovered_at,
        details: details
    }
  end

  defp handler_recovery_timestamp(%DateTime{} = observed_at),
    do: DateTime.add(observed_at, 2, :microsecond)

  defp handler_failure_recorded?(status_row, actor) do
    handler_marker_recorded?(
      status_row,
      handler_failure_timestamp(status_row.timestamp),
      "failed",
      actor
    )
  end

  defp handler_success_recorded?(status_row, actor) do
    with {:ok, recovery_recorded?} <-
           handler_marker_recorded?(
             status_row,
             handler_recovery_timestamp(status_row.timestamp),
             "succeeded",
             actor
           ) do
      if recovery_recorded? do
        {:ok, true}
      else
        successful_current_state_recorded?(status_row, actor)
      end
    end
  end

  defp handler_marker_recorded?(status_row, timestamp, marker_status, actor) do
    gateway_id = status_row.gateway_id
    service_name = status_row.service_name

    ServiceStatus
    |> Ash.Query.filter(
      timestamp == ^timestamp and gateway_id == ^gateway_id and service_name == ^service_name
    )
    |> Ash.read_one(actor: actor, domain: ServiceRadar.Observability)
    |> case do
      {:ok, nil} -> {:ok, false}
      {:ok, %ServiceStatus{details: details}} -> {:ok, handler_marker?(details, marker_status)}
      {:error, error} -> {:error, error}
      other -> {:error, {:unexpected_service_status_lookup_result, other}}
    end
  end

  defp handler_marker?(details, marker_status) when is_binary(details) do
    case Jason.decode(details) do
      {:ok, %{"downstream_ingest" => %{"status" => ^marker_status}}} -> true
      _ -> false
    end
  end

  defp handler_marker?(_details, _marker_status), do: false

  defp successful_current_state_recorded?(status_row, actor) do
    ServiceState
    |> Ash.Query.filter(
      agent_id == ^status_row.agent_id and partition == ^status_row.partition and
        service_type == ^status_row.service_type and service_name == ^status_row.service_name
    )
    |> Ash.read(actor: actor, domain: ServiceRadar.Observability)
    |> case do
      {:ok, states} when is_list(states) ->
        {:ok, Enum.any?(states, &successful_current_state?(&1, status_row))}

      {:error, error} ->
        {:error, error}

      other ->
        {:error, {:unexpected_service_state_lookup_result, other}}
    end
  end

  defp successful_current_state?(%ServiceState{} = state, status_row) do
    DateTime.compare(state.last_observed_at, status_row.timestamp) == :eq and
      state.available == status_row.available and state.message == status_row.message
  end

  defp handler_label(handler) when is_atom(handler) do
    handler
    |> Module.split()
    |> Enum.join(".")
  end

  defp handler_label(handler), do: inspect(handler)

  defp handler_error_text(reason) do
    reason
    |> redact_handler_error_values()
    |> render_handler_error()
    |> sanitize_handler_error()
    |> truncate_utf8(@handler_error_max_bytes)
  rescue
    _ -> "handler error unavailable"
  end

  defp redact_handler_error_values(%{__exception__: true} = error), do: error

  defp redact_handler_error_values(%{__struct__: module} = value) do
    {:struct, module, value |> Map.from_struct() |> redact_handler_error_values()}
  end

  defp redact_handler_error_values(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      if sensitive_handler_error_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, redact_handler_error_values(nested_value)}
      end
    end)
  end

  defp redact_handler_error_values({key, value}) when is_atom(key) or is_binary(key) do
    if sensitive_handler_error_key?(key) do
      {key, "[REDACTED]"}
    else
      {key, redact_handler_error_values(value)}
    end
  end

  defp redact_handler_error_values(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&redact_handler_error_values/1)
    |> List.to_tuple()
  end

  defp redact_handler_error_values(value) when is_list(value) do
    Enum.map(value, &redact_handler_error_values/1)
  end

  defp redact_handler_error_values(value) when is_binary(value) do
    truncate_utf8(value, @handler_error_component_max_bytes)
  end

  defp redact_handler_error_values(value), do: value

  defp sensitive_handler_error_key?(key) when is_atom(key) or is_binary(key) do
    key
    |> to_string()
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
    |> String.downcase()
    |> String.replace("-", "_")
    |> then(fn normalized ->
      normalized in [
        "api_key",
        "apikey",
        "api_token",
        "access_token",
        "access_key",
        "authorization",
        "bearer",
        "bearer_token",
        "client_secret",
        "credential",
        "credentials",
        "password",
        "private_key",
        "privatekey",
        "refresh_token",
        "secret"
      ] or normalized == "token" or
        String.starts_with?(normalized, ["token_", "credential_"]) or
        String.contains?(normalized, ["credential", "private_key", "privatekey"]) or
        String.ends_with?(normalized, ["_password", "_secret", "_token", "_access_key"])
    end)
  end

  defp sensitive_handler_error_key?(_key), do: false

  defp render_handler_error({context, %{__exception__: true} = error}) do
    "#{context}: #{Exception.message(error)}"
  end

  defp render_handler_error(%{__exception__: true} = error), do: Exception.message(error)

  defp render_handler_error(reason) do
    inspect(reason,
      limit: 20,
      printable_limit: @handler_error_max_bytes * 2,
      charlists: :as_lists
    )
  end

  defp sanitize_handler_error(text) when is_binary(text) do
    text
    |> String.replace(@private_key_pattern, "[REDACTED PRIVATE KEY]")
    |> String.replace(@bearer_value_pattern, "\\1 [REDACTED]")
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.replace(@sensitive_assignment_pattern, "\\1[REDACTED]")
    |> String.replace(@sensitive_quoted_value_pattern, "\\1[REDACTED]")
    |> String.replace(@sensitive_bare_value_pattern, "\\1[REDACTED]")
    |> String.replace(~r{://[^/\s:@]+:[^@\s/]+@}u, "://[REDACTED]@")
    |> String.trim()
  end

  defp truncate_utf8(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  defp truncate_utf8(text, max_bytes) do
    text
    |> binary_part(0, max_bytes)
    |> trim_incomplete_utf8()
  end

  defp trim_incomplete_utf8(text) do
    if String.valid?(text),
      do: text,
      else: trim_incomplete_utf8(binary_part(text, 0, byte_size(text) - 1))
  end

  defp handler_support({handler, _opts}, payload, status) when is_atom(handler) do
    handler_support(handler, payload, status)
  end

  defp handler_support(handler, payload, status) when is_atom(handler) do
    supported =
      cond do
        function_exported?(handler, :supports?, 2) -> handler.supports?(payload, status)
        function_exported?(handler, :supports?, 1) -> handler.supports?(payload)
        true -> true
      end

    case supported do
      true -> {:ok, true}
      false -> {:ok, false}
      other -> {:error, {:unexpected_support_result, other}}
    end
  rescue
    error -> {:error, {:support_check_failed, error}}
  catch
    kind, reason -> {:error, {:support_check_failed, {kind, reason}}}
  end

  defp handler_support(handler, _payload, _status), do: {:error, {:invalid_handler, handler}}

  defp ingest_handler(handler, payload, status, observed_at, actor) when is_atom(handler) do
    handler.ingest(payload, status, actor: actor, observed_at: observed_at)
  rescue
    e ->
      {:error, e}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  defp ingest_handler({handler, opts}, payload, status, observed_at, actor)
       when is_atom(handler) do
    handler.ingest(payload, status, Keyword.merge(opts, actor: actor, observed_at: observed_at))
  rescue
    e ->
      {:error, e}
  catch
    kind, reason ->
      {:error, {kind, reason}}
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

  defp state_registry do
    Application.get_env(
      :serviceradar_core,
      :plugin_result_state_registry,
      ServiceStateRegistry
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
