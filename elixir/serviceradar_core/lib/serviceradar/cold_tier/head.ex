defmodule ServiceRadar.ColdTier.Head do
  @moduledoc """
  Short-lived sessions against the analytics head.

  Every operation runs on a fresh Postgrex connection that is stopped
  afterwards — spike 0.3 showed a head session that has seen any DuckDB
  error can be poisoned (including silently losing its S3 secret and falling
  back to public endpoints), so sessions are never reused across failures.

  Also owns idempotent head setup (task 1.7 reconciler v1): the postgres_fdw
  SERVER + USER MAPPING to the primary, per-registry-table foreign tables,
  and the DuckDB S3 secret. The reconciler is an owner, not an asserter
  (spike 0.5): duplicate/stale same-scope secrets are dropped before
  re-creating (`duckdb.create_simple_secret` accumulates `_1/_2/…`
  duplicates with ambiguous resolution and has no delete function).
  """

  alias ServiceRadar.ColdTier.Config
  alias ServiceRadar.ColdTier.Registry
  alias ServiceRadar.ColdTier.Verification

  require Logger

  @fdw_schema "fdw_primary"
  @fdw_server "cold_primary"
  # pg_duckdb auto-names simple secrets simple_s3_secret(_N); there is no name
  # parameter and no delete function — cleanup is DROP SERVER on the dummy
  # foreign servers that back them (spike 0.5).
  @s3_secret_prefix "simple_s3_secret"

  @doc """
  Run `fun` with a fresh head connection; the connection is always stopped.
  Returns `{:ok, result}` / `{:error, reason}`.
  """
  @spec session((pid() -> any())) :: {:ok, any()} | {:error, any()}
  def session(fun) when is_function(fun, 1) do
    with {:ok, opts} <- head_opts_or_error(),
         {:ok, conn} <- Postgrex.start_link(opts) do
      try do
        {:ok, fun.(conn)}
      rescue
        e -> {:error, e}
      after
        GenServer.stop(conn, :normal, 5_000)
      end
    end
  end

  @doc "Plain query helper for use inside `session/1` callbacks."
  @spec query!(pid(), String.t(), list()) :: Postgrex.Result.t()
  def query!(conn, sql, params \\ []), do: Postgrex.query!(conn, sql, params, timeout: :infinity)

  @doc """
  Idempotently (re)assert head-side objects: FDW server/user mapping to the
  primary, foreign tables for every registry table, the boundaries ack
  table, and exactly one bucket-scoped DuckDB S3 secret.
  """
  @spec ensure_setup(pid()) :: :ok
  def ensure_setup(conn) do
    {:ok, fdw} = Config.primary_fdw()
    {:ok, s3} = Config.s3()

    query!(conn, "CREATE EXTENSION IF NOT EXISTS postgres_fdw")
    query!(conn, "CREATE SCHEMA IF NOT EXISTS #{@fdw_schema}")

    # The reconciler OWNS the server and its mapping — it does not merely
    # create them when absent. Credentials and connection facts rotate
    # (verified: an existence-only check leaves a stale password in the
    # mapping and every FDW read fails authentication until someone fixes it
    # by hand), so both are re-asserted from current config on every run.
    query!(conn, """
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_foreign_server WHERE srvname = '#{@fdw_server}') THEN
        CREATE SERVER #{@fdw_server}
          FOREIGN DATA WRAPPER postgres_fdw
          OPTIONS (host '#{sql_escape(fdw.host)}', port '#{fdw.port}', dbname '#{sql_escape(fdw.dbname)}',
                   fetch_size '1000', connect_timeout '5', tcp_user_timeout '60000',
                   keepalives_idle '30', keepalives_interval '10', keepalives_count '3');
      ELSE
        -- Re-assert connection facts (host/port/dbname can move; the tuning
        -- options are the spike-0.2 contract and must not drift).
        ALTER SERVER #{@fdw_server} OPTIONS (SET host '#{sql_escape(fdw.host)}');
        ALTER SERVER #{@fdw_server} OPTIONS (SET port '#{fdw.port}');
        ALTER SERVER #{@fdw_server} OPTIONS (SET dbname '#{sql_escape(fdw.dbname)}');
      END IF;
    END $$;
    """)

    query!(conn, """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_user_mappings WHERE srvname = '#{@fdw_server}' AND usename = current_user
      ) THEN
        -- Rotation-safe: drop and recreate so the mapping always carries the
        -- CURRENT credentials. postgres_fdw caches connections per session,
        -- but head sessions are short-lived and discarded after any error,
        -- so the next session picks the new password up.
        DROP USER MAPPING FOR CURRENT_USER SERVER #{@fdw_server};
      END IF;

      CREATE USER MAPPING FOR CURRENT_USER SERVER #{@fdw_server}
        OPTIONS (user '#{sql_escape(fdw.username)}', password '#{sql_escape(fdw.password)}');
    END $$;
    """)

    for entry <- Registry.tables() do
      query!(conn, """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM information_schema.foreign_tables
          WHERE foreign_table_schema = '#{@fdw_schema}'
            AND foreign_table_name = '#{entry.table}'
        ) THEN
          IMPORT FOREIGN SCHEMA platform LIMIT TO (#{entry.table})
            FROM SERVER #{@fdw_server} INTO #{@fdw_schema};
        END IF;
      END $$;
      """)
    end

    # Boundary ack table (the value the stitched views read; invariant
    # drop point <= B is enforced by writing/acking here BEFORE any chunk
    # at or below B becomes drop-eligible on the primary).
    query!(conn, """
    CREATE TABLE IF NOT EXISTS platform.cold_tier_boundaries (
      table_name text PRIMARY KEY,
      query_boundary timestamptz NOT NULL,
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    ensure_s3_secret(conn, s3)
    :ok
  end

  @doc """
  Write + ack the query boundary B for a table on the head, rebuild that
  table's stitched view at the effective split point, and return the
  effective boundary so the caller records the SAME value on the primary.

  B is monotonic on both sides. A late or recreated old chunk can produce a
  candidate BELOW the stored boundary; if the head moved backward while the
  primary's boundary stayed high, the stitched view would expect hot rows in
  a range the primary had already dropped while excluding the Parquet copy —
  a silent query gap. So the head clamps with `GREATEST`, and the value it
  actually stored (not the candidate) is what builds the view and what the
  caller acknowledges (design D3, invariant "drop point <= B <= F").

  The view is regenerated in the SAME step as the ack, so the boundary the
  views read can never disagree with the one the drop gate keys on.
  """
  @spec ack_boundary(pid(), String.t(), DateTime.t()) :: {:ok, DateTime.t()}
  def ack_boundary(conn, table_name, %DateTime{} = boundary) do
    %Postgrex.Result{rows: [[effective]]} =
      query!(
        conn,
        """
        INSERT INTO platform.cold_tier_boundaries (table_name, query_boundary, updated_at)
        VALUES ($1, $2, now())
        ON CONFLICT (table_name)
        DO UPDATE SET
          query_boundary =
            GREATEST(platform.cold_tier_boundaries.query_boundary, EXCLUDED.query_boundary),
          updated_at = now()
        RETURNING query_boundary
        """,
        [table_name, boundary]
      )

    case Registry.fetch(table_name) do
      {:ok, entry} -> ServiceRadar.ColdTier.Views.ensure_view(conn, entry, effective)
      :error -> :ok
    end

    {:ok, effective}
  end

  @doc """
  Export one absolute time range of a registry table to a parquet object.
  MUST run on a session that is discarded afterwards; never cancel it
  (spike 0.3). Returns the object key.
  """
  @spec export_range(pid(), Registry.Table.t(), DateTime.t(), DateTime.t(), String.t()) ::
          String.t()
  def export_range(conn, entry, %DateTime{} = lo, %DateTime{} = hi, object_key) do
    {:ok, s3} = Config.s3()
    select_list = Registry.export_select_list(entry)
    time_col = ~s("#{entry.time_column}")

    query!(conn, """
    COPY (
      SELECT #{select_list}
      FROM #{@fdw_schema}."#{entry.table}"
      WHERE #{time_col} >= '#{DateTime.to_iso8601(lo)}'::timestamptz
        AND #{time_col} < '#{DateTime.to_iso8601(hi)}'::timestamptz
    ) TO '#{s3.bucket_url}/#{object_key}' (FORMAT parquet, COMPRESSION zstd)
    """)

    object_key
  end

  @doc """
  Verification aggregate over an exported object via read_parquet — the
  engine-stable pair from spike 0.2, built by `ServiceRadar.ColdTier.Verification`
  so it can never drift from the primary side.
  """
  @spec parquet_verification(pid(), Registry.Table.t(), String.t()) ::
          Verification.result()
  def parquet_verification(conn, entry, object_key) do
    {:ok, s3} = Config.s3()

    %Postgrex.Result{rows: [row]} =
      query!(conn, Verification.parquet_sql(entry, "#{s3.bucket_url}/#{object_key}"))

    Verification.to_result(row)
  end

  # --- internals ---

  defp ensure_s3_secret(conn, s3) do
    # Drop every stale/duplicate cold S3 secret (stored as dummy foreign
    # servers), then create exactly one, bucket-scoped.
    %Postgrex.Result{rows: rows} =
      query!(conn, """
      SELECT srvname FROM pg_foreign_server WHERE srvname LIKE '#{@s3_secret_prefix}%'
      """)

    for [srvname] <- rows do
      query!(conn, ~s(DROP SERVER IF EXISTS "#{srvname}" CASCADE))
    end

    query!(conn, """
    SELECT duckdb.create_simple_secret(
      type := 'S3',
      key_id := '#{sql_escape(s3.access_key_id || "")}',
      secret := '#{sql_escape(s3.secret_access_key || "")}',
      region := '#{sql_escape(s3.region)}',
      endpoint := '#{sql_escape(s3.endpoint || "")}',
      url_style := '#{sql_escape(s3.url_style)}',
      use_ssl := '#{s3.use_ssl}',
      scope := '#{sql_escape(s3.bucket_url)}'
    )
    """)

    :ok
  rescue
    e ->
      # create_simple_secret signatures vary by pg_duckdb version; surface
      # loudly — without the secret every export/read fails fast anyway.
      Logger.error("Cold tier: failed to (re)assert S3 secret on head",
        reason: Exception.message(e)
      )

      reraise e, __STACKTRACE__
  end

  defp head_opts_or_error do
    case Config.head_opts() do
      {:ok, opts} -> {:ok, opts}
      :disabled -> {:error, :cold_tier_disabled}
    end
  end

  defp sql_escape(s), do: String.replace(s, "'", "''")
end
