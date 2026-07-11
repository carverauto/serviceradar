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
  alias ServiceRadar.Repo
  alias ServiceRadar.WifiMap.BatchIngestor

  require Ash.Query
  require Logger

  @handler_error_max_bytes 1_000
  @handler_error_component_max_bytes 512
  @handler_provenance_version 1
  # A service observation owns at most 256 microseconds of synthetic history.
  # Allocation fails instead of crossing the next genuine observation.
  @handler_marker_max_generations 128
  @handler_marker_window_microseconds @handler_marker_max_generations * 2
  @handler_marker_insert_attempts 4
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
        handlers = plugin_result_handlers()

        case ingest_registered_handlers(handlers, payload, status, observed_at, actor) do
          :ok ->
            case persist_handler_success(status_row, payload, handlers, actor) do
              :ok ->
                :ok

              {:error, persistence_error} ->
                error_text = handler_error_text(persistence_error)
                Logger.error("Plugin result handler success persistence failed: #{error_text}")
                {:error, {:plugin_result_handler_success_persistence_failed, error_text}}
            end

          {:error, {:plugin_result_handlers_failed, errors}} = handler_error ->
            case persist_handler_failure(status_row, payload, errors, handlers, actor) do
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

  defp insert_status_with_notifications(row, actor) do
    ServiceStatus
    |> Ash.Changeset.for_create(:insert_once, row, actor: actor)
    |> Ash.create(domain: ServiceRadar.Observability, return_notifications?: true)
    |> case do
      {:ok, record, notifications} ->
        if Ash.Resource.get_metadata(record, :upsert_skipped) == true do
          {:ok, []}
        else
          {:ok, notifications}
        end

      {:error, error} ->
        {:error, error}

      other ->
        {:error, {:unexpected_service_status_insert_result, other}}
    end
  end

  defp upsert_current_state_with_notifications(row) when is_map(row) do
    registry = state_registry()

    attrs = %{
      agent_id: Map.get(row, :agent_id),
      gateway_id: Map.get(row, :gateway_id),
      partition: Map.get(row, :partition),
      service_type: Map.get(row, :service_type),
      service_name: Map.get(row, :service_name),
      available: Map.get(row, :available),
      message: Map.get(row, :details) || Map.get(row, :message),
      timestamp: Map.get(row, :timestamp)
    }

    if Code.ensure_loaded?(registry) and
         function_exported?(registry, :upsert_from_status_strict_with_notifications, 1) do
      registry.upsert_from_status_strict_with_notifications(attrs)
    else
      case registry.upsert_from_status_strict(attrs) do
        :ok -> {:ok, []}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_service_state_upsert_result, other}}
      end
    end
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

  defp ingest_registered_handlers(handlers, payload, status, observed_at, actor) do
    errors =
      Enum.reduce(handlers, [], fn handler, errors ->
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

  defp persist_handler_failure(status_row, payload, errors, handlers, actor) do
    provenance = handler_set_provenance(handlers)

    result =
      with_handler_marker_lock(status_row, fn ->
        do_persist_handler_failure(
          status_row,
          payload,
          errors,
          provenance,
          actor,
          @handler_marker_insert_attempts
        )
      end)

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        error_text = handler_error_text(reason)
        Logger.error("Plugin result handler failure status persistence failed: #{error_text}")

        {:error, error_text}
    end
  end

  defp do_persist_handler_failure(status_row, payload, errors, provenance, actor, attempts) do
    with {:ok, marker} <- handler_marker_context(status_row, provenance, actor) do
      failure_row = handler_failure_status_row(status_row, payload, errors, marker)

      case insert_handler_marker(failure_row, marker, "failed", actor) do
        {:ok, marker_notifications} ->
          with {:ok, state_notifications} <-
                 persist_failure_state(status_row, failure_row, payload, marker, actor) do
            {:ok, marker_notifications ++ state_notifications}
          end

        {:error, :handler_marker_collision} when attempts > 1 ->
          do_persist_handler_failure(
            status_row,
            payload,
            errors,
            provenance,
            actor,
            attempts - 1
          )

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp persist_failure_state(
         status_row,
         _failure_row,
         payload,
         %{success_recorded?: true} = marker,
         actor
       ) do
    persist_handler_success_state(
      status_row,
      payload,
      %{marker | failure_recorded?: true},
      actor
    )
  end

  defp persist_failure_state(_status_row, failure_row, _payload, _marker, _actor) do
    upsert_current_state_with_notifications(failure_row)
  end

  defp persist_handler_success(status_row, payload, handlers, actor) do
    provenance = handler_set_provenance(handlers)

    with_handler_marker_lock(status_row, fn ->
      with {:ok, marker} <- handler_marker_context(status_row, provenance, actor) do
        persist_handler_success_state(status_row, payload, marker, actor)
      end
    end)
  end

  defp persist_handler_success_state(status_row, payload, marker, actor) do
    success_row = handler_success_status_row(status_row, payload, marker)

    with {:ok, history_notifications} <-
           maybe_insert_handler_recovery(success_row, marker, actor),
         {:ok, state_notifications} <- upsert_current_state_with_notifications(success_row) do
      {:ok, history_notifications ++ state_notifications}
    end
  end

  defp maybe_insert_handler_recovery(success_row, %{failure_recorded?: true} = marker, actor) do
    insert_handler_marker(success_row, marker, "succeeded", actor)
  end

  defp maybe_insert_handler_recovery(_success_row, _marker, _actor), do: {:ok, []}

  defp handler_failure_status_row(status_row, payload, errors, marker) do
    handlers = Enum.map(errors, fn {handler, _error_text} -> handler_label(handler) end)
    message = "Plugin result downstream ingest failed: #{Enum.join(handlers, ", ")}"

    details =
      FieldParser.encode_json(%{
        "status" => "CRITICAL",
        "summary" => message,
        "reported_result" => payload,
        "downstream_ingest" => %{
          "status" => "failed",
          "generation" => marker.generation,
          "handler_set" => marker.handler_set,
          "observation_timestamp" => marker.observation_timestamp,
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
      | timestamp: marker.failure_at,
        created_at: marker.failure_at,
        available: false,
        message: message,
        details: details
    }
  end

  defp handler_success_status_row(status_row, payload, marker) do
    details =
      FieldParser.encode_json(%{
        "status" => fetch_string(payload, ["status"]),
        "summary" => status_row.message,
        "reported_result" => payload,
        "downstream_ingest" => %{
          "status" => "succeeded",
          "generation" => marker.generation,
          "handler_set" => marker.handler_set,
          "observation_timestamp" => marker.observation_timestamp,
          "recovered_from_failure" => marker.failure_recorded?
        }
      })

    %{
      status_row
      | timestamp: marker.success_at,
        created_at: marker.success_at,
        details: details
    }
  end

  defp insert_handler_marker(row, marker, marker_status, actor) do
    with {:ok, notifications} <- insert_status_with_notifications(row, actor),
         {:ok, persisted_marker} <- handler_marker_at(row, actor) do
      if marker_matches?(persisted_marker, marker, marker_status) do
        {:ok, notifications}
      else
        {:error, :handler_marker_collision}
      end
    end
  end

  defp handler_marker_at(row, actor) do
    timestamp = row.timestamp
    gateway_id = row.gateway_id
    service_name = row.service_name

    ServiceStatus
    |> Ash.Query.filter(
      timestamp == ^timestamp and gateway_id == ^gateway_id and service_name == ^service_name
    )
    |> Ash.read_one(actor: actor, domain: ServiceRadar.Observability)
    |> case do
      {:ok, nil} -> {:ok, nil}
      {:ok, %ServiceStatus{} = status} -> {:ok, parse_handler_marker(status)}
      {:error, error} -> {:error, error}
      other -> {:error, {:unexpected_service_status_lookup_result, other}}
    end
  end

  defp marker_matches?(persisted, marker, marker_status) when is_map(persisted) do
    persisted.status == marker_status and persisted.generation == marker.generation and
      persisted.observation_timestamp == marker.observation_timestamp and
      persisted.handler_set == marker.handler_set
  end

  defp marker_matches?(_persisted, _marker, _marker_status), do: false

  defp with_handler_marker_lock(status_row, fun) when is_function(fun, 0) do
    lock_identity =
      Jason.encode!([
        status_row.gateway_id,
        status_row.service_name,
        DateTime.to_iso8601(status_row.timestamp)
      ])

    case Repo.transaction(fn ->
           case Repo.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
                  lock_identity
                ]) do
             {:ok, _result} ->
               case fun.() do
                 {:ok, notifications} when is_list(notifications) ->
                   {:ok, notifications}

                 {:error, reason} ->
                   Repo.rollback(reason)

                 other ->
                   Repo.rollback({:unexpected_handler_marker_result, other})
               end

             {:error, reason} ->
               Repo.rollback({:handler_marker_lock_acquire_failed, reason})

             other ->
               Repo.rollback({:unexpected_handler_marker_lock_result, other})
           end
         end) do
      {:ok, {:ok, notifications}} ->
        _ = Ash.Notifier.notify(notifications)
        :ok

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_handler_marker_transaction_result, other}}
    end
  end

  defp handler_marker_context(status_row, provenance, actor) do
    with {:ok, rows} <- handler_marker_rows(status_row, actor),
         {:ok, state} <- handler_marker_state(status_row, actor) do
      observation_timestamp = DateTime.to_iso8601(status_row.timestamp)

      markers =
        (rows ++ List.wrap(state))
        |> Enum.map(&parse_handler_marker/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(fn marker ->
          marker.observation_timestamp == observation_timestamp and
            valid_marker_timestamp?(marker, status_row.timestamp)
        end)

      current_markers = Enum.filter(markers, &(&1.handler_set == provenance))
      failure_recorded? = latest_handler_history_failed?(markers)

      case current_marker_generation(current_markers) do
        {:ok, generation} ->
          generation_markers =
            Enum.filter(current_markers, &(&1.generation == generation))

          build_marker_context(
            status_row,
            provenance,
            observation_timestamp,
            generation,
            generation_markers,
            failure_recorded?,
            rows
          )

        {:error, reason} ->
          {:error, reason}

        :none ->
          allocate_marker_context(
            status_row,
            provenance,
            observation_timestamp,
            markers,
            failure_recorded?,
            rows
          )
      end
    end
  end

  defp handler_marker_rows(status_row, actor) do
    observed_at = status_row.timestamp
    upper_bound = DateTime.add(observed_at, @handler_marker_window_microseconds, :microsecond)
    gateway_id = status_row.gateway_id
    service_name = status_row.service_name

    ServiceStatus
    |> Ash.Query.filter(
      timestamp > ^observed_at and timestamp <= ^upper_bound and gateway_id == ^gateway_id and
        service_name == ^service_name
    )
    |> Ash.read(actor: actor, domain: ServiceRadar.Observability)
    |> case do
      {:ok, rows} when is_list(rows) -> {:ok, rows}
      {:error, error} -> {:error, error}
      other -> {:error, {:unexpected_service_status_history_result, other}}
    end
  end

  defp handler_marker_state(status_row, actor) do
    agent_id = status_row.agent_id
    gateway_id = status_row.gateway_id
    partition = status_row.partition
    service_type = status_row.service_type
    service_name = status_row.service_name

    ServiceState
    |> Ash.Query.filter(
      agent_id == ^agent_id and gateway_id == ^gateway_id and partition == ^partition and
        service_type == ^service_type and service_name == ^service_name and state == "active"
    )
    |> Ash.read_one(actor: actor, domain: ServiceRadar.Observability)
    |> case do
      {:ok, state} -> {:ok, state}
      {:error, error} -> {:error, error}
      other -> {:error, {:unexpected_service_state_lookup_result, other}}
    end
  end

  defp current_marker_generation([]), do: :none

  defp current_marker_generation(markers) do
    generation = markers |> Enum.map(& &1.generation) |> Enum.max()

    if generation <= @handler_marker_max_generations do
      {:ok, generation}
    else
      {:error, :handler_marker_window_exhausted}
    end
  end

  defp allocate_marker_context(
         status_row,
         provenance,
         observation_timestamp,
         markers,
         failure_recorded?,
         rows
       ) do
    occupied_offsets =
      MapSet.new(rows, &DateTime.diff(&1.timestamp, status_row.timestamp, :microsecond))

    max_generation = markers |> Enum.map(& &1.generation) |> Enum.max(fn -> 0 end)
    next_observation_offset = next_genuine_observation_offset(rows, status_row.timestamp)

    generation =
      find_available_generation(max_generation, occupied_offsets, next_observation_offset)

    case generation do
      nil ->
        {:error, :handler_marker_window_exhausted}

      generation ->
        build_marker_context(
          status_row,
          provenance,
          observation_timestamp,
          generation,
          [],
          failure_recorded?,
          rows
        )
    end
  end

  defp find_available_generation(max_generation, _occupied_offsets, _next_observation_offset)
       when max_generation >= @handler_marker_max_generations, do: nil

  defp find_available_generation(max_generation, occupied_offsets, next_observation_offset) do
    Enum.find((max_generation + 1)..@handler_marker_max_generations, fn generation ->
      failure_offset = marker_offset(generation, "failed")
      success_offset = marker_offset(generation, "succeeded")

      success_offset < next_observation_offset and
        not MapSet.member?(occupied_offsets, failure_offset) and
        not MapSet.member?(occupied_offsets, success_offset)
    end)
  end

  defp build_marker_context(
         status_row,
         provenance,
         observation_timestamp,
         generation,
         current_markers,
         failure_recorded?,
         rows
       ) do
    failure_at = marker_timestamp(status_row.timestamp, generation, "failed")
    success_at = marker_timestamp(status_row.timestamp, generation, "succeeded")
    next_observation_at = next_genuine_observation_at(rows, status_row.timestamp)

    if generation > @handler_marker_max_generations or
         (next_observation_at && DateTime.compare(success_at, next_observation_at) != :lt) do
      {:error, :handler_marker_window_exhausted}
    else
      {:ok,
       %{
         generation: generation,
         handler_set: provenance,
         observation_timestamp: observation_timestamp,
         failure_at: failure_at,
         success_at: success_at,
         failure_recorded?: failure_recorded?,
         success_recorded?:
           Enum.any?(current_markers, fn marker ->
             marker.status == "succeeded" and marker.source == :state
           end)
       }}
    end
  end

  defp latest_handler_history_failed?(markers) do
    markers
    |> Enum.filter(&(&1.source == :history))
    |> Enum.max_by(&DateTime.to_unix(&1.timestamp, :microsecond), fn -> nil end)
    |> case do
      %{status: "failed"} -> true
      _ -> false
    end
  end

  defp next_genuine_observation_offset(rows, observed_at) do
    case next_genuine_observation_at(rows, observed_at) do
      nil -> @handler_marker_window_microseconds + 1
      timestamp -> DateTime.diff(timestamp, observed_at, :microsecond)
    end
  end

  defp next_genuine_observation_at(rows, observed_at) do
    rows
    |> Enum.reject(&synthetic_downstream_marker?(&1, observed_at))
    |> Enum.map(& &1.timestamp)
    |> Enum.min_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp synthetic_downstream_marker?(%ServiceStatus{} = status, observed_at) do
    case parse_handler_marker(status) do
      nil ->
        false

      marker ->
        marker.observation_timestamp == DateTime.to_iso8601(observed_at) and
          valid_marker_timestamp?(marker, observed_at)
    end
  end

  defp synthetic_downstream_marker?(_status, _observed_at), do: false

  defp parse_handler_marker(%ServiceStatus{details: details, timestamp: timestamp}) do
    parse_handler_marker_details(details, timestamp, :history)
  end

  defp parse_handler_marker(%ServiceState{details: details, last_observed_at: timestamp}) do
    parse_handler_marker_details(details, timestamp, :state)
  end

  defp parse_handler_marker(_status), do: nil

  defp parse_handler_marker_details(details, timestamp, source) when is_binary(details) do
    case Jason.decode(details) do
      {:ok,
       %{
         "downstream_ingest" => %{
           "status" => status,
           "generation" => generation,
           "handler_set" => %{"id" => id, "version" => version} = handler_set,
           "observation_timestamp" => observation_timestamp
         }
       }}
      when status in ["failed", "succeeded"] and is_integer(generation) and generation > 0 and
             is_binary(id) and is_integer(version) and is_binary(observation_timestamp) ->
        %{
          status: status,
          generation: generation,
          handler_set: handler_set,
          observation_timestamp: observation_timestamp,
          timestamp: timestamp,
          source: source
        }

      _ ->
        nil
    end
  end

  defp parse_handler_marker_details(_details, _timestamp, _source), do: nil

  defp valid_marker_timestamp?(marker, observed_at) do
    expected_at = marker_timestamp(observed_at, marker.generation, marker.status)
    DateTime.compare(marker.timestamp, expected_at) == :eq
  end

  defp marker_timestamp(observed_at, generation, status) do
    DateTime.add(observed_at, marker_offset(generation, status), :microsecond)
  end

  defp marker_offset(generation, "failed"), do: generation * 2 - 1
  defp marker_offset(generation, "succeeded"), do: generation * 2

  defp handler_set_provenance(handlers) do
    descriptors = Enum.map(handlers, &handler_provenance_descriptor/1)

    %{
      "id" => digest_term({@handler_provenance_version, descriptors}),
      "version" => @handler_provenance_version
    }
  end

  defp handler_provenance_descriptor({handler, opts}) when is_atom(handler) do
    {Atom.to_string(handler), handler_module_version(handler), digest_term(opts)}
  end

  defp handler_provenance_descriptor(handler) when is_atom(handler) do
    {Atom.to_string(handler), handler_module_version(handler), nil}
  end

  defp handler_provenance_descriptor(handler), do: {:invalid_handler, digest_term(handler)}

  defp handler_module_version(handler) do
    case Code.ensure_loaded(handler) do
      {:module, ^handler} -> :md5 |> handler.module_info() |> Base.encode16(case: :lower)
      _ -> "unloaded"
    end
  rescue
    _ -> "unknown"
  end

  defp digest_term(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
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
