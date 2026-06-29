defmodule ServiceRadar.WorkloadIdentity do
  @moduledoc """
  Coalesces node-local workload identity snapshots forwarded by agents.

  The collector runs as its own native add-on and writes bounded JSON snapshots
  locally. The Go agent forwards those snapshots through agent-gateway; this
  module performs the upstream decode and current-state upsert so netprobe is not
  required to carry workload metadata.
  """

  alias ServiceRadar.FlowAttribution
  alias ServiceRadar.Repo

  require Logger

  @table "workload_identity_current"
  @max_identities_per_snapshot 50_000

  @spec persist_snapshot(map()) :: :ok | {:error, term()}
  def persist_snapshot(%{message: message} = status) when is_binary(message) do
    with {:ok, snapshot} <- Jason.decode(message),
         {:ok, rows} <- rows_from_snapshot(snapshot, status) do
      guarded_write(rows, status, [])
    else
      {:error, reason} = error ->
        Logger.warning("WorkloadIdentity.persist_snapshot failed: #{inspect(reason)}")
        error
    end
  end

  def persist_snapshot(_status), do: {:error, :missing_workload_identity_message}

  @doc false
  # Testable seam: decode + build the candidate rows for a snapshot without the
  # DB write or the skip-guard. Used by the skip-guard unit tests to prove the
  # fingerprint is stable across snapshots that differ only in observed_at.
  @spec snapshot_rows(map()) :: {:ok, [map()]} | {:error, term()}
  def snapshot_rows(%{message: message} = status) when is_binary(message) do
    with {:ok, snapshot} <- Jason.decode(message) do
      rows_from_snapshot(snapshot, status)
    end
  end

  def snapshot_rows(_status), do: {:error, :missing_workload_identity_message}

  defp rows_from_snapshot(snapshot, status) when is_map(snapshot) do
    identities = Map.get(snapshot, "identities", [])

    cond do
      not is_list(identities) ->
        {:error, :invalid_workload_identity_identities}

      length(identities) > @max_identities_per_snapshot ->
        {:error, :workload_identity_snapshot_too_large}

      true ->
        observed_at = observed_at(snapshot)
        partition = normalize_string(status[:partition]) || "default"
        agent_id = normalize_string(status[:agent_id])
        gateway_id = normalize_string(status[:gateway_id])
        snapshot_degradation = normalize_string(Map.get(snapshot, "degradation_reason"))
        snapshot_endpoint = Map.get(snapshot, "endpoint")
        snapshot_context = workload_context_from_snapshot(snapshot)

        rows =
          identities
          |> Enum.map(
            &row_from_lookup(
              &1,
              observed_at,
              partition,
              agent_id,
              gateway_id,
              snapshot_endpoint,
              snapshot_degradation,
              snapshot_context
            )
          )
          |> Enum.reject(&is_nil/1)

        {:ok, rows}
    end
  end

  defp rows_from_snapshot(_snapshot, _status), do: {:error, :invalid_workload_identity_snapshot}

  defp row_from_lookup(
         lookup,
         observed_at,
         partition,
         agent_id,
         gateway_id,
         snapshot_endpoint,
         snapshot_degradation,
         snapshot_context
       )
       when is_map(lookup) do
    identity = Map.get(lookup, "identity")
    identity_container_id = if is_map(identity), do: Map.get(identity, "container_id")

    container_id =
      normalize_string(Map.get(lookup, "container_id")) || normalize_string(identity_container_id)

    if container_id in [nil, ""] or not is_map(identity) do
      nil
    else
      identity =
        identity
        |> Map.put_new("container_id", container_id)
        |> Map.put_new("snapshot_endpoint", snapshot_endpoint)
        |> Map.put_new("snapshot_degradation_reason", snapshot_degradation)
        |> put_snapshot_workload_context(snapshot_context)

      %{
        observed_at: observed_at,
        partition: partition,
        agent_id: agent_id,
        gateway_id: gateway_id,
        container_id: container_id,
        pod_uid: normalize_string(Map.get(identity, "pod_uid")),
        pod_namespace: normalize_string(Map.get(identity, "pod_namespace")),
        pod_name: normalize_string(Map.get(identity, "pod_name")),
        container_name: normalize_string(Map.get(identity, "container_name")),
        image:
          normalize_string(Map.get(identity, "image")) ||
            normalize_string(Map.get(identity, "image_ref")),
        runtime_source: runtime_source(identity),
        confidence: normalize_string(Map.get(identity, "confidence")),
        degradation_reason:
          normalize_string(Map.get(identity, "degradation_reason")) || snapshot_degradation,
        identity: identity
      }
    end
  end

  defp row_from_lookup(
         _lookup,
         _observed_at,
         _partition,
         _agent_id,
         _gateway_id,
         _endpoint,
         _degradation,
         _snapshot_context
       ),
       do: nil

  # ---------------------------------------------------------------------------
  # Change-detection skip-guard (fj #33)
  #
  # persist_snapshot/1 runs once per agent status report. On a stable cluster the
  # container->identity snapshot for a given {partition, agent_id} rarely changes,
  # yet every call previously re-ran the workload_identity_current upsert (plus a
  # flow-attribution backfill query) with byte-identical content -- the #1
  # demo-CNPG CPU driver via dead-tuple/WAL/autovacuum churn for zero net change.
  #
  # We fingerprint ONLY the identity content of the rows (the volatile
  # observed_at / inserted_at / updated_at are intentionally EXCLUDED, so an
  # unchanged snapshot carrying a fresh observed_at hashes identically -- this was
  # the exact #4298 first-draft bug) and skip the write when the fingerprint is
  # unchanged for the same {partition, agent_id} AND the heartbeat window has not
  # elapsed. Mirrors the #4298 canonical-rebuild skip-guard.
  #
  # State lives in a process-local named ETS table rather than a shared DB row: a
  # pod restart simply re-syncs once per agent (a one-time cost, NOT steady-state),
  # which is cheaper than cross-replica coordination for this hot path.
  #
  # RETENTION / HEARTBEAT: platform.workload_identity_current is NOT
  # retention-pruned anywhere (FlowAttribution.Retention.prune/0 only touches
  # flow_process_attribution_current, and WorkloadBackfill only reads this table),
  # so a skip can never let a live row be pruned out from under a reader. We still
  # force a periodic refresh of observed_at (default 30 min) so staleness reads
  # stay reasonable. If row-level retention is ever added to this table, set the
  # heartbeat to roughly HALF that retention so a still-current row is refreshed
  # well before it could be pruned.
  #
  # FAIL-OPEN: any exception raised inside the guard falls through to a normal
  # write -- a guard bug must never drop a real change.

  @guard_table :workload_identity_skip_guard
  @default_skip_guard_heartbeat_ms 30 * 60 * 1_000

  @doc false
  # Apply the skip-guard, then persist via `:writer` (default insert_rows/1).
  # opts (all optional; used by tests to drive the guard deterministically):
  #   :writer          - 1-arity row writer (default &insert_rows/1)
  #   :now_ms          - millisecond clock (default System.system_time/1)
  #   :heartbeat_ms    - heartbeat window override
  #   :fingerprint_fun - fingerprint override (used to exercise fail-open)
  @spec guarded_write([map()], map(), keyword()) :: :ok | {:error, term()}
  def guarded_write([], _status, opts) do
    writer(opts).([])
  end

  def guarded_write(rows, status, opts) do
    if guard_enabled?() do
      do_guarded_write(rows, status, opts)
    else
      writer(opts).(rows)
    end
  end

  defp do_guarded_write(rows, status, opts) do
    writer = writer(opts)
    now_ms = Keyword.get(opts, :now_ms, System.system_time(:millisecond))

    decision =
      try do
        fingerprint_fun = Keyword.get(opts, :fingerprint_fun, &rows_fingerprint/1)
        heartbeat_ms = Keyword.get(opts, :heartbeat_ms, heartbeat_ms())
        key = guard_key(status)
        fingerprint = fingerprint_fun.(rows)

        case skip_decision(fingerprint, lookup_guard(key), heartbeat_ms, now_ms) do
          :skip -> :skip
          :proceed -> {:proceed, key, fingerprint}
        end
      rescue
        error ->
          Logger.warning(
            "WorkloadIdentity skip-guard raised; writing through (fail-open): #{inspect(error)}"
          )

          :fail_open
      end

    case decision do
      :skip ->
        :ok

      :fail_open ->
        writer.(rows)

      {:proceed, key, fingerprint} ->
        case writer.(rows) do
          :ok ->
            record_guard(key, fingerprint, now_ms)
            :ok

          other ->
            other
        end
    end
  end

  defp writer(opts), do: Keyword.get(opts, :writer, &insert_rows/1)

  @doc false
  # Pure skip/proceed decision (no DB, no ETS) -- unit-testable in isolation.
  # Returns :skip ONLY when the fingerprint matches the stored fingerprint AND the
  # heartbeat window has not elapsed. A nil stored entry (cold start / pod
  # restart), a changed fingerprint, or an elapsed heartbeat all :proceed. The
  # function is total: any unexpected shape falls through to :proceed (fail-open).
  @spec skip_decision(
          non_neg_integer(),
          {non_neg_integer(), integer()} | nil,
          pos_integer(),
          integer()
        ) :: :skip | :proceed
  def skip_decision(fingerprint, stored, heartbeat_ms, now_ms)

  def skip_decision(fingerprint, {stored_fingerprint, last_written_ms}, heartbeat_ms, now_ms)
      when is_integer(fingerprint) and stored_fingerprint == fingerprint and
             is_integer(last_written_ms) and
             is_integer(heartbeat_ms) and is_integer(now_ms) do
    if now_ms - last_written_ms < heartbeat_ms do
      :skip
    else
      :proceed
    end
  end

  def skip_decision(_fingerprint, _stored, _heartbeat_ms, _now_ms), do: :proceed

  @doc false
  # Stable content fingerprint. Rows are sorted by container_id first so list
  # order can never flip the hash, and the volatile timestamps (observed_at /
  # inserted_at / updated_at) are excluded so an unchanged snapshot with a fresh
  # observed_at hashes identically.
  @spec rows_fingerprint([map()]) :: non_neg_integer()
  def rows_fingerprint(rows) when is_list(rows) do
    rows
    |> Enum.map(&fingerprint_row/1)
    |> Enum.sort()
    |> :erlang.phash2()
  end

  defp fingerprint_row(row) do
    {
      Map.get(row, :container_id),
      Map.get(row, :gateway_id),
      Map.get(row, :pod_uid),
      Map.get(row, :pod_namespace),
      Map.get(row, :pod_name),
      Map.get(row, :container_name),
      Map.get(row, :image),
      Map.get(row, :runtime_source),
      Map.get(row, :confidence),
      Map.get(row, :degradation_reason),
      Map.get(row, :identity)
    }
  end

  defp guard_key(status) do
    partition = normalize_string(status[:partition]) || "default"
    agent_id = normalize_string(status[:agent_id])
    {partition, agent_id}
  end

  defp lookup_guard(key) do
    ensure_guard_table()

    case :ets.lookup(@guard_table, key) do
      [{^key, {fingerprint, last_written_ms}}] -> {fingerprint, last_written_ms}
      _ -> nil
    end
  end

  defp record_guard(key, fingerprint, now_ms) do
    ensure_guard_table()
    :ets.insert(@guard_table, {key, {fingerprint, now_ms}})
    :ok
  rescue
    _ -> :ok
  end

  defp ensure_guard_table do
    case :ets.whereis(@guard_table) do
      :undefined ->
        try do
          :ets.new(@guard_table, [
            :set,
            :public,
            :named_table,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          # Lost a creation race with a concurrent caller; the table now exists.
          ArgumentError -> :ok
        end

      _tid ->
        :ok
    end

    @guard_table
  end

  defp guard_enabled? do
    case Keyword.get(config(), :skip_guard_enabled, true) do
      false -> false
      _ -> true
    end
  end

  defp heartbeat_ms do
    config()
    |> Keyword.get(:skip_guard_heartbeat_ms, @default_skip_guard_heartbeat_ms)
    |> normalize_positive_int(@default_skip_guard_heartbeat_ms)
  end

  defp config, do: Application.get_env(:serviceradar_core, __MODULE__, [])

  defp normalize_positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive_int(_value, default), do: default

  defp insert_rows([]), do: :ok

  defp insert_rows(rows) do
    now = DateTime.utc_now()

    rows =
      rows
      |> Enum.map(&Map.merge(&1, %{inserted_at: now, updated_at: now}))
      |> Jason.encode!()

    sql = """
    INSERT INTO platform.#{@table} (
      observed_at,
      inserted_at,
      updated_at,
      partition,
      agent_id,
      gateway_id,
      container_id,
      pod_uid,
      pod_namespace,
      pod_name,
      container_name,
      image,
      runtime_source,
      confidence,
      degradation_reason,
      identity
    )
    SELECT
      r.observed_at,
      r.inserted_at,
      r.updated_at,
      r.partition,
      r.agent_id,
      r.gateway_id,
      r.container_id,
      r.pod_uid,
      r.pod_namespace,
      r.pod_name,
      r.container_name,
      r.image,
      r.runtime_source,
      r.confidence,
      r.degradation_reason,
      r.identity
    FROM jsonb_to_recordset(($1::text)::jsonb) AS r(
      observed_at timestamptz,
      inserted_at timestamptz,
      updated_at timestamptz,
      partition text,
      agent_id text,
      gateway_id text,
      container_id text,
      pod_uid text,
      pod_namespace text,
      pod_name text,
      container_name text,
      image text,
      runtime_source text,
      confidence text,
      degradation_reason text,
      identity jsonb
    )
    ON CONFLICT (partition, agent_id, container_id)
    DO UPDATE SET
      observed_at = EXCLUDED.observed_at,
      updated_at = EXCLUDED.updated_at,
      gateway_id = EXCLUDED.gateway_id,
      pod_uid = EXCLUDED.pod_uid,
      pod_namespace = EXCLUDED.pod_namespace,
      pod_name = EXCLUDED.pod_name,
      container_name = EXCLUDED.container_name,
      image = EXCLUDED.image,
      runtime_source = EXCLUDED.runtime_source,
      confidence = EXCLUDED.confidence,
      degradation_reason = EXCLUDED.degradation_reason,
      identity = EXCLUDED.identity
    """

    case Repo.query(sql, [rows]) do
      {:ok, _result} ->
        backfill_flow_attribution(rows)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp backfill_flow_attribution(encoded_rows) do
    with {:ok, rows} <- Jason.decode(encoded_rows),
         {:ok, _count} <- FlowAttribution.backfill_current_workload_identity(rows) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("WorkloadIdentity flow attribution backfill failed: #{inspect(reason)}")
        :ok
    end
  end

  defp observed_at(snapshot) do
    case Map.get(snapshot, "observed_at_unix_nano") do
      value when is_integer(value) and value > 0 ->
        value
        |> System.convert_time_unit(:nanosecond, :microsecond)
        |> DateTime.from_unix!(:microsecond)

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} when int > 0 ->
            int
            |> System.convert_time_unit(:nanosecond, :microsecond)
            |> DateTime.from_unix!(:microsecond)

          _ ->
            DateTime.utc_now()
        end

      _ ->
        DateTime.utc_now()
    end
  end

  defp runtime_source(%{"runtime_source" => value}) when is_binary(value), do: value

  defp runtime_source(%{"runtime_source" => value}) when is_map(value) do
    value
    |> Map.values()
    |> List.first()
    |> normalize_string()
  end

  defp runtime_source(_identity), do: nil

  defp workload_context_from_snapshot(snapshot) do
    %{
      "context_name" => normalize_string(Map.get(snapshot, "context_name"))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp put_snapshot_workload_context(identity, context) when map_size(context) == 0 do
    identity
  end

  defp put_snapshot_workload_context(identity, context) do
    Enum.reduce(context, identity, fn {key, value}, acc ->
      Map.put_new(acc, key, value)
    end)
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      sentinel when sentinel in ["nil", "null", "undefined"] -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_string()

  defp normalize_string(_value), do: nil
end
