defmodule ServiceRadar.AnalyticsStore.Compactor do
  @moduledoc """
  Compact a bounded snapshot of immutable files before atomically replacing it.

  Canonical rows are materialized once on a fresh analytics-head connection,
  then sorted for device queries and written to one unique candidate. Count,
  time bounds and two order-independent row-hash aggregates must survive the
  rewrite. These checks preserve duplicate rows; compaction never deduplicates.

  No primary transaction remains open during object IO. Failed candidates stay
  invisible, and source objects remain available to readers that captured their
  keys before publication. Physical object cleanup is a separate operation.

  An operator-supplied `:session` callback can accept `(config, context, fun)`.
  The context contains `:source_urls` and `:target_url`, allowing the session to
  restrict object access before invoking `fun`. The default and existing
  two-argument callbacks continue to accept `(config, fun)`.
  """

  alias ServiceRadar.AnalyticsStore.Bindings
  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.AnalyticsStore.FileManifest
  alias ServiceRadar.AnalyticsStore.Head
  alias ServiceRadar.AnalyticsStore.Layout
  alias ServiceRadar.AnalyticsStore.ManifestCompaction
  alias ServiceRadar.AnalyticsStore.Storage
  alias ServiceRadar.ColdTier.Registry

  @table "timeseries_metrics"
  @temp_table "analytics_compaction"
  @statement_timeout 120_000

  @doc "Compact at most one source group; only the selected hybrid metric table is enabled."
  def run(table, opts \\ [])

  def run(@table = table, opts) do
    cfg = Keyword.get_lazy(opts, :config, &Config.load/0)

    if Config.driver_for(cfg, table) == :hybrid do
      candidates = Keyword.get(opts, :candidates, &FileManifest.compaction_candidates/2)

      case candidates.(table, opts) do
        {:ok, []} -> {:ok, :no_candidates}
        {:ok, sources} -> compact(cfg, sources, opts)
        {:error, _} = error -> error
      end
    else
      {:ok, :disabled}
    end
  end

  def run(_table, _opts), do: {:error, :unsupported_compaction_table}

  @doc "Rewrite one unsorted legacy metric file without changing the scheduled compaction budget."
  def rewrite_file(table, manifest_id, opts \\ [])

  def rewrite_file(@table, manifest_id, _opts)
      when not is_integer(manifest_id) or manifest_id <= 0,
      do: {:error, :invalid_rewrite_manifest_id}

  def rewrite_file(@table = table, manifest_id, opts) do
    cfg = Keyword.get_lazy(opts, :config, &Config.load/0)
    source = Keyword.get(opts, :source, &FileManifest.rewrite_source/3)
    replace = Keyword.get(opts, :replace_rewrite, &FileManifest.replace_rewrite/3)

    if Config.driver_for(cfg, table) == :hybrid do
      with {:ok, source} <- source.(table, manifest_id, opts),
           :ok <- ManifestCompaction.validate_rewrite_source(source, opts),
           attrs = candidate_attrs([source], "rewrite"),
           :ok <- ManifestCompaction.validate_rewrite(source, attrs, opts) do
        rewrite_candidate(cfg, [source], attrs, opts, fn [source], attrs, opts ->
          replace.(source, attrs, opts)
        end)
      end
    else
      {:error, :rewrite_requires_hybrid}
    end
  end

  def rewrite_file(_table, _manifest_id, _opts), do: {:error, :unsupported_compaction_table}

  defp compact(cfg, sources, opts) do
    attrs = candidate_attrs(sources, "compact")
    replace = Keyword.get(opts, :replace_sources, &FileManifest.replace_sources/3)

    with :ok <- ManifestCompaction.validate_replacement(sources, attrs) do
      rewrite_candidate(cfg, sources, attrs, opts, replace)
    end
  end

  defp rewrite_candidate(cfg, sources, attrs, opts, replace) do
    session = Keyword.get(opts, :session, &Head.session/2)

    with :ok <- validate_source_keys(sources),
         {:ok, urls} <- source_urls(cfg, sources),
         {:ok, target} <- Storage.copy_target(cfg, attrs.object_key),
         {:ok, {:ok, verification}} <-
           open_session(session, cfg, %{source_urls: urls, target_url: target}, fn conn ->
             rewrite(conn, urls, target, attrs, opts)
           end),
         attrs = %{attrs | content_checksum: verification_digest(verification)},
         :ok <- replace.(sources, attrs, opts) do
      {:ok, %{source_files: length(sources), row_count: attrs.row_count}}
    else
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, _} = error -> error
    end
  end

  defp open_session(session, cfg, context, fun) when is_function(session, 3),
    do: session.(cfg, context, fun)

  defp open_session(session, cfg, _context, fun) when is_function(session, 2),
    do: session.(cfg, fun)

  defp candidate_attrs([first | _] = sources, purpose) do
    keys = Layout.candidate_keys(@table, first.partition_date, purpose, Ecto.UUID.generate())

    %{
      table_name: @table,
      object_key: keys.published_key,
      staging_key: keys.published_key,
      batch_id: keys.batch_id,
      partition_date: first.partition_date,
      row_count: Enum.sum(Enum.map(sources, & &1.row_count)),
      min_timestamp:
        Enum.min_by(sources, &DateTime.to_unix(&1.min_timestamp, :microsecond)).min_timestamp,
      max_timestamp:
        Enum.max_by(sources, &DateTime.to_unix(&1.max_timestamp, :microsecond)).max_timestamp,
      content_checksum: "unverified",
      archive_batch_id: nil
    }
  end

  defp validate_source_keys(sources) do
    if Enum.all?(sources, &valid_source_key?/1) do
      :ok
    else
      {:error, :invalid_compaction_source_key}
    end
  end

  defp valid_source_key?(source) do
    prefixes = [
      "analytics/v1/#{@table}/date=#{source.partition_date}/",
      "analytics/v1/#{@table}/_candidates/date=#{source.partition_date}/"
    ]

    DateTime.to_date(source.min_timestamp) == source.partition_date and
      DateTime.to_date(source.max_timestamp) == source.partition_date and
      Enum.any?(prefixes, fn prefix ->
        String.starts_with?(source.object_key, prefix) and
          Regex.match?(
            ~r/\A[A-Za-z0-9_-]+\.parquet\z/,
            String.replace_prefix(source.object_key, prefix, "")
          )
      end)
  end

  defp source_urls(cfg, sources) do
    Enum.reduce_while(sources, {:ok, []}, fn source, {:ok, urls} ->
      case Storage.copy_target(cfg, source.object_key) do
        {:ok, url} -> {:cont, {:ok, [url | urls]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp rewrite(conn, urls, target, attrs, opts) do
    query = Keyword.get(opts, :query, &query!/3)
    query.(conn, "SET application_name = 'sr_analytics_compactor'", [])
    query.(conn, "SET statement_timeout = '#{@statement_timeout}'", [])

    with :ok <- head_ready(conn, query) do
      entry = Registry.fetch!(@table)
      source = canonical_select(entry, parquet_source(urls))
      raw_query(conn, "CREATE TEMP TABLE #{@temp_table} AS #{source}", query)
      source_check = verify(conn, entry, @temp_table, query)

      with :ok <- verify_envelope(source_check, attrs) do
        copy_sql = """
        COPY (SELECT * FROM #{@temp_table} ORDER BY device_id, metric_name, timestamp)
        TO #{literal(target)} (FORMAT parquet, COMPRESSION zstd)
        """

        raw_query(conn, copy_sql, query)

        target_check =
          verify(conn, entry, "(#{canonical_select(entry, parquet_source([target]))})", query)

        if target_check == source_check,
          do: {:ok, target_check},
          else: {:error, :compaction_verification_mismatch}
      end
    end
  end

  defp head_ready(conn, query) do
    %Postgrex.Result{rows: [[active]]} =
      query.(
        conn,
        """
        SELECT count(*) FROM pg_stat_activity
        WHERE datname = current_database() AND backend_type = 'client backend'
          AND state = 'active' AND pid <> pg_backend_pid()
        """,
        []
      )

    if active <= 1, do: :ok, else: {:error, :analytics_head_busy}
  end

  defp canonical_select(entry, source) do
    columns =
      Enum.map_join(entry.columns, ", ", fn {name, type, cast} ->
        type = if cast == :text, do: "VARCHAR", else: type
        "CAST(#{quoted(name)} AS #{type}) AS #{quoted(name)}"
      end)

    "SELECT #{columns} FROM #{source}"
  end

  defp parquet_source(urls),
    do: "read_parquet([#{Enum.map_join(urls, ",", &literal/1)}], hive_partitioning = false)"

  defp verify(conn, entry, source, query) do
    columns = Enum.map_join(entry.columns, ",", &quoted(elem(&1, 0)))

    sql = """
    SELECT count(*) AS row_count,
           epoch_us(min(timestamp))::VARCHAR AS min_epoch,
           epoch_us(max(timestamp))::VARCHAR AS max_epoch,
           bit_xor(hash(#{columns}))::VARCHAR AS hash_xor,
           sum(hash(#{columns})::HUGEINT)::VARCHAR AS hash_sum
      FROM #{source}
    """

    native = "SELECT to_json(r)::VARCHAR AS payload FROM (#{sql}) r"

    {:ok, sql} =
      Bindings.bind("SELECT CAST(t['payload'] AS text) FROM duckdb.query($1) AS t", [native],
        types: ["text"]
      )

    %Postgrex.Result{rows: [[json]]} = query.(conn, sql, [])
    Jason.decode!(json)
  end

  defp verify_envelope(check, attrs) do
    expected = %{
      "row_count" => attrs.row_count,
      "min_epoch" => Integer.to_string(DateTime.to_unix(attrs.min_timestamp, :microsecond)),
      "max_epoch" => Integer.to_string(DateTime.to_unix(attrs.max_timestamp, :microsecond))
    }

    if Map.take(check, Map.keys(expected)) == expected and
         is_binary(check["hash_xor"]) and is_binary(check["hash_sum"]),
       do: :ok,
       else: {:error, :compaction_source_mismatch}
  end

  defp verification_digest(check) do
    tuple = Enum.map(~w(row_count min_epoch max_epoch hash_xor hash_sum), &Map.fetch!(check, &1))
    digest = :sha256 |> :crypto.hash(Jason.encode!(tuple)) |> Base.encode16(case: :lower)
    "row-hash-v1:" <> digest
  end

  defp raw_query(conn, native, query) do
    {:ok, sql} = Bindings.bind("SELECT duckdb.raw_query($1)", [native], types: ["text"])
    query.(conn, sql, [])
  end

  defp quoted(name), do: ~s("#{name}")
  defp literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"

  defp query!(conn, sql, params),
    do: Postgrex.query!(conn, sql, params, timeout: @statement_timeout + 5_000)
end
