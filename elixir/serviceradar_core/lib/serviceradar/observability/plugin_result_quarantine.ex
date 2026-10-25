defmodule ServiceRadar.Observability.PluginResultQuarantine do
  @moduledoc """
  Tracks per-observation ingestion attempts for capability-retained plugin results
  outside the handler ingestion transaction and quarantines observations that
  repeatedly exceed the worker execution budget.

  Durable state lives in `platform.plugin_result_ingestion_attempts` keyed by
  `{agent_id, result_key}`, with an in-memory ETS mirror so unit tests running
  without `ServiceRadar.Repo` (or sandboxed tests where a worker kill aborts the
  active connection) still observe monotonic attempt and quarantine state.
  """

  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.Observability.PluginResultReportedMarker
  alias ServiceRadar.Observability.ServiceStateRegistry.PluginStateContract
  alias ServiceRadar.Observability.ServiceStatusPubSub
  alias ServiceRadar.Repo

  require Logger

  @ets_table :serviceradar_plugin_result_quarantine_ets
  @default_max_consecutive_timeouts 3
  @default_quarantine_reason "execution_timeout_budget_exceeded"
  @error_max_bytes 1_000

  @type attempt_record :: %{
          id: String.t(),
          agent_id: String.t(),
          result_key: String.t(),
          gateway_id: String.t() | nil,
          partition: String.t(),
          service_type: String.t(),
          service_name: String.t(),
          observation_timestamp: DateTime.t(),
          payload_digest: String.t(),
          payload_bytes: non_neg_integer(),
          attempt_count: non_neg_integer(),
          consecutive_timeout_count: non_neg_integer(),
          state: String.t(),
          last_outcome: String.t() | nil,
          last_error: String.t() | nil,
          quarantine_reason: String.t() | nil,
          quarantined_at: DateTime.t() | nil,
          last_attempt_at: DateTime.t(),
          retained_status: map(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  Returns the configured maximum number of consecutive execution timeouts before
  an observation is quarantined (default: #{@default_max_consecutive_timeouts}).
  """
  @spec max_consecutive_timeouts() :: pos_integer()
  def max_consecutive_timeouts do
    configured =
      Application.get_env(:serviceradar_core, :plugin_result_quarantine_max_timeouts) ||
        :serviceradar_core
        |> Application.get_env(ServiceRadar.Admission.RetainedPluginLane, [])
        |> Keyword.get(:max_consecutive_timeouts)

    if is_integer(configured) and configured > 0 do
      configured
    else
      @default_max_consecutive_timeouts
    end
  end

  @doc """
  Extracts deterministic observation identity and payload metadata from a retained
  plugin status map.
  """
  @spec extract_identity(map(), non_neg_integer() | nil) :: map()
  def extract_identity(status, explicit_payload_bytes \\ nil) when is_map(status) do
    identity = PluginStateContract.status_identity(status)
    payload = extract_payload(status)
    observed_at = resolve_observed_at(payload, status)
    payload_digest = compute_payload_digest(payload, status)
    payload_bytes = resolve_payload_bytes(status, explicit_payload_bytes)
    iso_observed_at = DateTime.to_iso8601(observed_at)

    result_key =
      Enum.join(
        [
          identity.partition,
          identity.service_type,
          identity.service_name,
          iso_observed_at,
          payload_digest
        ],
        ":"
      )

    %{
      agent_id: identity.agent_id,
      result_key: result_key,
      gateway_id: identity.gateway_id,
      partition: identity.partition,
      service_type: identity.service_type,
      service_name: identity.service_name,
      observation_timestamp: observed_at,
      payload_digest: payload_digest,
      payload_bytes: payload_bytes,
      retained_status: serialize_retained_status(status)
    }
  end

  @doc """
  Checks whether a retained plugin status observation is quarantined before running
  downstream handlers.

  If the observation has already reached `max_consecutive_timeouts/0` or is in
  the `"quarantined"` state, ensures the quarantine state and health signal are
  recorded and returns `{:quarantined, record}` so the caller can acknowledge the
  result without running handlers again.
  """
  @spec check_quarantined(map()) :: :ok | {:quarantined, attempt_record()}
  def check_quarantined(status) when is_map(status) do
    identity = extract_identity(status)
    threshold = max_consecutive_timeouts()

    case fetch_record(identity.agent_id, identity.result_key) do
      nil ->
        :ok

      %{state: "quarantined"} = record ->
        {:quarantined, record}

      %{consecutive_timeout_count: count} = record when count >= threshold ->
        quarantined = transition_to_quarantined(record, identity, @default_quarantine_reason)
        {:quarantined, quarantined}

      _record ->
        :ok
    end
  end

  def check_quarantined(_status), do: :ok

  @doc """
  Records an execution timeout for a retained plugin status outside the aborted
  worker transaction.

  When the consecutive execution timeout count reaches `max_consecutive_timeouts/0`,
  the observation is immediately transitioned to `"quarantined"`, recording the
  quarantine reason, payload identity, and payload size, and emitting a health
  signal.
  """
  @spec record_execution_timeout(map(), non_neg_integer() | nil) ::
          {:ok, attempt_record()} | :ok
  def record_execution_timeout(status, payload_bytes \\ nil)

  def record_execution_timeout(status, payload_bytes) when is_map(status) do
    identity = extract_identity(status, payload_bytes)
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    threshold = max_consecutive_timeouts()
    existing = fetch_record(identity.agent_id, identity.result_key)

    attempt_count = if(existing, do: existing.attempt_count, else: 0) + 1
    consecutive_timeouts = if(existing, do: existing.consecutive_timeout_count, else: 0) + 1
    already_quarantined? = existing != nil and existing.state == "quarantined"
    quarantine_now? = already_quarantined? or consecutive_timeouts >= threshold

    state = if quarantine_now?, do: "quarantined", else: "active"

    quarantine_reason =
      cond do
        already_quarantined? and is_binary(existing.quarantine_reason) ->
          existing.quarantine_reason

        quarantine_now? ->
          @default_quarantine_reason

        true ->
          nil
      end

    quarantined_at =
      cond do
        already_quarantined? and existing.quarantined_at != nil ->
          existing.quarantined_at

        quarantine_now? ->
          now

        true ->
          nil
      end

    record =
      build_record(existing, identity, %{
        attempt_count: attempt_count,
        consecutive_timeout_count: consecutive_timeouts,
        state: state,
        last_outcome: "execution_timeout",
        last_error: "worker_execution_timeout",
        quarantine_reason: quarantine_reason,
        quarantined_at: quarantined_at,
        last_attempt_at: now,
        updated_at: now
      })

    persisted = persist_record(record)

    if quarantine_now? and not already_quarantined? do
      emit_quarantine_signal(persisted)
    end

    {:ok, persisted}
  rescue
    e ->
      Logger.warning("Failed to record plugin result execution timeout: #{Exception.message(e)}")

      :ok
  end

  def record_execution_timeout(_status, _payload_bytes), do: :ok

  @doc """
  Records a non-timeout handler error outcome outside the handler transaction.
  Resets `consecutive_timeout_count` because the worker completed within budget.
  """
  @spec record_handler_error(map(), term()) :: {:ok, attempt_record()} | :ok
  def record_handler_error(status, error_reason) when is_map(status) do
    identity = extract_identity(status)
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    existing = fetch_record(identity.agent_id, identity.result_key)
    attempt_count = if(existing, do: existing.attempt_count, else: 0) + 1

    record =
      build_record(existing, identity, %{
        attempt_count: attempt_count,
        consecutive_timeout_count: 0,
        state: if(existing && existing.state == "quarantined", do: "quarantined", else: "active"),
        last_outcome: "handler_error",
        last_error: format_error(error_reason),
        quarantine_reason: if(existing, do: existing.quarantine_reason),
        quarantined_at: if(existing, do: existing.quarantined_at),
        last_attempt_at: now,
        updated_at: now
      })

    {:ok, persist_record(record)}
  rescue
    e ->
      Logger.warning("Failed to record plugin result handler error: #{Exception.message(e)}")
      :ok
  end

  def record_handler_error(_status, _error_reason), do: :ok

  @doc """
  Records a successful ingestion outcome, resetting consecutive timeout state
  and clearing any active quarantine on the observation.
  """
  @spec record_success(map()) :: {:ok, attempt_record()} | :ok
  def record_success(status) when is_map(status) do
    identity = extract_identity(status)
    existing = fetch_record(identity.agent_id, identity.result_key)

    if is_nil(existing) do
      :ok
    else
      now = DateTime.truncate(DateTime.utc_now(), :microsecond)

      record =
        build_record(existing, identity, %{
          attempt_count: existing.attempt_count + 1,
          consecutive_timeout_count: 0,
          state: "succeeded",
          last_outcome: "succeeded",
          last_error: nil,
          quarantine_reason: nil,
          quarantined_at: nil,
          last_attempt_at: now,
          updated_at: now
        })

      {:ok, persist_record(record)}
    end
  rescue
    e ->
      Logger.warning("Failed to record plugin result success: #{Exception.message(e)}")
      :ok
  end

  def record_success(_status), do: :ok

  @doc """
  Returns the attempt record for a given `agent_id` and `result_key`, or `nil`.
  """
  @spec get_attempt(String.t(), String.t()) :: attempt_record() | nil
  def get_attempt(agent_id, result_key) when is_binary(agent_id) and is_binary(result_key) do
    fetch_record(agent_id, result_key)
  end

  @doc """
  Returns the attempt record for a retained plugin `status` map, or `nil`.
  """
  @spec get_attempt_for_status(map()) :: attempt_record() | nil
  def get_attempt_for_status(status) when is_map(status) do
    identity = extract_identity(status)
    fetch_record(identity.agent_id, identity.result_key)
  end

  @doc """
  Operator-visible list of quarantined plugin result observations.

  Supported options:
  - `:agent_id` - filter by agent ID
  - `:service_name` - filter by service name
  - `:partition` - filter by partition
  - `:limit` - maximum number of records to return (default: 100)
  """
  @spec list_quarantined(keyword()) :: [attempt_record()]
  def list_quarantined(opts \\ []) do
    opts
    |> Keyword.put(:state, "quarantined")
    |> list_attempts()
  end

  @doc """
  Lists recorded plugin result ingestion attempts.
  """
  @spec list_attempts(keyword()) :: [attempt_record()]
  def list_attempts(opts \\ []) do
    sync_ets_to_repo()

    records =
      case list_repo_records(opts) do
        {:ok, db_records} ->
          merge_with_ets_records(db_records, opts)

        :unavailable ->
          list_ets_records(opts)
      end

    limit = Keyword.get(opts, :limit, 100)
    Enum.take(records, limit)
  end

  @doc """
  Retries a quarantined plugin result observation on operator request.

  Clears the quarantine state and resets `consecutive_timeout_count` to `0`.
  When `:reingest?` is `true` (default), re-runs `ResultIngestor.process_retained_plugin/1`
  using the stored or caller-supplied `status` map.
  """
  @spec retry_quarantined(String.t(), String.t(), keyword()) ::
          {:ok, attempt_record()} | {:error, term()}
  def retry_quarantined(agent_id, result_key, opts \\ [])
      when is_binary(agent_id) and is_binary(result_key) do
    case fetch_record(agent_id, result_key) do
      nil ->
        {:error, :not_found}

      record ->
        do_retry_quarantined(record, opts)
    end
  end

  @doc """
  Retries a quarantined plugin result observation identified by its `status` map
  or `attempt_record`.
  """
  @spec retry_quarantined_status(map(), keyword()) ::
          {:ok, attempt_record()} | {:error, term()}
  def retry_quarantined_status(status, opts \\ []) when is_map(status) do
    identity = extract_identity(status)

    case fetch_record(identity.agent_id, identity.result_key) do
      nil ->
        {:error, :not_found}

      record ->
        do_retry_quarantined(record, Keyword.put_new(opts, :status, status))
    end
  end

  @doc false
  @spec clear_all!() :: :ok
  def clear_all! do
    ensure_ets_table()
    :ets.delete_all_objects(@ets_table)

    if repo_available?() do
      _ = Repo.query("DELETE FROM platform.plugin_result_ingestion_attempts", [])
    end

    :ok
  rescue
    _ -> :ok
  end

  defp do_retry_quarantined(record, opts) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    reset_record =
      persist_record(%{
        record
        | consecutive_timeout_count: 0,
          state: "active",
          quarantine_reason: nil,
          quarantined_at: nil,
          updated_at: now
      })

    if Keyword.get(opts, :reingest?, true) do
      status =
        Keyword.get_lazy(opts, :status, fn ->
          deserialize_retained_status(reset_record.retained_status)
        end)

      if is_map(status) and map_size(status) > 0 do
        case ServiceRadar.Ingestion.ResultIngestor.process_retained_plugin(status) do
          :ok ->
            {:ok, fetch_record(reset_record.agent_id, reset_record.result_key) || reset_record}

          {:error, reason} ->
            {:error, reason}
        end
      else
        {:ok, reset_record}
      end
    else
      {:ok, reset_record}
    end
  end

  defp transition_to_quarantined(record, identity, reason) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    updated =
      build_record(record, identity, %{
        attempt_count: record.attempt_count,
        consecutive_timeout_count: record.consecutive_timeout_count,
        state: "quarantined",
        last_outcome: record.last_outcome || "execution_timeout",
        last_error: record.last_error || "worker_execution_timeout",
        quarantine_reason: record.quarantine_reason || reason,
        quarantined_at: record.quarantined_at || now,
        last_attempt_at: record.last_attempt_at || now,
        updated_at: now
      })

    persisted = persist_record(updated)
    emit_quarantine_signal(persisted)
    persisted
  end

  defp emit_quarantine_signal(record) do
    :telemetry.execute(
      [:serviceradar, :plugin_result, :quarantined],
      %{
        count: 1,
        attempt_count: record.attempt_count,
        consecutive_timeout_count: record.consecutive_timeout_count,
        payload_bytes: record.payload_bytes
      },
      %{
        agent_id: record.agent_id,
        gateway_id: record.gateway_id,
        partition: record.partition,
        service_type: record.service_type,
        service_name: record.service_name,
        result_key: record.result_key,
        payload_digest: record.payload_digest,
        observation_timestamp: record.observation_timestamp,
        reason: record.quarantine_reason
      }
    )

    Logger.warning(
      "Plugin result quarantined: agent_id=#{record.agent_id} service_name=#{record.service_name} " <>
        "result_key=#{record.result_key} payload_digest=#{record.payload_digest} " <>
        "payload_bytes=#{record.payload_bytes} attempts=#{record.attempt_count} " <>
        "consecutive_timeouts=#{record.consecutive_timeout_count} reason=#{record.quarantine_reason}"
    )

    if is_pid(Process.whereis(ServiceRadar.PubSub)) do
      Phoenix.PubSub.broadcast(
        ServiceRadar.PubSub,
        ServiceStatusPubSub.topic(),
        {:plugin_result_quarantined, record}
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  defp build_record(existing, identity, updates) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    base =
      if existing do
        existing
      else
        %{
          id: Ecto.UUID.generate(),
          agent_id: identity.agent_id,
          result_key: identity.result_key,
          gateway_id: identity.gateway_id,
          partition: identity.partition,
          service_type: identity.service_type,
          service_name: identity.service_name,
          observation_timestamp: identity.observation_timestamp,
          payload_digest: identity.payload_digest,
          payload_bytes: identity.payload_bytes,
          attempt_count: 0,
          consecutive_timeout_count: 0,
          state: "active",
          last_outcome: nil,
          last_error: nil,
          quarantine_reason: nil,
          quarantined_at: nil,
          last_attempt_at: now,
          retained_status: identity.retained_status,
          inserted_at: now,
          updated_at: now
        }
      end

    base
    |> Map.merge(%{
      gateway_id: identity.gateway_id || base.gateway_id,
      partition: identity.partition || base.partition,
      service_type: identity.service_type || base.service_type,
      service_name: identity.service_name || base.service_name,
      observation_timestamp: identity.observation_timestamp || base.observation_timestamp,
      payload_digest: identity.payload_digest || base.payload_digest,
      payload_bytes: max(identity.payload_bytes, base.payload_bytes),
      retained_status:
        if(map_size(identity.retained_status) > 0,
          do: identity.retained_status,
          else: base.retained_status
        )
    })
    |> Map.merge(updates)
  end

  defp fetch_record(agent_id, result_key) do
    ets_record = fetch_ets_record(agent_id, result_key)
    repo_record = fetch_repo_record(agent_id, result_key)

    case {repo_record, ets_record} do
      {nil, nil} ->
        nil

      {repo, nil} ->
        put_ets_record(repo)
        repo

      {nil, ets} ->
        _ = upsert_repo_record(ets)
        ets

      {repo, ets} ->
        preferred = prefer_newer_record(repo, ets)
        put_ets_record(preferred)

        if preferred != repo do
          _ = upsert_repo_record(preferred)
        end

        preferred
    end
  end

  defp prefer_newer_record(repo, ets) do
    cond do
      ets.attempt_count > repo.attempt_count ->
        ets

      repo.attempt_count > ets.attempt_count ->
        repo

      DateTime.after?(ets.updated_at, repo.updated_at) ->
        ets

      true ->
        repo
    end
  end

  defp persist_record(record) do
    put_ets_record(record)

    case upsert_repo_record(record) do
      {:ok, persisted} ->
        put_ets_record(persisted)
        persisted

      :unavailable ->
        record
    end
  end

  defp sync_ets_to_repo do
    if repo_available?() do
      ensure_ets_table()

      @ets_table
      |> :ets.tab2list()
      |> Enum.each(fn {_key, record} ->
        _ = upsert_repo_record(record)
      end)
    end
  rescue
    _ -> :ok
  end

  defp fetch_ets_record(agent_id, result_key) do
    ensure_ets_table()

    case :ets.lookup(@ets_table, {agent_id, result_key}) do
      [{_key, record}] -> record
      [] -> nil
    end
  rescue
    _ -> nil
  end

  defp put_ets_record(record) do
    ensure_ets_table()
    :ets.insert(@ets_table, {{record.agent_id, record.result_key}, record})
    record
  rescue
    _ -> record
  end

  defp list_ets_records(opts) do
    ensure_ets_table()

    @ets_table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> filter_records(opts)
    |> sort_records()
  rescue
    _ -> []
  end

  defp merge_with_ets_records(db_records, opts) do
    ensure_ets_table()

    ets_map =
      @ets_table
      |> :ets.tab2list()
      |> Map.new(fn {key, record} -> {key, record} end)

    db_map =
      Map.new(db_records, fn record ->
        {{record.agent_id, record.result_key}, record}
      end)

    db_map
    |> Map.merge(ets_map, fn _key, repo, ets ->
      prefer_newer_record(repo, ets)
    end)
    |> Map.values()
    |> filter_records(opts)
    |> sort_records()
  end

  defp filter_records(records, opts) do
    Enum.filter(records, fn record ->
      matches_opt?(record.state, opts[:state]) and
        matches_opt?(record.agent_id, opts[:agent_id]) and
        matches_opt?(record.service_name, opts[:service_name]) and
        matches_opt?(record.partition, opts[:partition])
    end)
  end

  defp matches_opt?(_value, nil), do: true
  defp matches_opt?(value, expected), do: value == expected

  defp sort_records(records) do
    Enum.sort_by(
      records,
      fn record ->
        quarantined_unix =
          if record.quarantined_at,
            do: DateTime.to_unix(record.quarantined_at, :microsecond),
            else: 0

        updated_unix =
          if record.updated_at,
            do: DateTime.to_unix(record.updated_at, :microsecond),
            else: 0

        {quarantined_unix, updated_unix}
      end,
      :desc
    )
  end

  defp ensure_ets_table do
    case :ets.whereis(@ets_table) do
      :undefined ->
        try do
          :ets.new(@ets_table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> @ets_table
        end

      _tid ->
        @ets_table
    end
  end

  defp repo_available? do
    is_pid(Process.whereis(Repo))
  end

  defp fetch_repo_record(agent_id, result_key) do
    if repo_available?() do
      sql = """
      SELECT id::text,
             agent_id,
             result_key,
             gateway_id,
             partition,
             service_type,
             service_name,
             observation_timestamp,
             payload_digest,
             payload_bytes,
             attempt_count,
             consecutive_timeout_count,
             state,
             last_outcome,
             last_error,
             quarantine_reason,
             quarantined_at,
             last_attempt_at,
             retained_status,
             inserted_at,
             updated_at
      FROM platform.plugin_result_ingestion_attempts
      WHERE agent_id = $1 AND result_key = $2
      LIMIT 1
      """

      case run_repo_query(sql, [agent_id, result_key]) do
        {:ok, %{rows: [row]}} -> row_to_record(row)
        _ -> nil
      end
    end
  rescue
    _ -> nil
  end

  defp upsert_repo_record(record) do
    if repo_available?() do
      sql = """
      INSERT INTO platform.plugin_result_ingestion_attempts (
        id,
        agent_id,
        result_key,
        gateway_id,
        partition,
        service_type,
        service_name,
        observation_timestamp,
        payload_digest,
        payload_bytes,
        attempt_count,
        consecutive_timeout_count,
        state,
        last_outcome,
        last_error,
        quarantine_reason,
        quarantined_at,
        last_attempt_at,
        retained_status,
        inserted_at,
        updated_at
      )
      VALUES (
        $1::uuid, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11,
        $12, $13, $14, $15, $16, $17, $18, $19::jsonb, $20, $21
      )
      ON CONFLICT (agent_id, result_key) DO UPDATE SET
        gateway_id = EXCLUDED.gateway_id,
        partition = EXCLUDED.partition,
        service_type = EXCLUDED.service_type,
        service_name = EXCLUDED.service_name,
        observation_timestamp = EXCLUDED.observation_timestamp,
        payload_digest = EXCLUDED.payload_digest,
        payload_bytes = GREATEST(platform.plugin_result_ingestion_attempts.payload_bytes, EXCLUDED.payload_bytes),
        attempt_count = EXCLUDED.attempt_count,
        consecutive_timeout_count = EXCLUDED.consecutive_timeout_count,
        state = EXCLUDED.state,
        last_outcome = EXCLUDED.last_outcome,
        last_error = EXCLUDED.last_error,
        quarantine_reason = EXCLUDED.quarantine_reason,
        quarantined_at = EXCLUDED.quarantined_at,
        last_attempt_at = EXCLUDED.last_attempt_at,
        retained_status = EXCLUDED.retained_status,
        updated_at = EXCLUDED.updated_at
      RETURNING id::text,
                agent_id,
                result_key,
                gateway_id,
                partition,
                service_type,
                service_name,
                observation_timestamp,
                payload_digest,
                payload_bytes,
                attempt_count,
                consecutive_timeout_count,
                state,
                last_outcome,
                last_error,
                quarantine_reason,
                quarantined_at,
                last_attempt_at,
                retained_status,
                inserted_at,
                updated_at
      """

      params = [
        record.id,
        record.agent_id,
        record.result_key,
        record.gateway_id,
        record.partition,
        record.service_type,
        record.service_name,
        record.observation_timestamp,
        record.payload_digest,
        record.payload_bytes,
        record.attempt_count,
        record.consecutive_timeout_count,
        record.state,
        record.last_outcome,
        record.last_error,
        record.quarantine_reason,
        record.quarantined_at,
        record.last_attempt_at,
        record.retained_status || %{},
        record.inserted_at,
        record.updated_at
      ]

      case run_repo_query(sql, params) do
        {:ok, %{rows: [row]}} -> {:ok, row_to_record(row)}
        _ -> :unavailable
      end
    else
      :unavailable
    end
  rescue
    _ -> :unavailable
  end

  defp list_repo_records(opts) do
    if repo_available?() do
      {where_sql, params} = build_filter_sql(opts)

      sql = """
      SELECT id::text,
             agent_id,
             result_key,
             gateway_id,
             partition,
             service_type,
             service_name,
             observation_timestamp,
             payload_digest,
             payload_bytes,
             attempt_count,
             consecutive_timeout_count,
             state,
             last_outcome,
             last_error,
             quarantine_reason,
             quarantined_at,
             last_attempt_at,
             retained_status,
             inserted_at,
             updated_at
      FROM platform.plugin_result_ingestion_attempts
      #{where_sql}
      ORDER BY quarantined_at DESC NULLS LAST, updated_at DESC
      """

      case run_repo_query(sql, params) do
        {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &row_to_record/1)}
        _ -> :unavailable
      end
    else
      :unavailable
    end
  rescue
    _ -> :unavailable
  end

  defp build_filter_sql(opts) do
    filters =
      Enum.reject(
        [
          {:state, opts[:state]},
          {:agent_id, opts[:agent_id]},
          {:service_name, opts[:service_name]},
          {:partition, opts[:partition]}
        ],
        fn {_col, val} -> is_nil(val) end
      )

    if filters == [] do
      {"", []}
    else
      {clauses, params, _idx} =
        Enum.reduce(filters, {[], [], 1}, fn {col, val}, {clauses, params, idx} ->
          {["#{col} = $#{idx}" | clauses], params ++ [val], idx + 1}
        end)

      {"WHERE " <> Enum.join(Enum.reverse(clauses), " AND "), params}
    end
  end

  defp run_repo_query(sql, params) do
    case Repo.query(sql, params) do
      {:ok, result} ->
        {:ok, result}

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        ensure_repo_table()
        Repo.query(sql, params)

      {:error, _reason} = error ->
        error
    end
  end

  defp ensure_repo_table do
    ddl = """
    CREATE TABLE IF NOT EXISTS platform.plugin_result_ingestion_attempts (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      agent_id text NOT NULL,
      result_key text NOT NULL,
      gateway_id text,
      partition text NOT NULL DEFAULT 'default',
      service_type text NOT NULL DEFAULT 'plugin',
      service_name text NOT NULL DEFAULT 'unknown',
      observation_timestamp timestamptz NOT NULL,
      payload_digest text NOT NULL,
      payload_bytes integer NOT NULL DEFAULT 0,
      attempt_count integer NOT NULL DEFAULT 0,
      consecutive_timeout_count integer NOT NULL DEFAULT 0,
      state text NOT NULL DEFAULT 'active',
      last_outcome text,
      last_error text,
      quarantine_reason text,
      quarantined_at timestamptz,
      last_attempt_at timestamptz NOT NULL,
      retained_status jsonb NOT NULL DEFAULT '{}'::jsonb,
      inserted_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL
    )
    """

    idx_sql = """
    CREATE UNIQUE INDEX IF NOT EXISTS plugin_result_ingestion_attempts_agent_result_uidx
    ON platform.plugin_result_ingestion_attempts (agent_id, result_key)
    """

    _ = Repo.query(ddl, [])
    _ = Repo.query(idx_sql, [])
    :ok
  end

  defp row_to_record([
         id,
         agent_id,
         result_key,
         gateway_id,
         partition,
         service_type,
         service_name,
         observation_timestamp,
         payload_digest,
         payload_bytes,
         attempt_count,
         consecutive_timeout_count,
         state,
         last_outcome,
         last_error,
         quarantine_reason,
         quarantined_at,
         last_attempt_at,
         retained_status,
         inserted_at,
         updated_at
       ]) do
    %{
      id: id,
      agent_id: agent_id,
      result_key: result_key,
      gateway_id: gateway_id,
      partition: partition,
      service_type: service_type,
      service_name: service_name,
      observation_timestamp: observation_timestamp,
      payload_digest: payload_digest,
      payload_bytes: payload_bytes,
      attempt_count: attempt_count,
      consecutive_timeout_count: consecutive_timeout_count,
      state: state,
      last_outcome: last_outcome,
      last_error: last_error,
      quarantine_reason: quarantine_reason,
      quarantined_at: quarantined_at,
      last_attempt_at: last_attempt_at,
      retained_status: normalize_retained_status_map(retained_status),
      inserted_at: inserted_at,
      updated_at: updated_at
    }
  end

  defp extract_payload(status) do
    case status[:message] || status["message"] do
      message when is_binary(message) and byte_size(message) > 0 ->
        case Jason.decode(message) do
          {:ok, decoded} when is_map(decoded) ->
            decoded

          {:ok, [first | _]} when is_map(first) ->
            first

          _ ->
            %{}
        end

      message when is_map(message) ->
        message

      _ ->
        %{}
    end
  end

  defp resolve_observed_at(payload, status) do
    FieldParser.parse_timestamp(
      fetch_value(payload, ["observed_at", "observedAt"]) ||
        status[:agent_timestamp] ||
        status["agent_timestamp"] ||
        status[:timestamp] ||
        status["timestamp"]
    )
  end

  defp compute_payload_digest(payload, status) when is_map(payload) and map_size(payload) > 0 do
    payload
    |> Map.delete(PluginResultReportedMarker.marker_key())
    |> PluginResultReportedMarker.payload_digest()
  end

  defp compute_payload_digest(_payload, status) do
    raw = to_string(status[:message] || status["message"] || "")
    :sha256 |> :crypto.hash(raw) |> Base.encode16(case: :lower)
  end

  defp resolve_payload_bytes(_status, bytes) when is_integer(bytes) and bytes > 0, do: bytes

  defp resolve_payload_bytes(status, _bytes) do
    case status[:message] || status["message"] do
      message when is_binary(message) -> byte_size(message)
      _ -> :erlang.external_size(status)
    end
  end

  defp serialize_retained_status(status) when is_map(status) do
    keys = [
      :source,
      :agent_id,
      :gateway_id,
      :partition,
      :service_type,
      :service_name,
      :service_id,
      :available,
      :message,
      :details,
      :timestamp,
      :agent_timestamp,
      :delivery_capabilities,
      :plugin_assignment_id,
      :plugin_package_id,
      :plugin_wasi_Digest
    ]

    Enum.reduce(keys, %{}, fn key, acc ->
      string_key = Atom.to_string(key)
      value = Map.get(status, key) || Map.get(status, string_key)

      case serialize_status_value(value) do
        nil -> acc
        serialized -> Map.put(acc, string_key, serialized)
      end
    end)
  end

  defp serialize_status_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp serialize_status_value(value) when is_atom(value) and not is_boolean(value),
    do: Atom.to_string(value)

  defp serialize_status_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value), do: value

  defp serialize_status_value(value) when is_list(value),
    do: Enum.map(value, &serialize_status_value/1)

  defp serialize_status_value(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), serialize_status_value(v)} end)

  defp serialize_status_value(_value), do: nil

  defp deserialize_retained_status(map) when is_map(map) do
    %{
      source: map["source"] || "plugin-result",
      agent_id: map["agent_id"],
      gateway_id: map["gateway_id"],
      partition: map["partition"] || "default",
      service_type: map["service_type"] || "plugin",
      service_name: map["service_name"],
      service_id: map["service_id"],
      available: map["available"],
      message: map["message"],
      details: map["details"],
      timestamp: parse_optional_timestamp(map["timestamp"]),
      agent_timestamp: parse_optional_timestamp(map["agent_timestamp"]),
      delivery_capabilities: map["delivery_capabilities"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp deserialize_retained_status(_other), do: %{}

  defp parse_optional_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_optional_timestamp(%DateTime{} = dt), do: dt
  defp parse_optional_timestamp(_), do: nil

  defp normalize_retained_status_map(value) when is_map(value), do: value

  defp normalize_retained_status_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp normalize_retained_status_map(_), do: %{}

  defp fetch_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key) || Map.get(map, to_string(key))
    end)
  end

  defp format_error(reason) do
    reason
    |> inspect(limit: 20, printable_limit: @error_max_bytes)
    |> String.slice(0, @error_max_bytes)
  end
end
