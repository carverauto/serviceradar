defmodule ServiceRadar.Observability.PluginResultIngestor do
  @moduledoc """
  Ingests plugin results (`serviceradar.plugin_result.v1`) into service_status
  and registered platform handlers.

  Numeric plugin metrics are published by the agent gateway to the shared
  JetStream metrics stream as `serviceradar.metric.v1` protobuf envelopes and
  persisted by event_writer. Plugin-result JSON payloads are not a metric
  ingestion path.

  Host-stamped result provenance (assignment, package and module hash) is
  stored with each status row; `ServiceRadar.Observability.PluginResultProvenance`
  documents where it lives and how a rollout health gate reads it.

  Both entry points, `ingest_durable/3` and `ingest/2`, first reduce the result
  and its status with `ServiceRadar.Camera.StreamAddressReduction`, and build
  everything they persist or pass on (status and state rows, the reported payload
  digest, every handler's input, logs) from the reduced values only, so no camera
  stream address or URL userinfo is stored from a plugin result.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.EventIngestor
  alias ServiceRadar.Camera.InventoryIngestor
  alias ServiceRadar.Camera.StreamAddressReduction
  alias ServiceRadar.Dgraph.TransientError
  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.Inventory.DeviceDiscoveryIngestor
  alias ServiceRadar.Inventory.HypervisorEnrichmentIngestor
  alias ServiceRadar.Inventory.ProxmoxEnrichmentIngestor
  alias ServiceRadar.Inventory.ProxmoxSourceScopeResolver
  alias ServiceRadar.Inventory.VulnerabilityAdvisoryIngestor
  alias ServiceRadar.NetworkConfig.PluginIngestor
  alias ServiceRadar.Observability.AdvisoryLocks
  alias ServiceRadar.Observability.PluginResultHandlerOutcome
  alias ServiceRadar.Observability.PluginResultProvenance
  alias ServiceRadar.Observability.PluginResultReportedMarker
  alias ServiceRadar.Observability.PluginResultSlot
  alias ServiceRadar.Observability.ServiceIdentity
  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Observability.ServiceStateRegistry
  alias ServiceRadar.Observability.ServiceStateRegistry.PluginResultStateWinner
  alias ServiceRadar.Observability.ServiceStateRegistry.PluginServiceIdentity
  alias ServiceRadar.Observability.ServiceStateRegistry.PluginState
  alias ServiceRadar.Observability.ServiceStateRegistry.PluginStateContract
  alias ServiceRadar.Observability.ServiceStatus
  alias ServiceRadar.Observability.ServiceStatusPubSub
  alias ServiceRadar.Observability.ThreatIntelPluginIngestor
  alias ServiceRadar.Repo
  alias ServiceRadar.WifiMap.BatchIngestor

  require Ash.Query
  require Logger

  @handler_error_max_bytes 1_000
  @handler_error_component_max_bytes 512
  @handler_provenance_version 1
  @handler_marker_max_generations 128
  @handler_marker_window_microseconds @handler_marker_max_generations * 2
  @handler_marker_insert_attempts 4
  @status_slot_bucket_width_microseconds @handler_marker_window_microseconds + 1
  @reported_status_marker_key "_serviceradar_plugin_result"
  @reported_status_marker_version 1
  @reserved_state_detail_keys [
    @reported_status_marker_key,
    "downstream_ingest",
    "reported_result",
    "status",
    "summary"
  ]
  @private_key_pattern ~r/-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----.*?-----END(?: [A-Z0-9]+)? PRIVATE KEY-----/su
  @unterminated_private_key_pattern ~r/-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----.*\z/su
  @authorization_header_pattern ~r/\b(Authorization\s*:\s*)(?:Basic|Bearer)\s+[^\s,}\]]+/iu
  @bearer_value_pattern ~r/\b(Bearer)\s+[^\s,}\]]+/iu
  @sensitive_assignment_pattern ~r/((?:api[_ -]?(?:key|token)|access[_ -]?(?:key|token)|refresh[_ -]?token|bearer[_ -]?token|client[_ -]?secret|private[_ -]?key|credentials?|password|secret|token)\s*(?:=>|:|=)\s*)("[^"]*"|'[^']*'|[^\s,}\]]+)/iu
  @sensitive_quoted_value_pattern ~r/\b((?:private[_ -]?key|credentials?|token)\s+)("[^"]*"|'[^']*')/iu
  @sensitive_bare_value_pattern ~r/\b((?:private[_ -]?key|credentials?|token)\s+)([A-Za-z0-9_.\/+\-=:]{8,})/iu

  @doc false
  @spec ingest_durable(map() | list(), map(), keyword()) ::
          :ok | {:settled, term()} | {:refused, term()} | {:error, term()}
  def ingest_durable(payload, status, opts \\ [])

  def ingest_durable(payload, status, opts) when is_map(payload) do
    payload = StreamAddressReduction.reduce(payload)
    status = StreamAddressReduction.reduce(status)
    actor = SystemActor.system(:plugin_result_ingestor)
    created_at = DateTime.truncate(DateTime.utc_now(), :microsecond)
    observed_at = resolve_observed_at(payload, status)
    summary = resolve_summary(payload)
    status_label = fetch_string(payload, ["status"])
    available = resolve_available(status, status_label)
    defer_cleanup? = Keyword.get(opts, :defer_artifact_cleanup, true)
    handler_context = %{defer_cleanup?: defer_cleanup?}
    persistence = Keyword.get(opts, :persistence, %{})
    handlers = Keyword.get_lazy(opts, :handlers, fn -> plugin_result_handlers() end)

    remap_fn = Map.get(persistence, :remap_service_name, &remap_service_name/1)
    insert_fn = Map.get(persistence, :insert_status, &insert_status/2)

    case remap_fn.(status) do
      {:ok, remapped_status} ->
        status_row =
          build_status_row(
            payload,
            remapped_status,
            observed_at,
            created_at,
            summary,
            available
          )

        case insert_fn.(status_row, actor) do
          {:ok, reported_status, :inserted} ->
            reported_status
            |> run_handlers_durable(
              payload,
              status,
              observed_at,
              handlers,
              persistence,
              handler_context,
              actor
            )
            |> strip_legacy_errors()

          {:ok, reported_status, :existing} ->
            reported_status
            |> redeliver_durable(
              payload,
              status,
              observed_at,
              handlers,
              persistence,
              handler_context,
              actor
            )
            |> strip_legacy_errors()

          {:error, persistence_error} ->
            maybe_discard_artifacts(defer_cleanup?, payload, status)
            error_text = handler_error_text(persistence_error)
            Logger.error("Plugin result status persistence failed: #{error_text}")
            {:error, {:plugin_result_status_persistence_failed, error_text}}
        end

      {:error, _reason} = error ->
        maybe_discard_artifacts(defer_cleanup?, payload, status)
        error
    end
  rescue
    e ->
      maybe_discard_artifacts(
        Keyword.get(opts, :defer_artifact_cleanup, true),
        StreamAddressReduction.reduce(payload),
        StreamAddressReduction.reduce(status)
      )

      error_text = handler_error_text(e)
      Logger.error("Plugin result ingest failed: #{error_text}")
      {:error, {:plugin_result_ingest_failed, error_text}}
  end

  def ingest_durable(_payload, _status, _opts),
    do: {:refused, {:invalid_plugin_result_payload, %{}}}

  @spec ingest(map() | list(), map()) :: :ok | {:error, term()}
  def ingest(payload, status) when is_map(payload) do
    payload = StreamAddressReduction.reduce(payload)
    status = StreamAddressReduction.reduce(status)
    handler_context = %{defer_cleanup?: false}
    actor = SystemActor.system(:plugin_result_ingestor)
    created_at = DateTime.truncate(DateTime.utc_now(), :microsecond)
    observed_at = resolve_observed_at(payload, status)
    summary = resolve_summary(payload)
    status_label = fetch_string(payload, ["status"])
    available = resolve_available(status, status_label)
    handlers = plugin_result_handlers()

    case remap_service_name(status) do
      {:ok, remapped_status} ->
        status_row =
          build_status_row(
            payload,
            remapped_status,
            observed_at,
            created_at,
            summary,
            available
          )

        case insert_status(status_row, actor) do
          {:ok, reported_status, :inserted} ->
            reported_status
            |> run_handlers_durable(
              payload,
              status,
              observed_at,
              handlers,
              %{},
              handler_context,
              actor
            )
            |> to_legacy_ingest_result()

          {:ok, reported_status, :existing} ->
            reported_status
            |> redeliver_durable(
              payload,
              status,
              observed_at,
              handlers,
              %{},
              handler_context,
              actor
            )
            |> to_legacy_ingest_result()

          {:error, persistence_error} ->
            PluginIngestor.discard_artifacts(payload, status)
            error_text = handler_error_text(persistence_error)
            Logger.error("Plugin result status persistence failed: #{error_text}")
            {:error, {:plugin_result_status_persistence_failed, error_text}}
        end

      {:error, _reason} = error ->
        PluginIngestor.discard_artifacts(payload, status)
        error
    end
  rescue
    e ->
      PluginIngestor.discard_artifacts(
        StreamAddressReduction.reduce(payload),
        StreamAddressReduction.reduce(status)
      )

      error_text = handler_error_text(e)
      Logger.error("Plugin result ingest failed: #{error_text}")
      {:error, {:plugin_result_ingest_failed, error_text}}
  end

  def ingest(payload, status) when is_list(payload) do
    payload
    |> Enum.filter(&is_map/1)
    |> case do
      [] ->
        {:error, :invalid_payload}

      [entry | remaining] ->
        result = ingest(entry, status)

        case PluginIngestor.discard_artifacts(
               StreamAddressReduction.reduce(remaining),
               StreamAddressReduction.reduce(status)
             ) do
          :ok ->
            result

          {:error, reason} ->
            {:error,
             {:plugin_result_artifact_cleanup_failed,
              [{PluginIngestor, handler_error_text(reason)}]}}
        end
    end
  end

  def ingest(_payload, _status), do: {:error, :invalid_payload}

  defp maybe_discard_artifacts(true, _payload, _status), do: :ok

  defp maybe_discard_artifacts(false, payload, status) do
    _ = PluginIngestor.discard_artifacts(payload, status)
    :ok
  end

  defp strip_legacy_errors({:refused, reason_tuple, _errors}), do: {:refused, reason_tuple}

  defp strip_legacy_errors({:transient, {failure_kind, _errors}, transient}),
    do: {:error, {failure_kind, transient}}

  defp strip_legacy_errors(other), do: other

  defp to_legacy_ingest_result(:ok), do: :ok
  defp to_legacy_ingest_result({:settled, _reason}), do: :ok

  defp to_legacy_ingest_result({:refused, _reason_tuple, errors}),
    do: {:error, {:plugin_result_handlers_failed, errors}}

  defp to_legacy_ingest_result({:transient, reason, _transient}), do: {:error, reason}

  defp to_legacy_ingest_result({:error, _reason} = error), do: error

  defp run_handlers_durable(
         reported_status,
         payload,
         status,
         observed_at,
         handlers,
         persistence,
         handler_context,
         actor
       ) do
    persist_ok_fn =
      Map.get(persistence, :persist_applied, fn row, p, outcomes, act ->
        persist_handler_success(row, p, outcomes, handlers, act)
      end)

    persist_settled_fn =
      Map.get(persistence, :persist_settled, fn row, p, outcomes, act ->
        persist_handler_settled(row, p, outcomes, handlers, act)
      end)

    persist_err_fn = Map.get(persistence, :persist_failed, &persist_handler_failure/5)
    publish_fn = Map.get(persistence, :publish_status, &publish_committed_status/1)
    attrs = service_status_attributes(reported_status)

    case evaluate_registered_handlers(
           handlers,
           payload,
           status,
           observed_at,
           handler_context,
           actor
         ) do
      {:applied, outcomes} ->
        case persist_ok_fn.(attrs, payload, outcomes, actor) do
          {:ok, status_event} ->
            publish_fn.(status_event || reported_status)
            :ok

          {:error, persistence_error} ->
            publish_fn.(reported_status)
            error_text = handler_error_text(persistence_error)
            Logger.error("Plugin result handler success persistence failed: #{error_text}")
            {:error, {:plugin_result_handler_success_persistence_failed, error_text}}
        end

      {:settled, primary_reason, detail, outcomes} ->
        case persist_settled_fn.(attrs, payload, outcomes, actor) do
          {:ok, status_event} ->
            publish_fn.(status_event || reported_status)
            {:settled, {primary_reason, detail}}

          {:error, persistence_error} ->
            publish_fn.(reported_status)
            error_text = handler_error_text(persistence_error)
            Logger.error("Plugin result handler settled persistence failed: #{error_text}")
            {:error, {:plugin_result_handler_settled_persistence_failed, error_text}}
        end

      {:refused, primary_reason, detail, _outcomes, errors} ->
        case persist_err_fn.(attrs, payload, errors, handlers, actor) do
          {:ok, status_event} ->
            publish_fn.(status_event || reported_status)
            {:refused, {primary_reason, detail}, errors}

          {:error, persistence_error_text} ->
            publish_fn.(reported_status)

            {:error,
             {:plugin_result_handler_failure_persistence_failed, errors, persistence_error_text}}
        end

      {:retryable, failure_kind, outcomes, errors} ->
        case persist_err_fn.(attrs, payload, errors, handlers, actor) do
          {:ok, status_event} ->
            publish_fn.(status_event || reported_status)
            retryable_error(failure_kind, errors, outcomes)

          {:error, persistence_error_text} ->
            publish_fn.(reported_status)

            {:error,
             {:plugin_result_handler_failure_persistence_failed, errors, persistence_error_text}}
        end
    end
  end

  # When every failed handler hit a dependency a later delivery can find available again (a
  # Dgraph timeout or leader election, `ServiceRadar.Dgraph.TransientError`), the durable result
  # carries that typed failure instead of the handler texts, so its caller retries the record
  # as transient rather than as an unexplained failure. The texts are already persisted.
  defp retryable_error(failure_kind, errors, outcomes) do
    case transient_failure(outcomes) do
      %TransientError{} = transient -> {:transient, {failure_kind, errors}, transient}
      nil -> {:error, {failure_kind, errors}}
    end
  end

  defp transient_failure(outcomes) do
    failures =
      for %{outcome: :retryable, raw_error: raw_error} <- outcomes,
          do: TransientError.find(raw_error)

    if failures != [] and Enum.all?(failures), do: hd(failures)
  end

  defp redeliver_durable(
         reported_status,
         payload,
         status,
         observed_at,
         handlers,
         persistence,
         handler_context,
         actor
       ) do
    if server_reported_status?(reported_status) do
      case committed_outcome(service_status_attributes(reported_status), handlers, actor) do
        {:committed, "succeeded"} ->
          :ok

        {:committed, "settled"} ->
          {:settled, {:already_settled, %{}}}

        :not_committed ->
          run_handlers_durable(
            reported_status,
            payload,
            status,
            observed_at,
            handlers,
            persistence,
            handler_context,
            actor
          )
      end
    else
      run_handlers_durable(
        reported_status,
        payload,
        status,
        observed_at,
        handlers,
        persistence,
        handler_context,
        actor
      )
    end
  end

  defp committed_outcome(status_row, handlers, actor) do
    provenance = handler_set_provenance(handlers)
    observation_timestamp = PluginResultSlot.logical_observation_timestamp(status_row)
    payload_digest = reported_status_payload_digest(status_row.details)

    with {:ok, rows} <- handler_marker_rows(status_row, actor),
         {:ok, state} <- handler_marker_state(status_row, actor) do
      (rows ++ List.wrap(state))
      |> Enum.map(&parse_handler_marker/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn marker ->
        marker.observation_timestamp == observation_timestamp and
          marker.payload_digest == payload_digest and
          valid_marker_timestamp?(marker, status_row.timestamp)
      end)
      |> Enum.max_by(&DateTime.to_unix(&1.timestamp, :microsecond), fn -> nil end)
      |> case do
        %{status: marker_status, handler_set: ^provenance}
        when marker_status in ["succeeded", "settled"] ->
          {:committed, marker_status}

        _latest ->
          :not_committed
      end
    else
      {:error, _reason} -> :not_committed
    end
  end

  defp insert_status(row, actor) do
    do_insert_status(row, actor, 0)
  end

  defp do_insert_status(row, actor, attempt) do
    if attempt < PluginResultSlot.insert_attempts() do
      block_base = PluginResultSlot.block_base(row, attempt)
      physical_row = reported_status_physical_row(row, block_base)
      # First attempt probes the physical slot buckets without blocking
      # (a busy bucket means a concurrent writer holds the slot; retry on the
      # next block). Retries take them exclusively, folded into the same
      # ordered statement as the identity locks.
      first_probe? = attempt == 0

      case Repo.transaction(fn ->
             with {:ok, identity_locks} <- status_identity_lock_sequence(physical_row),
                  :ok <- AdvisoryLocks.acquire_ordered(identity_locks),
                  {:ok, existing} <- existing_reported_status(row, actor) do
               case existing do
                 %ServiceStatus{} = status ->
                   {:ok, status, [], :existing}

                 nil ->
                   with :ok <-
                          acquire_status_slot_buckets(
                            physical_row,
                            if(first_probe?, do: :try, else: :exclusive)
                          ),
                        {:ok, status, notifications, origin} <-
                          do_insert_reported_status(row, physical_row, actor) do
                     {:ok, status, notifications, origin}
                   else
                     {:error, reason} -> Repo.rollback(reason)
                   end
               end
             else
               {:error, reason} -> Repo.rollback(reason)
             end
           end) do
        {:ok, {:ok, status, notifications, origin}} ->
          _ = Ash.Notifier.notify(notifications)
          {:ok, status, origin}

        {:error, reason}
        when reason in [:reported_status_slot_collision, :status_slot_lock_busy] ->
          do_insert_status(row, actor, attempt + 1)

        {:error, reason} ->
          {:error, reason}

        other ->
          {:error, {:unexpected_reported_status_transaction_result, other}}
      end
    else
      {:error, :reported_status_allocation_exhausted}
    end
  end

  defp insert_status_with_notifications(row, actor) do
    ServiceStatus
    |> Ash.Changeset.for_create(:insert_once, row, actor: actor)
    |> Ash.create(domain: ServiceRadar.Observability, return_notifications?: true)
    |> case do
      {:ok, record, notifications} ->
        if Ash.Resource.get_metadata(record, :upsert_skipped) == true do
          {:ok, record, []}
        else
          {:ok, record, notifications}
        end

      {:error, error} ->
        {:error, error}

      other ->
        {:error, {:unexpected_service_status_insert_result, other}}
    end
  end

  defp reported_status_physical_row(row, block_base) do
    details =
      case Jason.decode(row.details) do
        {:ok, %{@reported_status_marker_key => marker} = decoded} when is_map(marker) ->
          decoded
          |> Map.put(
            @reported_status_marker_key,
            Map.put(marker, "slot", reported_slot(block_base))
          )
          |> FieldParser.encode_json()

        _ ->
          row.details
      end

    %{row | timestamp: block_base, details: details}
  end

  defp reported_slot(block_base) do
    %{
      "base_timestamp" => DateTime.to_iso8601(block_base),
      "version" => 1,
      "width_microseconds" => PluginResultSlot.block_width_microseconds()
    }
  end

  defp service_status_attributes(%ServiceStatus{} = status) do
    Map.take(status, [
      :timestamp,
      :gateway_id,
      :agent_id,
      :service_id,
      :service_name,
      :service_type,
      :available,
      :message,
      :details,
      :partition,
      :created_at
    ])
  end

  defp existing_reported_status(row, actor) do
    observed_at = PluginResultSlot.logical_observed_at(row)

    lower_bound =
      DateTime.add(
        observed_at,
        -PluginResultSlot.allocation_window_microseconds(),
        :microsecond
      )

    agent_id = row.agent_id
    gateway_id = row.gateway_id
    partition = row.partition
    service_type = row.service_type
    service_name = row.service_name

    ServiceStatus
    |> Ash.Query.filter(
      timestamp >= ^lower_bound and timestamp <= ^observed_at and agent_id == ^agent_id and
        gateway_id == ^gateway_id and partition == ^partition and service_type == ^service_type and
        service_name == ^service_name
    )
    |> Ash.read(actor: actor, domain: ServiceRadar.Observability)
    |> case do
      {:ok, rows} when is_list(rows) -> {:ok, preferred_reported_status(rows, row)}
      {:error, error} -> {:error, error}
      other -> {:error, {:unexpected_existing_reported_status_result, other}}
    end
  end

  defp preferred_reported_status(rows, logical_row) do
    rows
    |> Enum.filter(&reported_status_matches?(&1, logical_row))
    |> Enum.min_by(
      fn status ->
        marker_rank = if parse_reported_status_marker(status), do: 0, else: 1
        {marker_rank, DateTime.to_unix(status.timestamp, :microsecond)}
      end,
      fn -> nil end
    )
  end

  defp do_insert_reported_status(logical_row, physical_row, actor) do
    with {:ok, slot_rows} <- reported_status_overlap_rows(physical_row, actor) do
      case Enum.find(slot_rows, &reported_status_matches?(&1, logical_row)) do
        %ServiceStatus{} = existing ->
          {:ok, existing, [], :existing}

        nil ->
          if Enum.any?(slot_rows, &blocking_status_overlap?(&1, physical_row)) do
            {:error, :reported_status_slot_collision}
          else
            insert_reported_status_at_available_slot(logical_row, physical_row, actor)
          end
      end
    end
  end

  defp insert_reported_status_at_available_slot(logical_row, physical_row, actor) do
    with {:ok, _record, notifications} <-
           insert_status_with_notifications(physical_row, actor),
         {:ok, persisted} <- service_status_at_slot(physical_row, actor) do
      if reported_status_matches?(persisted, logical_row) do
        {:ok, persisted, notifications, :inserted}
      else
        {:error, :reported_status_slot_collision}
      end
    end
  end

  defp reported_status_overlap_rows(row, actor) do
    lower_bound = DateTime.add(row.timestamp, -@handler_marker_window_microseconds, :microsecond)
    upper_bound = DateTime.add(row.timestamp, @handler_marker_window_microseconds, :microsecond)
    gateway_id = row.gateway_id
    service_name = row.service_name

    ServiceStatus
    |> Ash.Query.filter(
      timestamp >= ^lower_bound and timestamp <= ^upper_bound and
        gateway_id == ^gateway_id and service_name == ^service_name
    )
    |> Ash.read(actor: actor, domain: ServiceRadar.Observability)
    |> case do
      {:ok, rows} when is_list(rows) -> {:ok, rows}
      {:error, error} -> {:error, error}
      other -> {:error, {:unexpected_reported_status_slot_result, other}}
    end
  end

  defp blocking_status_overlap?(status, physical_row) do
    DateTime.compare(status.timestamp, physical_row.timestamp) != :lt or
      not is_nil(parse_reported_status_marker(status))
  end

  defp service_status_at_slot(row, actor) do
    timestamp = row.timestamp
    gateway_id = row.gateway_id
    service_name = row.service_name

    ServiceStatus
    |> Ash.Query.filter(
      timestamp == ^timestamp and gateway_id == ^gateway_id and service_name == ^service_name
    )
    |> Ash.read_one(actor: actor, domain: ServiceRadar.Observability)
    |> case do
      {:ok, %ServiceStatus{} = status} -> {:ok, status}
      {:ok, nil} -> {:error, :reported_status_slot_missing}
      {:error, error} -> {:error, error}
      other -> {:error, {:unexpected_reported_status_slot_lookup_result, other}}
    end
  end

  defp upsert_current_state_with_notifications(row) when is_map(row) do
    registry = state_registry()

    case PluginResultStateWinner.select(row) do
      {:ok, candidate} ->
        attrs = %{
          agent_id: Map.get(candidate, :agent_id),
          gateway_id: Map.get(candidate, :gateway_id),
          partition: Map.get(candidate, :partition),
          service_type: Map.get(candidate, :service_type),
          service_name: Map.get(candidate, :service_name),
          available: Map.get(candidate, :available),
          message: Map.get(candidate, :details) || Map.get(candidate, :message),
          timestamp: Map.get(candidate, :timestamp)
        }

        do_upsert_current_state_with_notifications(registry, attrs)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_upsert_current_state_with_notifications(registry, attrs) do
    cond do
      Code.ensure_loaded?(registry) and
          function_exported?(registry, :replace_from_status_with_notifications, 1) ->
        case registry.replace_from_status_with_notifications(attrs) do
          {:ok, notifications, side_effects} ->
            {:ok, notifications, [{registry, side_effects}]}

          {:error, reason} ->
            {:error, reason}

          other ->
            {:error, {:unexpected_service_state_replace_result, other}}
        end

      Code.ensure_loaded?(registry) and
          function_exported?(registry, :upsert_from_status_strict_with_notifications, 1) ->
        case registry.upsert_from_status_strict_with_notifications(attrs) do
          {:ok, notifications, side_effects} ->
            {:ok, notifications, [{registry, side_effects}]}

          {:error, reason} ->
            {:error, reason}

          other ->
            {:error, {:unexpected_service_state_upsert_result, other}}
        end

      true ->
        case registry.upsert_from_status_strict(attrs) do
          :ok -> {:ok, [], []}
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

  # The agent reports every assignment of a plugin under the package name.
  # When the host-stamped provenance names the assignment, core rewrites
  # the service name to that assignment's own identity (bare for the
  # primary assignment, disambiguated for a coexisting one) before any
  # lock, lookup, slot, or marker key is derived from it, so the whole
  # ingest keys per assignment. Results without provenance, or whose
  # assignment no longer resolves, keep the reported name as before.
  defp remap_service_name(status) when is_map(status) do
    provenance = PluginResultProvenance.from_status(status)
    identity = PluginStateContract.status_identity(status)

    case provenance &&
           PluginServiceIdentity.service_name_for_assignment(
             identity.agent_id,
             provenance["assignment_id"]
           ) do
      {:ok, service_name} -> {:ok, put_service_name(status, service_name)}
      {:error, reason} -> {:error, {:plugin_service_identity_resolution_failed, reason}}
      :not_found -> {:ok, status}
      nil -> {:ok, status}
    end
  end

  defp remap_service_name(status), do: {:ok, status}

  defp put_service_name(status, service_name) do
    if Map.has_key?(status, "service_name") and not Map.has_key?(status, :service_name) do
      Map.put(status, "service_name", service_name)
    else
      Map.put(status, :service_name, service_name)
    end
  end

  defp build_status_row(payload, status, observed_at, created_at, summary, available) do
    identity = PluginStateContract.status_identity(status)
    service_id = ServiceIdentity.service_id(identity)

    reported_payload = drop_top_level_keys(payload, [@reported_status_marker_key])
    payload_digest = payload_digest(reported_payload)

    marker =
      PluginResultProvenance.put(
        %{
          "kind" => "reported",
          "observation_timestamp" => DateTime.to_iso8601(observed_at),
          "payload_digest" => payload_digest,
          "service_id" => to_string(service_id),
          "version" => @reported_status_marker_version
        },
        PluginResultProvenance.from_status(status)
      )

    details = Map.put(reported_payload, @reported_status_marker_key, marker)

    %{
      timestamp: observed_at,
      gateway_id: identity.gateway_id,
      agent_id: identity.agent_id,
      service_id: service_id,
      service_name: identity.service_name,
      service_type: identity.service_type,
      available: available,
      message: summary,
      details: FieldParser.encode_json(details),
      partition: identity.partition,
      created_at: created_at
    }
  end

  defp publish_committed_status(status) do
    ServiceStatusPubSub.broadcast_update(status)
  end

  defp fetch_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key) || Map.get(map, to_string(key))
    end)
  end

  defp fetch_value(_map, _keys), do: nil

  defp drop_top_level_keys(map, reserved_keys) when is_map(map) and is_list(reserved_keys) do
    reserved_keys = MapSet.new(reserved_keys)

    Map.reject(map, fn {key, _value} ->
      normalized_key = if is_atom(key), do: Atom.to_string(key), else: key
      MapSet.member?(reserved_keys, normalized_key)
    end)
  end

  defp fetch_string(map, keys) do
    case fetch_value(map, keys) do
      nil -> nil
      value when is_binary(value) -> String.trim(value)
      value when is_atom(value) -> Atom.to_string(value)
      value when is_integer(value) -> Integer.to_string(value)
      value when is_float(value) -> Float.to_string(value)
      _ -> nil
    end
  end

  defp optional_identity_string(map, keys) do
    case fetch_value(map, keys) do
      nil ->
        nil

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value when is_atom(value) and not is_boolean(value) ->
        Atom.to_string(value)

      value when is_integer(value) ->
        Integer.to_string(value)

      _ ->
        nil
    end
  end

  defp outcome_identity_context(payload, status) do
    assignment_id =
      Enum.find_value(
        [fetch_value(status, [:plugin_provenance]), fetch_value(payload, ["labels"])],
        &optional_identity_string(&1, ["assignment_id"])
      )

    %{
      agent_id: optional_identity_string(status, [:agent_id]),
      assignment_id: assignment_id,
      partition: optional_identity_string(status, [:partition])
    }
  end

  defp evaluate_registered_handlers(
         handlers,
         payload,
         status,
         observed_at,
         handler_context,
         actor
       ) do
    identity = outcome_identity_context(payload, status)

    outcomes =
      handlers
      |> Enum.reduce([], fn handler, acc ->
        case handler_support(handler, payload, status) do
          {:ok, true} ->
            raw = ingest_handler(handler, payload, status, observed_at, handler_context, actor)
            classified = classify_and_emit(handler, raw, identity)
            [classified | acc]

          {:ok, false} ->
            acc

          {:error, reason} ->
            classified = classify_and_emit(handler, {:error, reason}, identity)
            [classified | acc]
        end
      end)
      |> Enum.reverse()

    case PluginResultHandlerOutcome.combine(outcomes) do
      {:applied, all_outcomes} ->
        {:applied, all_outcomes}

      {:settled, primary_reason, detail, all_outcomes} ->
        {:settled, primary_reason, detail, all_outcomes}

      {:refused, primary_reason, detail, all_outcomes} ->
        {:refused, primary_reason, detail, all_outcomes,
         failure_pairs_from_outcomes(all_outcomes)}

      {:retryable, all_outcomes} ->
        cleanup_failed? =
          Enum.any?(all_outcomes, fn item ->
            item.handler_module == PluginIngestor and
              item.raw_error == :running_config_artifact_cleanup_failed
          end)

        failure_kind =
          if cleanup_failed?,
            do: :plugin_result_artifact_cleanup_failed,
            else: :plugin_result_handlers_failed

        {:retryable, failure_kind, all_outcomes, failure_pairs_from_outcomes(all_outcomes)}
    end
  end

  defp classify_and_emit(handler, raw_result, identity) do
    mod = handler_module(handler)

    classified =
      if is_atom(mod) do
        PluginResultHandlerOutcome.classify(mod, raw_result)
      else
        ServiceRadar.Observability.PluginResultHandler
        |> PluginResultHandlerOutcome.classify({:error, {:invalid_handler, mod}})
        |> Map.put(:handler_module, mod)
      end

    :telemetry.execute(
      [:serviceradar, :plugin_result, :handler, :outcome],
      %{count: 1},
      %{
        outcome: classified.outcome,
        handler: classified.handler,
        reason: classified.reason,
        agent_id: identity.agent_id,
        assignment_id: identity.assignment_id
      }
    )

    log_classified_outcome(classified, identity)
    classified
  end

  defp log_classified_outcome(%{outcome: :applied}, _identity), do: :ok

  defp log_classified_outcome(%{outcome: :settled} = classified, identity) do
    Logger.info(
      "Plugin result handler #{inspect(classified.handler_module)} settled: reason=#{classified.reason}",
      outcome_logger_metadata(classified, identity)
    )
  end

  defp log_classified_outcome(%{outcome: :refused} = classified, identity) do
    error_text = handler_error_text(classified.raw_error)

    Logger.warning(
      "Plugin result handler #{inspect(classified.handler_module)} refused: reason=#{classified.reason} detail=#{error_text}",
      outcome_logger_metadata(classified, identity)
    )
  end

  defp log_classified_outcome(%{outcome: :retryable} = classified, identity) do
    error_text = handler_error_text(classified.raw_error)

    Logger.warning(
      "Plugin result handler #{inspect(classified.handler_module)} failed: #{error_text}",
      outcome_logger_metadata(classified, identity)
    )
  end

  defp outcome_logger_metadata(classified, identity) do
    Enum.reject(
      [
        outcome: classified.outcome,
        handler: classified.handler,
        reason: classified.reason,
        agent_id: identity.agent_id,
        assignment_id: identity.assignment_id,
        partition: identity.partition
      ],
      fn {_k, v} -> is_nil(v) end
    )
  end

  defp failure_pairs_from_outcomes(outcomes) do
    for item <- outcomes, item.outcome in [:refused, :retryable] do
      {item.handler_module, handler_error_text(item.raw_error)}
    end
  end

  defp serialize_handler_outcomes(outcomes) do
    Enum.map(outcomes, fn item ->
      status_str =
        case item.outcome do
          :applied -> "succeeded"
          :settled -> "settled"
          _ -> "failed"
        end

      base = %{
        "handler" => handler_label(item.handler_module),
        "status" => status_str,
        "reason" => Atom.to_string(item.reason)
      }

      cond do
        item.outcome == :settled and map_size(item.metadata) > 0 ->
          Map.put(base, "metadata", item.metadata)

        item.outcome in [:refused, :retryable] ->
          Map.put(base, "error", handler_error_text(item.raw_error))

        true ->
          base
      end
    end)
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
      {:ok, status_event} ->
        {:ok, status_event}

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
          with {:ok, state_notifications, side_effects, status_event} <-
                 persist_failure_state(status_row, failure_row, payload, marker, actor) do
            {:ok, marker_notifications ++ state_notifications, side_effects, status_event}
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
         %{settled_recorded?: true} = marker,
         actor
       ) do
    persist_handler_settled_state(
      status_row,
      payload,
      [],
      %{marker | failure_recorded?: true},
      actor
    )
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
      [],
      %{marker | failure_recorded?: true},
      actor
    )
  end

  defp persist_failure_state(_status_row, failure_row, _payload, _marker, _actor) do
    with {:ok, notifications, side_effects} <-
           upsert_current_state_with_notifications(failure_row) do
      {:ok, notifications, side_effects, failure_row}
    end
  end

  defp persist_handler_settled(status_row, payload, outcomes, handlers, actor) do
    provenance = handler_set_provenance(handlers)

    with_handler_marker_lock(status_row, fn ->
      do_persist_handler_settled(
        status_row,
        payload,
        outcomes,
        provenance,
        actor,
        @handler_marker_insert_attempts
      )
    end)
  end

  defp do_persist_handler_settled(status_row, payload, outcomes, provenance, actor, attempts) do
    with {:ok, marker} <- handler_marker_context(status_row, provenance, actor) do
      case persist_handler_settled_state(status_row, payload, outcomes, marker, actor) do
        {:error, :handler_marker_collision} when attempts > 1 ->
          do_persist_handler_settled(
            status_row,
            payload,
            outcomes,
            provenance,
            actor,
            attempts - 1
          )

        other ->
          other
      end
    end
  end

  defp persist_handler_settled_state(status_row, payload, outcomes, marker, actor) do
    settled_row = handler_settled_status_row(status_row, payload, outcomes, marker)

    with {:ok, history_notifications, inserted?, persisted} <-
           insert_handler_marker_with_result(settled_row, marker, "settled", actor),
         {:ok, state_notifications, side_effects} <-
           upsert_current_state_with_notifications(settled_row) do
      status_event = if inserted? or marker.failure_recorded?, do: persisted, else: settled_row
      {:ok, history_notifications ++ state_notifications, side_effects, status_event}
    end
  end

  defp persist_handler_success(status_row, payload, outcomes, handlers, actor) do
    provenance = handler_set_provenance(handlers)

    with_handler_marker_lock(status_row, fn ->
      with {:ok, marker} <- handler_marker_context(status_row, provenance, actor) do
        persist_handler_success_state(status_row, payload, outcomes, marker, actor)
      end
    end)
  end

  defp persist_handler_success_state(status_row, payload, outcomes, marker, actor) do
    success_row = handler_success_status_row(status_row, payload, outcomes, marker)

    with {:ok, history_notifications, history_status_event} <-
           maybe_insert_handler_recovery(status_row, success_row, marker, actor),
         {:ok, state_notifications, side_effects} <-
           upsert_current_state_with_notifications(success_row) do
      status_event = history_status_event || if(marker.failure_recorded?, do: success_row)

      {:ok, history_notifications ++ state_notifications, side_effects, status_event}
    end
  end

  defp maybe_insert_handler_recovery(reported_row, success_row, marker, actor) do
    if marker.failure_recorded? or not server_reported_status?(reported_row) do
      insert_handler_recovery_marker(success_row, marker, actor)
    else
      case PluginResultStateWinner.multiple_reported_payloads?(success_row) do
        {:ok, true} -> insert_handler_recovery_marker(success_row, marker, actor)
        {:ok, false} -> {:ok, [], nil}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp server_reported_status?(row), do: not is_nil(parse_reported_status_marker(row))

  defp insert_handler_recovery_marker(success_row, marker, actor) do
    case insert_handler_marker_with_result(success_row, marker, "succeeded", actor) do
      {:ok, notifications, true, persisted} ->
        {:ok, notifications, persisted}

      {:ok, notifications, false, persisted} ->
        status_event = if marker.failure_recorded?, do: persisted
        {:ok, notifications, status_event}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handler_failure_status_row(status_row, payload, errors, marker) do
    handlers = Enum.map(errors, fn {handler, _error_text} -> handler_label(handler) end)
    message = "Plugin result downstream ingest failed: #{Enum.join(handlers, ", ")}"
    reported_payload = drop_top_level_keys(payload, [@reported_status_marker_key])

    details =
      payload
      |> drop_top_level_keys(@reserved_state_detail_keys)
      |> Map.merge(%{
        "status" => "CRITICAL",
        "summary" => message,
        "reported_result" => reported_payload,
        "downstream_ingest" =>
          PluginResultProvenance.put(
            %{
              "status" => "failed",
              "generation" => marker.generation,
              "handler_set" => marker.handler_set,
              "observation_timestamp" => marker.observation_timestamp,
              "payload_digest" => marker.payload_digest,
              "handlers" =>
                Enum.map(errors, fn {handler, error_text} ->
                  %{
                    "handler" => handler_label(handler),
                    "status" => "failed",
                    "error" => error_text
                  }
                end)
            },
            PluginResultProvenance.from_details(status_row.details)
          )
      })
      |> FieldParser.encode_json()

    %{
      status_row
      | timestamp: marker.failure_at,
        created_at: marker.failure_at,
        available: false,
        message: message,
        details: details
    }
  end

  defp handler_settled_status_row(status_row, payload, outcomes, marker) do
    reported_payload = drop_top_level_keys(payload, [@reported_status_marker_key])

    downstream_base = %{
      "status" => "settled",
      "generation" => marker.generation,
      "handler_set" => marker.handler_set,
      "observation_timestamp" => marker.observation_timestamp,
      "payload_digest" => marker.payload_digest,
      "recovered_from_failure" => marker.failure_recorded?,
      "handlers" => serialize_handler_outcomes(outcomes)
    }

    details =
      payload
      |> drop_top_level_keys(@reserved_state_detail_keys)
      |> Map.merge(%{
        "status" => fetch_string(payload, ["status"]),
        "summary" => status_row.message,
        "reported_result" => reported_payload,
        "downstream_ingest" =>
          PluginResultProvenance.put(
            downstream_base,
            PluginResultProvenance.from_details(status_row.details)
          )
      })
      |> FieldParser.encode_json()

    %{
      status_row
      | timestamp: marker.success_at,
        created_at: marker.success_at,
        available: status_row.available,
        details: details
    }
  end

  defp handler_success_status_row(status_row, payload, outcomes, marker) do
    reported_payload = drop_top_level_keys(payload, [@reported_status_marker_key])

    downstream_base =
      maybe_put_handler_outcomes(
        %{
          "status" => "succeeded",
          "generation" => marker.generation,
          "handler_set" => marker.handler_set,
          "observation_timestamp" => marker.observation_timestamp,
          "payload_digest" => marker.payload_digest,
          "recovered_from_failure" => marker.failure_recorded?
        },
        outcomes
      )

    details =
      payload
      |> drop_top_level_keys(@reserved_state_detail_keys)
      |> Map.merge(%{
        "status" => fetch_string(payload, ["status"]),
        "summary" => status_row.message,
        "reported_result" => reported_payload,
        "downstream_ingest" =>
          PluginResultProvenance.put(
            downstream_base,
            PluginResultProvenance.from_details(status_row.details)
          )
      })
      |> FieldParser.encode_json()

    %{
      status_row
      | timestamp: marker.success_at,
        created_at: marker.success_at,
        details: details
    }
  end

  defp maybe_put_handler_outcomes(map, []), do: map

  defp maybe_put_handler_outcomes(map, outcomes),
    do: Map.put(map, "handlers", serialize_handler_outcomes(outcomes))

  defp insert_handler_marker(row, marker, marker_status, actor) do
    case insert_handler_marker_with_result(row, marker, marker_status, actor) do
      {:ok, notifications, _inserted?, _persisted} -> {:ok, notifications}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_handler_marker_with_result(row, marker, marker_status, actor) do
    with {:ok, record, notifications} <- insert_status_with_notifications(row, actor),
         {:ok, persisted} <- handler_status_at(row, actor) do
      persisted_marker = parse_handler_marker(persisted)

      if marker_matches?(persisted_marker, marker, marker_status) do
        inserted? = Ash.Resource.get_metadata(record, :upsert_skipped) != true
        {:ok, notifications, inserted?, persisted}
      else
        {:error, :handler_marker_collision}
      end
    end
  end

  defp handler_status_at(row, actor) do
    timestamp = row.timestamp
    agent_id = row.agent_id
    gateway_id = row.gateway_id
    partition = row.partition
    service_type = row.service_type
    service_name = row.service_name

    ServiceStatus
    |> Ash.Query.filter(
      timestamp == ^timestamp and agent_id == ^agent_id and gateway_id == ^gateway_id and
        partition == ^partition and service_type == ^service_type and
        service_name == ^service_name
    )
    |> Ash.read_one(actor: actor, domain: ServiceRadar.Observability)
    |> case do
      {:ok, nil} -> {:ok, nil}
      {:ok, %ServiceStatus{} = status} -> {:ok, status}
      {:error, error} -> {:error, error}
      other -> {:error, {:unexpected_service_status_lookup_result, other}}
    end
  end

  defp marker_matches?(persisted, marker, marker_status) when is_map(persisted) do
    persisted.status == marker_status and persisted.generation == marker.generation and
      persisted.observation_timestamp == marker.observation_timestamp and
      persisted.payload_digest == marker.payload_digest and
      persisted.handler_set == marker.handler_set
  end

  defp marker_matches?(_persisted, _marker, _marker_status), do: false

  defp with_handler_marker_lock(status_row, fun) when is_function(fun, 0) do
    case Repo.transaction(fn ->
           case acquire_status_slot_locks(status_row) do
             :ok ->
               case fun.() do
                 {:ok, notifications, side_effects, status_event}
                 when is_list(notifications) and is_list(side_effects) ->
                   {:ok, notifications, side_effects, status_event}

                 {:error, reason} ->
                   Repo.rollback(reason)

                 other ->
                   Repo.rollback({:unexpected_handler_marker_result, other})
               end

             {:error, reason} ->
               Repo.rollback(reason)
           end
         end) do
      {:ok, {:ok, notifications, side_effects, status_event}} ->
        _ = Ash.Notifier.notify(notifications)

        case dispatch_handler_side_effects(side_effects) do
          :ok -> {:ok, status_event}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_handler_marker_transaction_result, other}}
    end
  end

  defp acquire_status_slot_locks(status_row) do
    # One statement for the whole ordered sequence: reconcile-shared, logical
    # plugin state, logical observation, rolling-upgrade compatibility, then
    # the ascending physical slot buckets -- the stable order shared with
    # lifecycle mutations, without a round trip per stage.
    with {:ok, locks} <- status_identity_lock_sequence(status_row) do
      locks
      |> Kernel.++(Enum.map(bucket_lock_keys(status_row), &{:exclusive, &1}))
      |> AdvisoryLocks.acquire_ordered()
    end
  end

  defp status_identity_lock_sequence(status_row) do
    logical_observed_at = PluginResultSlot.logical_observed_at(status_row)

    observation_lock_identity =
      Jason.encode!([
        "plugin-result-observation",
        status_row.agent_id,
        status_row.partition,
        status_row.service_type,
        status_row.service_name,
        DateTime.to_iso8601(logical_observed_at)
      ])

    legacy_slot_lock_identity =
      Jason.encode!([
        "service-status-slots",
        status_row.gateway_id,
        status_row.service_name
      ])

    with {:ok, plugin_locks} <- PluginState.lock_sequence(status_row) do
      {:ok,
       plugin_locks ++
         [
           {:exclusive, observation_lock_identity},
           {:shared, legacy_slot_lock_identity}
         ]}
    end
  end

  # The physical slot buckets a status write touches, ascending: one batched
  # statement whether the window spans one bucket or several.
  defp acquire_status_slot_buckets(status_row, :try) do
    case status_row |> bucket_lock_keys() |> AdvisoryLocks.try_acquire_ordered() do
      :ok -> :ok
      {:error, {:advisory_locks_busy, _keys}} -> {:error, :status_slot_lock_busy}
      {:error, reason} -> {:error, reason}
    end
  end

  defp acquire_status_slot_buckets(status_row, :exclusive) do
    status_row
    |> bucket_lock_keys()
    |> Enum.map(&{:exclusive, &1})
    |> AdvisoryLocks.acquire_ordered()
  end

  defp bucket_lock_keys(status_row) do
    status_row
    |> status_slot_bucket_ids()
    |> Enum.map(fn bucket_id ->
      Jason.encode!([
        "service-status-slots-v2",
        status_row.gateway_id,
        status_row.service_name,
        bucket_id
      ])
    end)
  end

  defp status_slot_bucket_ids(status_row) do
    first_microsecond = DateTime.to_unix(status_row.timestamp, :microsecond)
    last_microsecond = first_microsecond + @handler_marker_window_microseconds
    first_bucket = Integer.floor_div(first_microsecond, @status_slot_bucket_width_microseconds)
    last_bucket = Integer.floor_div(last_microsecond, @status_slot_bucket_width_microseconds)

    Enum.to_list(first_bucket..last_bucket)
  end

  defp dispatch_handler_side_effects(side_effects) do
    Enum.reduce_while(side_effects, :ok, fn {registry, effects}, :ok ->
      if Code.ensure_loaded?(registry) and
           function_exported?(registry, :dispatch_deferred_side_effects, 1) do
        case registry.dispatch_deferred_side_effects(effects) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
          other -> {:halt, {:error, {:unexpected_deferred_side_effect_result, other}}}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp handler_marker_context(status_row, provenance, actor) do
    with {:ok, rows} <- handler_marker_rows(status_row, actor),
         {:ok, slot_rows} <- handler_marker_slot_rows(status_row, actor),
         {:ok, state} <- handler_marker_state(status_row, actor) do
      observation_timestamp = PluginResultSlot.logical_observation_timestamp(status_row)
      payload_digest = reported_status_payload_digest(status_row.details)

      markers =
        (rows ++ List.wrap(state))
        |> Enum.map(&parse_handler_marker/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(fn marker ->
          marker.observation_timestamp == observation_timestamp and
            valid_marker_timestamp?(marker, status_row.timestamp)
        end)

      payload_markers = Enum.filter(markers, &(&1.payload_digest == payload_digest))

      current_markers =
        Enum.filter(payload_markers, &(&1.handler_set == provenance))

      failure_recorded? = latest_handler_history_failed?(payload_markers)

      with {:ok, payload_generation} <- max_marker_generation(payload_markers) do
        case current_marker_generation(current_markers) do
          {:ok, generation}
          when generation == payload_generation ->
            if globally_latest_provenance?(
                 markers,
                 provenance,
                 payload_digest,
                 generation
               ) and
                 generation_reusable?(
                   status_row,
                   provenance,
                   observation_timestamp,
                   payload_digest,
                   generation,
                   slot_rows
                 ) do
              generation_markers =
                Enum.filter(current_markers, &(&1.generation == generation))

              build_marker_context(
                status_row,
                provenance,
                observation_timestamp,
                payload_digest,
                generation,
                generation_markers,
                failure_recorded?
              )
            else
              allocate_marker_context(
                status_row,
                provenance,
                observation_timestamp,
                payload_digest,
                markers,
                failure_recorded?,
                slot_rows
              )
            end

          {:ok, _older_generation} ->
            allocate_marker_context(
              status_row,
              provenance,
              observation_timestamp,
              payload_digest,
              markers,
              failure_recorded?,
              slot_rows
            )

          {:error, reason} ->
            {:error, reason}

          :none ->
            allocate_marker_context(
              status_row,
              provenance,
              observation_timestamp,
              payload_digest,
              markers,
              failure_recorded?,
              slot_rows
            )
        end
      end
    end
  end

  defp handler_marker_rows(status_row, actor) do
    observed_at = status_row.timestamp
    upper_bound = DateTime.add(observed_at, @handler_marker_window_microseconds, :microsecond)
    agent_id = status_row.agent_id
    gateway_id = status_row.gateway_id
    partition = status_row.partition
    service_type = status_row.service_type
    service_name = status_row.service_name

    ServiceStatus
    |> Ash.Query.filter(
      timestamp > ^observed_at and timestamp <= ^upper_bound and agent_id == ^agent_id and
        gateway_id == ^gateway_id and partition == ^partition and service_type == ^service_type and
        service_name == ^service_name
    )
    |> Ash.read(actor: actor, domain: ServiceRadar.Observability)
    |> case do
      {:ok, rows} when is_list(rows) -> {:ok, rows}
      {:error, error} -> {:error, error}
      other -> {:error, {:unexpected_service_status_history_result, other}}
    end
  end

  defp handler_marker_slot_rows(status_row, actor) do
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
      other -> {:error, {:unexpected_service_status_slot_result, other}}
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

  defp max_marker_generation(markers) do
    generation = markers |> Enum.map(& &1.generation) |> Enum.max(fn -> 0 end)

    if generation <= @handler_marker_max_generations do
      {:ok, generation}
    else
      {:error, :handler_marker_window_exhausted}
    end
  end

  defp globally_latest_provenance?(markers, provenance, payload_digest, generation) do
    markers
    |> Enum.filter(&(&1.generation == generation))
    |> Enum.all?(fn marker ->
      marker.handler_set == provenance and marker.payload_digest == payload_digest
    end)
  end

  defp generation_reusable?(
         status_row,
         provenance,
         observation_timestamp,
         payload_digest,
         generation,
         slot_rows
       ) do
    expected = %{
      generation: generation,
      handler_set: provenance,
      observation_timestamp: observation_timestamp,
      payload_digest: payload_digest
    }

    failure_reusable? =
      slot_timestamp_reusable?(status_row, slot_rows, generation, "failed", expected, ["failed"])

    terminal_reusable? =
      slot_timestamp_reusable?(status_row, slot_rows, generation, "succeeded", expected, [
        "succeeded",
        "settled"
      ])

    failure_reusable? and terminal_reusable?
  end

  defp slot_timestamp_reusable?(
         status_row,
         slot_rows,
         generation,
         offset_status,
         expected,
         allowed_statuses
       ) do
    timestamp = marker_timestamp(status_row.timestamp, generation, offset_status)

    case Enum.find(slot_rows, &(DateTime.compare(&1.timestamp, timestamp) == :eq)) do
      nil ->
        true

      %ServiceStatus{} = row ->
        persisted = parse_handler_marker(row)

        exact_service_status_identity?(row, status_row) and
          Enum.any?(allowed_statuses, &marker_matches?(persisted, expected, &1))
    end
  end

  defp exact_service_status_identity?(left, right) do
    left.agent_id == right.agent_id and left.gateway_id == right.gateway_id and
      left.partition == right.partition and left.service_type == right.service_type and
      left.service_name == right.service_name
  end

  defp allocate_marker_context(
         status_row,
         provenance,
         observation_timestamp,
         payload_digest,
         markers,
         failure_recorded?,
         slot_rows
       ) do
    occupied_offsets =
      MapSet.new(slot_rows, &DateTime.diff(&1.timestamp, status_row.timestamp, :microsecond))

    max_generation = markers |> Enum.map(& &1.generation) |> Enum.max(fn -> 0 end)
    generation = find_available_generation(max_generation, occupied_offsets)

    case generation do
      nil ->
        {:error, :handler_marker_window_exhausted}

      generation ->
        provenance_markers =
          Enum.filter(markers, fn marker ->
            marker.handler_set == provenance and marker.payload_digest == payload_digest
          end)

        build_marker_context(
          status_row,
          provenance,
          observation_timestamp,
          payload_digest,
          generation,
          provenance_markers,
          failure_recorded?
        )
    end
  end

  defp find_available_generation(max_generation, _occupied_offsets)
       when max_generation >= @handler_marker_max_generations, do: nil

  defp find_available_generation(max_generation, occupied_offsets) do
    Enum.find((max_generation + 1)..@handler_marker_max_generations, fn generation ->
      failure_offset = marker_offset(generation, "failed")
      success_offset = marker_offset(generation, "succeeded")

      not MapSet.member?(occupied_offsets, failure_offset) and
        not MapSet.member?(occupied_offsets, success_offset)
    end)
  end

  defp build_marker_context(
         status_row,
         provenance,
         observation_timestamp,
         payload_digest,
         generation,
         current_markers,
         failure_recorded?
       ) do
    failure_at = marker_timestamp(status_row.timestamp, generation, "failed")
    success_at = marker_timestamp(status_row.timestamp, generation, "succeeded")

    if generation > @handler_marker_max_generations do
      {:error, :handler_marker_window_exhausted}
    else
      {:ok,
       %{
         generation: generation,
         handler_set: provenance,
         observation_timestamp: observation_timestamp,
         payload_digest: payload_digest,
         failure_at: failure_at,
         success_at: success_at,
         failure_recorded?: failure_recorded?,
         settled_recorded?:
           Enum.any?(current_markers, fn marker ->
             marker.status == "settled" and marker.source == :state
           end),
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

  defp reported_status_matches?(%ServiceStatus{} = persisted, row) do
    if exact_service_status_identity?(persisted, row) and
         reported_status_content_matches?(persisted, row) do
      case parse_reported_status_marker(persisted) do
        nil ->
          DateTime.compare(persisted.timestamp, row.timestamp) == :eq

        marker ->
          marker.observation_timestamp == DateTime.to_iso8601(row.timestamp) and
            marker.service_id == to_string(row.service_id) and
            valid_reported_status_timestamp?(persisted.timestamp, row.timestamp)
      end
    else
      false
    end
  end

  defp reported_status_matches?(_persisted, _row), do: false

  defp reported_status_content_matches?(%ServiceStatus{} = persisted, row) do
    persisted.available == Map.get(row, :available) and
      persisted.message == Map.get(row, :message) and
      reported_status_payload_digest(persisted.details) ==
        reported_status_payload_digest(Map.get(row, :details))
  end

  defp reported_status_payload_digest(details) when is_binary(details) do
    PluginResultReportedMarker.payload_digest_without_marker(details)
  end

  defp reported_status_payload_digest(details), do: payload_digest(details)

  defp valid_reported_status_timestamp?(physical_timestamp, observed_at) do
    PluginResultSlot.within_allocation_window?(physical_timestamp, observed_at)
  end

  defp parse_reported_status_marker(status), do: PluginResultReportedMarker.parse(status)

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
         "downstream_ingest" =>
           %{
             "status" => status,
             "generation" => generation,
             "handler_set" => %{"id" => id, "version" => version} = handler_set,
             "observation_timestamp" => observation_timestamp
           } = downstream_ingest
       } = decoded}
      when status in ["failed", "settled", "succeeded"] and is_integer(generation) and
             generation > 0 and
             is_binary(id) and is_integer(version) and is_binary(observation_timestamp) ->
        %{
          status: status,
          generation: generation,
          handler_set: handler_set,
          observation_timestamp: observation_timestamp,
          payload_digest: handler_payload_digest(decoded, downstream_ingest),
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

  defp marker_offset(generation, status) when status in ["succeeded", "settled"],
    do: generation * 2

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

  defp handler_payload_digest(decoded, downstream_ingest) do
    case Map.get(downstream_ingest, "payload_digest") do
      digest when is_binary(digest) and byte_size(digest) == 64 ->
        digest

      _ ->
        case Map.get(decoded, "reported_result") do
          payload when is_map(payload) ->
            payload
            |> drop_top_level_keys([@reported_status_marker_key])
            |> payload_digest()

          payload when is_list(payload) ->
            payload_digest(payload)

          _ ->
            decoded |> drop_top_level_keys(@reserved_state_detail_keys) |> payload_digest()
        end
    end
  end

  defp payload_digest(payload) do
    PluginResultReportedMarker.payload_digest(payload)
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
    value
    |> sanitize_handler_error()
    |> truncate_utf8(@handler_error_component_max_bytes)
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
    |> String.replace(@unterminated_private_key_pattern, "[REDACTED PRIVATE KEY]")
    |> String.replace(@authorization_header_pattern, "\\1[REDACTED]")
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

  # Proxmox inventory results also carry a generic device-discovery envelope for
  # compatibility with older consumers. Running that handler would reconcile
  # the plugin-owned, globally scoped `proxmox:*` identifiers before the
  # authenticated source scope is resolved below. The Proxmox enrichment path
  # is the sole device creator for these results so cluster/node/vmid identity
  # remains scoped to the approved assignment and credential rule.
  defp handler_support({DeviceDiscoveryIngestor, _opts}, payload, status) do
    device_discovery_support(payload, status)
  end

  defp handler_support(DeviceDiscoveryIngestor, payload, status) do
    device_discovery_support(payload, status)
  end

  defp handler_support({handler, _opts}, payload, status) when is_atom(handler) do
    handler_support(handler, payload, status)
  end

  defp handler_support(handler, payload, status) when is_atom(handler) do
    # function_exported?/3 is false for a module that has not been loaded yet,
    # which would silently turn a handler with supports?/2 into a catch-all.
    if Code.ensure_loaded?(handler) do
      supported =
        cond do
          function_exported?(handler, :supports?, 2) -> handler.supports?(payload, status)
          function_exported?(handler, :supports?, 1) -> handler.supports?(payload)
          true -> true
        end

      handler_support_result(supported)
    else
      {:error, {:handler_not_loadable, handler}}
    end
  rescue
    error -> {:error, {:support_check_failed, error}}
  catch
    kind, reason -> {:error, {:support_check_failed, {kind, reason}}}
  end

  defp handler_support(handler, _payload, _status), do: {:error, {:invalid_handler, handler}}

  defp device_discovery_support(payload, status) do
    if ProxmoxEnrichmentIngestor.supports?(payload, status) do
      {:ok, false}
    else
      handler_support_result(DeviceDiscoveryIngestor.supports?(payload, status))
    end
  rescue
    error -> {:error, {:support_check_failed, error}}
  catch
    kind, reason -> {:error, {:support_check_failed, {kind, reason}}}
  end

  defp handler_support_result(true), do: {:ok, true}
  defp handler_support_result(false), do: {:ok, false}
  defp handler_support_result(other), do: {:error, {:unexpected_support_result, other}}

  defp ingest_handler(
         ProxmoxEnrichmentIngestor,
         payload,
         status,
         observed_at,
         handler_context,
         actor
       ) do
    ingest_proxmox(payload, status, observed_at, handler_context, actor, [])
  end

  defp ingest_handler(
         {ProxmoxEnrichmentIngestor, opts},
         payload,
         status,
         observed_at,
         handler_context,
         actor
       ) do
    ingest_proxmox(payload, status, observed_at, handler_context, actor, opts)
  end

  defp ingest_handler(handler, payload, status, observed_at, handler_context, actor)
       when is_atom(handler) do
    handler.ingest(
      payload,
      status,
      handler_opts([], observed_at, handler_context, actor)
    )
  rescue
    e ->
      {:error, e}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  defp ingest_handler({handler, opts}, payload, status, observed_at, handler_context, actor)
       when is_atom(handler) do
    handler.ingest(
      payload,
      status,
      handler_opts(opts, observed_at, handler_context, actor)
    )
  rescue
    e ->
      {:error, e}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  defp ingest_handler(handler, _payload, _status, _observed_at, _handler_context, _actor) do
    {:error, {:invalid_handler, handler}}
  end

  defp handler_opts(opts, observed_at, handler_context, actor) do
    opts
    |> Keyword.put_new(:defer_artifact_cleanup, handler_context.defer_cleanup?)
    |> Keyword.merge(actor: actor, observed_at: observed_at)
  end

  defp ingest_proxmox(payload, status, observed_at, handler_context, actor, opts) do
    case proxmox_source_scope_resolver().resolve(payload, status, actor: actor) do
      {:ok, source_scope} ->
        merged_opts =
          opts
          |> Keyword.put_new(:defer_artifact_cleanup, handler_context.defer_cleanup?)
          |> Keyword.merge(
            actor: actor,
            observed_at: observed_at,
            source_scope: source_scope
          )

        ProxmoxEnrichmentIngestor.ingest(payload, status, merged_opts)

      {:error, reason} ->
        ProxmoxSourceScopeResolver.classify_error(reason, payload, status)
    end
  rescue
    e ->
      {:error, e}
  catch
    kind, reason ->
      {:error, {kind, reason}}
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

  defp proxmox_source_scope_resolver do
    Application.get_env(
      :serviceradar_core,
      :proxmox_source_scope_resolver,
      ProxmoxSourceScopeResolver
    )
  end

  defp state_registry do
    Application.get_env(
      :serviceradar_core,
      :plugin_result_state_registry,
      ServiceStateRegistry
    )
  end

  @doc false
  def platform_contract_handlers do
    [
      PluginIngestor,
      ServiceRadar.DeclarativeChecks.EdgeResultIngestor,
      ServiceRadar.NetworkConfig.InterfaceCheckIngestor,
      DeviceDiscoveryIngestor,
      HypervisorEnrichmentIngestor,
      ProxmoxEnrichmentIngestor,
      VulnerabilityAdvisoryIngestor,
      BatchIngestor,
      ThreatIntelPluginIngestor,
      EventIngestor,
      InventoryIngestor,
      ServiceRadar.Plugins.RunOverrideAckIngestor
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
