defmodule ServiceRadar.Observability.PluginResultQuarantine do
  @moduledoc """
  Bounds redelivery of a capability-retained plugin result whose ingestion keeps
  exceeding the retained plugin lane's worker budget.

  `platform.plugin_result_ingestion_attempts` holds one row per `{agent_id,
  result_key}`. The result key is the logical service identity plus a digest of
  the raw retained message, which the agent redelivers byte for byte.

  - The lane coordinator calls `record_execution_timeout/2` after it kills an
    over-budget worker. The killed worker's transaction is rolled back, so the
    count is written by the coordinator in its own single-statement upsert, and
    the increment and the quarantine transition happen atomically in the
    database. Once `consecutive_timeout_count` reaches
    `max_consecutive_timeouts/0` the row becomes `"quarantined"`.
  - The worker calls `lookup/1` before running handlers. A quarantined result is
    acknowledged without running them, so the agent drops it and its retained
    queue drains. That acknowledgement leaves the row in place.
  - `clear/1` deletes the row after a success or a committed handler-domain
    failure. The quarantine acknowledgement does not.
  - `prune/1` deletes expired attempt rows in primary-key batches: active,
    non-quarantined rows older than `active_retention_days/0` (default 7 days)
    and quarantined rows older than `quarantine_retention_days/0` (default 30
    days).

  Only execution timeouts count. An admission timeout means the lane could not
  start the result at all; it says the lane is congested, not that this result is
  too expensive, and counting it would quarantine results that were only queued
  behind a slow one.

  Every outcome is counted on the `:retained_plugin_result` ingestion lane
  (`result_ingestion_events_attempt_recorded`, `_quarantined`,
  `_quarantine_acknowledged`, `_attempt_pruned` and `_attempt_store_failed`). A
  store failure is logged and fails open: the result is ingested, or redelivered,
  as if no attempt had been recorded.
  """

  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.Ingestion.RuntimeMetrics
  alias ServiceRadar.Observability.ServiceStateRegistry.PluginStateContract
  alias ServiceRadar.Repo

  require Logger

  @default_max_consecutive_timeouts 3
  @default_active_retention_days 7
  @default_quarantine_retention_days 30
  @default_prune_batch_size 1_000
  @quarantine_reason "execution_timeout_budget_exceeded"
  @store_timeout_ms 2_000
  @prune_timeout_ms 30_000
  @lane :retained_plugin_result

  @prune_batch_sql """
  WITH doomed AS (
    SELECT id
    FROM platform.plugin_result_ingestion_attempts
    WHERE (state = 'active' AND last_attempt_at < $1)
       OR (state = 'quarantined' AND COALESCE(quarantined_at, last_attempt_at) < $2)
    ORDER BY id
    LIMIT $3
  )
  DELETE FROM platform.plugin_result_ingestion_attempts AS attempt
  USING doomed
  WHERE attempt.id = doomed.id
  """

  # The retained status fields an operator retry needs to re-run ingestion.
  @retained_keys ~w(source agent_id gateway_id partition authenticated_partition service_type
                    service_name available message timestamp agent_timestamp kv_store_id
                    delivery_capabilities)a
  @provenance_keys ~w(assignment_id plugin_id plugin_package_id plugin_version content_hash)a

  @listed_columns ~w(agent_id result_key gateway_id partition service_type service_name
                     observation_timestamp payload_digest payload_bytes attempt_count
                     consecutive_timeout_count state last_outcome quarantine_reason
                     quarantined_at last_attempt_at)a

  @type identity :: %{agent_id: String.t(), result_key: String.t()}

  @doc """
  Consecutive execution timeouts before a result is quarantined (default
  #{@default_max_consecutive_timeouts}).
  """
  @spec max_consecutive_timeouts() :: pos_integer()
  def max_consecutive_timeouts do
    case Application.get_env(:serviceradar_core, :plugin_result_quarantine_max_timeouts) do
      configured when is_integer(configured) and configured > 0 -> configured
      _ -> @default_max_consecutive_timeouts
    end
  end

  @doc """
  Retention window in days for active, non-quarantined attempt rows (default
  #{@default_active_retention_days}; `:plugin_result_attempt_active_retention_days`
  in `:serviceradar_core`, `SERVICERADAR_PLUGIN_RESULT_ATTEMPT_ACTIVE_RETENTION_DAYS`).
  """
  @spec active_retention_days() :: pos_integer()
  def active_retention_days do
    case Application.get_env(
           :serviceradar_core,
           :plugin_result_attempt_active_retention_days,
           @default_active_retention_days
         ) do
      days when is_integer(days) and days > 0 -> days
      _ -> @default_active_retention_days
    end
  end

  @doc """
  Retention window in days for quarantined attempt rows (default
  #{@default_quarantine_retention_days}; `:plugin_result_quarantine_retention_days`
  in `:serviceradar_core`, `SERVICERADAR_PLUGIN_RESULT_QUARANTINE_RETENTION_DAYS`).
  """
  @spec quarantine_retention_days() :: pos_integer()
  def quarantine_retention_days do
    case Application.get_env(
           :serviceradar_core,
           :plugin_result_quarantine_retention_days,
           @default_quarantine_retention_days
         ) do
      days when is_integer(days) and days > 0 -> days
      _ -> @default_quarantine_retention_days
    end
  end

  @doc """
  Batch size for primary-key attempt row pruning (default
  #{@default_prune_batch_size}; `:plugin_result_attempt_prune_batch_size` in
  `:serviceradar_core`).
  """
  @spec prune_batch_size() :: pos_integer()
  def prune_batch_size do
    case Application.get_env(
           :serviceradar_core,
           :plugin_result_attempt_prune_batch_size,
           @default_prune_batch_size
         ) do
      size when is_integer(size) and size > 0 -> min(size, 10_000)
      _ -> @default_prune_batch_size
    end
  end

  @doc "The attempt-row key of a retained plugin status."
  @spec identity(map()) :: identity()
  def identity(status) when is_map(status) do
    {contract, digest} = key_parts(status)
    %{agent_id: contract.agent_id, result_key: result_key(contract, digest)}
  end

  @doc """
  Returns the result's attempt state: `:none` without a row, `:attempted` when
  an earlier attempt timed out, or `:quarantined`. A quarantined lookup is
  counted as an acknowledgement. A store failure returns `:none`.
  """
  @spec lookup(identity()) :: :none | :attempted | :quarantined
  def lookup(%{agent_id: agent_id, result_key: result_key}) do
    case query(
           "SELECT state FROM platform.plugin_result_ingestion_attempts " <>
             "WHERE agent_id = $1 AND result_key = $2",
           [agent_id, result_key]
         ) do
      {:ok, %{rows: [["quarantined"]]}} ->
        observe(:quarantine_acknowledged)
        :quarantined

      {:ok, %{rows: [_row]}} ->
        :attempted

      {:ok, %{rows: []}} ->
        :none

      {:error, reason} ->
        store_failed(:lookup, reason)
        :none
    end
  end

  @doc "Deletes the attempt row of an acknowledged result."
  @spec clear(identity()) :: :ok
  def clear(%{agent_id: agent_id, result_key: result_key}) do
    case query(
           "DELETE FROM platform.plugin_result_ingestion_attempts " <>
             "WHERE agent_id = $1 AND result_key = $2",
           [agent_id, result_key]
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> store_failed(:clear, reason)
    end
  end

  @doc """
  Counts one execution timeout of `status` and quarantines it once the
  consecutive count reaches `max_consecutive_timeouts/0`.

  Called by the lane coordinator, never by the killed worker, so the write
  commits on its own.
  """
  @spec record_execution_timeout(map(), non_neg_integer() | nil) :: :ok
  def record_execution_timeout(status, payload_bytes) when is_map(status) do
    {contract, digest} = key_parts(status)
    agent_id = contract.agent_id
    result_key = result_key(contract, digest)
    now = DateTime.utc_now()

    params = [
      agent_id,
      result_key,
      contract.gateway_id,
      contract.partition,
      contract.service_type,
      contract.service_name,
      observed_at(status),
      digest,
      payload_bytes(status, payload_bytes),
      max_consecutive_timeouts(),
      @quarantine_reason,
      now,
      retained_status(status)
    ]

    case query(record_timeout_sql(), params) do
      {:ok, %{rows: [[attempts, newly_quarantined]]}} ->
        observe(:attempt_recorded)

        if newly_quarantined do
          observe(:quarantined)

          Logger.warning(
            "Quarantined retained plugin result after #{attempts} execution timeouts: " <>
              "agent_id=#{agent_id} result_key=#{result_key}"
          )
        end

        :ok

      {:error, reason} ->
        store_failed(:record_execution_timeout, reason)
    end
  end

  @doc """
  Operator-visible quarantined results, newest first. Filters: `:agent_id`,
  `:service_name`, `:partition`; `:limit` defaults to 100.
  """
  @spec list_quarantined(keyword()) :: [map()]
  def list_quarantined(opts \\ []) do
    filters = Enum.filter([:agent_id, :service_name, :partition], &opts[&1])

    where =
      filters
      |> Enum.with_index(2)
      |> Enum.map_join("", fn {key, index} -> " AND #{key} = $#{index}" end)

    sql = """
    SELECT #{Enum.join(@listed_columns, ", ")}
    FROM platform.plugin_result_ingestion_attempts
    WHERE state = 'quarantined'#{where}
    ORDER BY quarantined_at DESC
    LIMIT $1
    """

    %{rows: rows} =
      Repo.query!(sql, [Keyword.get(opts, :limit, 100) | Enum.map(filters, &opts[&1])])

    Enum.map(rows, &(@listed_columns |> Enum.zip(&1) |> Map.new()))
  end

  @doc """
  Operator retry of a quarantined result from its stored status.

  Handlers run while the row is still quarantined. A success or a committed
  handler-domain failure deletes the row. Any other result leaves it
  quarantined, and an exception does too, so the retry can be repeated.
  """
  @spec retry_quarantined(String.t(), String.t()) :: :ok | {:error, term()}
  def retry_quarantined(agent_id, result_key)
      when is_binary(agent_id) and is_binary(result_key) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT retained_status
        FROM platform.plugin_result_ingestion_attempts
        WHERE agent_id = $1 AND result_key = $2 AND state = 'quarantined'
        """,
        [agent_id, result_key]
      )

    case rows do
      [[retained]] ->
        ServiceRadar.Ingestion.ResultIngestor.reingest_quarantined_plugin(restore(retained))

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Deletes expired rows from `platform.plugin_result_ingestion_attempts` in
  primary-key batches:

  - Active, non-quarantined rows (`state = 'active'`) whose `last_attempt_at`
    is older than `active_retention_days/0`.
  - Quarantined rows (`state = 'quarantined'`) whose `quarantined_at` (falling
    back to `last_attempt_at`) is older than `quarantine_retention_days/0`.

  Each deleted batch is counted on the `:retained_plugin_result` ingestion lane
  under `:attempt_pruned` (`result_ingestion_events_attempt_pruned`).
  """
  @spec prune(keyword()) ::
          {:ok, %{deleted: non_neg_integer(), batches: non_neg_integer()}} | {:error, term()}
  def prune(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    active_days = positive_opt(opts, :active_retention_days, active_retention_days())
    quarantine_days = positive_opt(opts, :quarantine_retention_days, quarantine_retention_days())
    batch_size = min(positive_opt(opts, :batch_size, prune_batch_size()), 10_000)

    active_cutoff = DateTime.shift(now, day: -active_days)
    quarantine_cutoff = DateTime.shift(now, day: -quarantine_days)

    do_prune(active_cutoff, quarantine_cutoff, batch_size, 0, 0)
  end

  defp do_prune(active_cutoff, quarantine_cutoff, batch_size, total_deleted, batches) do
    case Repo.query(
           @prune_batch_sql,
           [active_cutoff, quarantine_cutoff, batch_size],
           timeout: @prune_timeout_ms
         ) do
      {:ok, %{num_rows: deleted}} when deleted > 0 ->
        RuntimeMetrics.record(@lane, :attempt_pruned, %{count: deleted})
        total_deleted = total_deleted + deleted
        batches = batches + 1

        if deleted < batch_size do
          {:ok, %{deleted: total_deleted, batches: batches}}
        else
          do_prune(active_cutoff, quarantine_cutoff, batch_size, total_deleted, batches)
        end

      {:ok, %{num_rows: 0}} ->
        {:ok, %{deleted: total_deleted, batches: batches}}

      {:error, _reason} = error ->
        error
    end
  end

  defp positive_opt(opts, key, default) do
    case Keyword.get(opts, key) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp key_parts(status), do: {PluginStateContract.status_identity(status), digest(status)}

  defp result_key(contract, digest),
    do: Enum.join([contract.partition, contract.service_type, contract.service_name, digest], ":")

  defp record_timeout_sql do
    """
    INSERT INTO platform.plugin_result_ingestion_attempts AS attempt (
      agent_id, result_key, gateway_id, partition, service_type, service_name,
      observation_timestamp, payload_digest, payload_bytes, attempt_count,
      consecutive_timeout_count, state, last_outcome, last_error, quarantine_reason,
      quarantined_at, last_attempt_at, retained_status, inserted_at, updated_at
    )
    VALUES (
      $1, $2, $3, $4, $5, $6, $7, $8, $9, 1, 1,
      CASE WHEN $10::integer <= 1 THEN 'quarantined' ELSE 'active' END,
      'execution_timeout', 'worker_execution_timeout',
      CASE WHEN $10::integer <= 1 THEN $11::text END,
      CASE WHEN $10::integer <= 1 THEN $12::timestamp END,
      $12::timestamp, $13::jsonb, $12::timestamp, $12::timestamp
    )
    ON CONFLICT (agent_id, result_key) DO UPDATE SET
      gateway_id = EXCLUDED.gateway_id,
      payload_bytes = GREATEST(attempt.payload_bytes, EXCLUDED.payload_bytes),
      attempt_count = attempt.attempt_count + 1,
      consecutive_timeout_count = attempt.consecutive_timeout_count + 1,
      state = CASE
        WHEN attempt.state = 'quarantined' OR attempt.consecutive_timeout_count + 1 >= $10::integer
          THEN 'quarantined'
        ELSE 'active'
      END,
      last_outcome = 'execution_timeout',
      last_error = 'worker_execution_timeout',
      quarantine_reason = CASE
        WHEN attempt.state = 'quarantined' THEN attempt.quarantine_reason
        WHEN attempt.consecutive_timeout_count + 1 >= $10::integer THEN $11::text
      END,
      quarantined_at = CASE
        WHEN attempt.state = 'quarantined' THEN attempt.quarantined_at
        WHEN attempt.consecutive_timeout_count + 1 >= $10::integer THEN $12::timestamp
      END,
      last_attempt_at = $12::timestamp,
      updated_at = $12::timestamp
    RETURNING attempt_count,
      state = 'quarantined' AND quarantined_at IS NOT DISTINCT FROM $12::timestamp
    """
  end

  defp query(sql, params) do
    Repo.query(sql, params, timeout: @store_timeout_ms)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp store_failed(operation, reason) do
    observe(:attempt_store_failed)

    Logger.warning(
      "Plugin result attempt store #{operation} failed: " <>
        inspect(reason, limit: 10, printable_limit: 500)
    )

    :ok
  end

  defp observe(event) do
    RuntimeMetrics.record(@lane, event, %{count: 1})
  end

  defp digest(status) do
    :sha256
    |> :crypto.hash(message_bytes(status))
    |> Base.encode16(case: :lower)
  end

  defp message_bytes(status) do
    case status[:message] do
      message when is_binary(message) -> message
      message -> :erlang.term_to_binary(message)
    end
  end

  defp payload_bytes(_status, bytes) when is_integer(bytes) and bytes > 0, do: bytes
  defp payload_bytes(status, _bytes), do: byte_size(message_bytes(status))

  defp observed_at(status) do
    payload =
      with message when is_binary(message) <- status[:message],
           {:ok, decoded} <- Jason.decode(message) do
        decoded
      else
        _ -> nil
      end

    observed =
      case payload do
        %{"observed_at" => value} -> value
        [%{"observed_at" => value} | _rest] -> value
        _ -> status[:agent_timestamp]
      end

    FieldParser.parse_timestamp(observed)
  end

  defp retained_status(status) do
    status
    |> Map.take(@retained_keys)
    |> maybe_put_provenance(status[:plugin_provenance])
  end

  defp maybe_put_provenance(retained, provenance) when is_map(provenance),
    do: Map.put(retained, :plugin_provenance, Map.take(provenance, @provenance_keys))

  defp maybe_put_provenance(retained, _provenance), do: retained

  defp restore(retained) when is_map(retained) do
    status = take_atom_keys(retained, @retained_keys)

    case retained["plugin_provenance"] do
      provenance when is_map(provenance) ->
        Map.put(status, :plugin_provenance, take_atom_keys(provenance, @provenance_keys))

      _ ->
        status
    end
  end

  defp take_atom_keys(map, keys) do
    for key <- keys, Map.has_key?(map, Atom.to_string(key)), into: %{} do
      {key, Map.fetch!(map, Atom.to_string(key))}
    end
  end
end
