defmodule ServiceRadar.ColdTier.RetentionFence do
  @moduledoc """
  The single authority for TimescaleDB retention-policy DDL on cold-tier
  registry tables (OpenSpec add-tiered-telemetry-offload, task 2.4; spec
  requirement "Retention policy installation is fenced through a single
  shared helper").

  Both `ServiceRadar.Observability.DataRetentionWorker` and retention-policy
  migrations MUST route registry-table policy DDL through this module. When
  the cold tier is enabled for a deployment:

    * in-database retention policies for registry tables are REMOVED (never
      re-armed) so the TimescaleDB background worker can never drop
      un-exported chunks autonomously;
    * `drop_chunks` is bounded by `safe_drop_point/2`: the oldest of the
      retention cutoff, the analytics-head-acknowledged query boundary (B),
      and the first non-verified chunk — so only contiguously verified,
      below-boundary data can ever be dropped.

  When the cold tier is disabled (the OSS default), every function delegates
  to today's behavior unchanged.
  """

  alias Ecto.Adapters.SQL
  alias ServiceRadar.ColdTier.Registry
  alias ServiceRadar.Repo

  require Logger

  @query_timeout_ms 120_000

  @doc """
  Whether in-database retention policies are fenced off for this table
  (cold tier enabled AND the table is in the registry).
  """
  @spec fenced?(String.t()) :: boolean()
  def fenced?(table_name) do
    Registry.enabled?() and Registry.member?(table_name)
  end

  @doc """
  Reconcile the in-database retention policy for a table.

  Unfenced: remove + re-add the policy at `retention_days` (current
  behavior). Fenced: remove the policy and do not re-add it. Safe to call
  from migrations and from the retention worker; no-ops gracefully when the
  table is not a hypertable or TimescaleDB is absent.
  """
  @spec reconcile_policy(String.t(), pos_integer(), keyword()) :: :ok
  def reconcile_policy(table_name, retention_days, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    if fenced?(table_name) do
      run_policy_sql(repo, table_name, remove_policy_sql(table_name))
    else
      run_policy_sql(repo, table_name, replace_policy_sql(table_name, retention_days))
    end
  end

  @doc """
  Assert no in-database retention policy exists on fenced tables; returns the
  list of violations (empty when clean). The exporter calls this every run
  and alerts on violations (defense-in-depth against future migrations or
  manual DDL re-arming a policy).
  """
  @spec policy_violations() :: [String.t()]
  def policy_violations(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    if Registry.enabled?() do
      fenced_tables = Registry.table_names()

      case SQL.query(
             repo,
             """
             SELECT hypertable_name
             FROM timescaledb_information.jobs
             WHERE proc_name = 'policy_retention'
               AND hypertable_schema = 'platform'
               AND hypertable_name = ANY($1)
             """,
             [fenced_tables],
             timeout: @query_timeout_ms
           ) do
        {:ok, %{rows: rows}} -> List.flatten(rows)
        {:error, _} -> []
      end
    else
      []
    end
  end

  @doc """
  The timestamp below which chunks of `table_name` may be dropped.

  Unfenced: the plain retention cutoff (`now() - retention_days`). Fenced:
  the least of the retention cutoff, the acknowledged query boundary (B),
  and the start of the first chunk that is not `verified` in the manifest —
  which makes dropping a contiguous verified prefix safe by construction
  (design D3/D5). Returns `{:ok, DateTime.t()}` or `:hold` when nothing may
  be dropped (no boundary acked yet, or the oldest chunk is unverified).
  """
  @spec safe_drop_point(String.t(), pos_integer(), keyword()) :: {:ok, DateTime.t()} | :hold
  def safe_drop_point(table_name, retention_days, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    retention_cutoff = DateTime.add(DateTime.utc_now(), -retention_days * 86_400, :second)

    if fenced?(table_name) do
      with {:ok, boundary} when not is_nil(boundary) <- acked_boundary(repo, table_name),
           {:ok, verified_through} when not is_nil(verified_through) <-
             contiguous_verified_through(repo, table_name, retention_cutoff) do
        point = Enum.min([retention_cutoff, boundary, verified_through], DateTime)

        # Drop-time re-verification (spec: "Retention is offload-gated with
        # drop-time re-verification"): count-check every verified chunk about
        # to be dropped against its manifest row; clamp to the first drifted
        # chunk so it is held for the exporter's re-export instead of dropped.
        {:ok, drift_clamp(repo, table_name, point)}
      else
        _ -> :hold
      end
    else
      {:ok, retention_cutoff}
    end
  end

  defp drift_clamp(repo, table_name, point) do
    time_column =
      case Registry.fetch(table_name) do
        {:ok, entry} -> entry.time_column
        :error -> "timestamp"
      end

    sql = """
    SELECT min(c.range_start)
    FROM timescaledb_information.chunks c
    JOIN platform.cold_chunk_exports m
      ON m.table_name = $1 AND m.chunk_name = c.chunk_name AND m.status = 'verified'
    WHERE c.hypertable_schema = 'platform'
      AND c.hypertable_name = $1
      AND c.range_end <= $2
      AND m.row_count IS DISTINCT FROM (
        SELECT count(*) FROM platform.#{quoted(table_name)} t
        WHERE t.#{quoted(time_column)} >= c.range_start
          AND t.#{quoted(time_column)} < c.range_end
      )
    """

    case SQL.query(repo, sql, [table_name, point], timeout: @query_timeout_ms) do
      {:ok, %{rows: [[nil]]}} ->
        point

      {:ok, %{rows: [[first_drifted_start]]}} ->
        Logger.info(
          "Cold tier: drop-time re-verification found drift; clamping drop point for re-export",
          table: table_name,
          clamped_to: inspect(first_drifted_start)
        )

        first_drifted_start

      {:error, error} ->
        Logger.warning("Cold tier: drop-time re-verification failed; holding drop point",
          table: table_name,
          reason: Exception.message(error)
        )

        point
    end
  end

  defp quoted(name), do: ~s("#{name}")

  # The acked query boundary B for the table, or nil.
  defp acked_boundary(repo, table_name) do
    case SQL.query(
           repo,
           """
           SELECT query_boundary
           FROM platform.cold_tier_boundaries
           WHERE table_name = $1 AND boundary_acked_at IS NOT NULL
           """,
           [table_name],
           timeout: @query_timeout_ms
         ) do
      {:ok, %{rows: [[boundary]]}} -> {:ok, boundary}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} -> {:ok, nil}
      {:error, error} -> {:error, error}
    end
  end

  # The end of the contiguous verified chunk prefix at or below the cutoff:
  # equivalently, the start of the first chunk (by range) that is NOT
  # verified. Chunks entirely above the cutoff don't constrain dropping.
  defp contiguous_verified_through(repo, table_name, cutoff) do
    case SQL.query(
           repo,
           """
           SELECT min(c.range_start)
           FROM timescaledb_information.chunks c
           LEFT JOIN platform.cold_chunk_exports m
             ON m.table_name = $1
            AND m.chunk_name = c.chunk_name
            AND m.status = 'verified'
           WHERE c.hypertable_schema = 'platform'
             AND c.hypertable_name = $1
             AND c.range_start < $2
             AND m.id IS NULL
           """,
           [table_name, cutoff],
           timeout: @query_timeout_ms
         ) do
      {:ok, %{rows: [[nil]]}} ->
        # every chunk below the cutoff is verified
        {:ok, cutoff}

      {:ok, %{rows: [[first_unverified_start]]}} ->
        {:ok, first_unverified_start}

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        {:ok, nil}

      {:error, error} ->
        {:error, error}
    end
  end

  defp remove_policy_sql(table_name) do
    """
    DO $$
    DECLARE
      table_ident text;
      ts_schema text;
    BEGIN
      table_ident := format('%I.%I', 'platform', '#{table_name}');

      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NOT NULL
         AND EXISTS (
           SELECT 1
           FROM timescaledb_information.hypertables
           WHERE hypertable_schema = 'platform'
             AND hypertable_name = '#{table_name}'
         ) THEN
        EXECUTE format(
          'SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)',
          ts_schema,
          table_ident
        );
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not remove retention policy for #{table_name}: %', SQLERRM;
    END;
    $$;
    """
  end

  defp replace_policy_sql(table_name, retention_days) do
    """
    DO $$
    DECLARE
      table_ident text;
      ts_schema text;
    BEGIN
      table_ident := format('%I.%I', 'platform', '#{table_name}');

      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NOT NULL
         AND EXISTS (
           SELECT 1
           FROM timescaledb_information.hypertables
           WHERE hypertable_schema = 'platform'
             AND hypertable_name = '#{table_name}'
         ) THEN
        EXECUTE format(
          'SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)',
          ts_schema,
          table_ident
        );

        EXECUTE format(
          'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''#{retention_days} days'', if_not_exists => true)',
          ts_schema,
          table_ident
        );
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not reconcile retention policy for #{table_name}: %', SQLERRM;
    END;
    $$;
    """
  end

  defp run_policy_sql(repo, table_name, sql) do
    case SQL.query(repo, sql, [], timeout: @query_timeout_ms) do
      {:ok, _result} ->
        :ok

      {:error, error} ->
        Logger.warning("Cold-tier retention fence: policy DDL failed",
          table: table_name,
          reason: Exception.message(error)
        )

        :ok
    end
  end
end
