defmodule ServiceRadar.Inventory.EndpointInventoryTelemetry do
  @moduledoc """
  Cost and volume telemetry for endpoint software inventory.
  """

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Repo

  @prefix [:serviceradar, :endpoint_inventory]
  @ingest_event @prefix ++ [:ingest, :scan]
  @storage_event @prefix ++ [:storage]
  @table_event @prefix ++ [:table]

  @inventory_tables [
    "endpoint_inventory_scans",
    "endpoint_inventory_artifacts",
    "endpoint_inventory_artifact_contents",
    "endpoint_inventory_packages",
    "endpoint_inventory_scan_history",
    "endpoint_inventory_package_events",
    "endpoint_inventory_current_package_counts",
    "endpoint_inventory_current_cpe_counts",
    "endpoint_inventory_package_count_history",
    "endpoint_inventory_cpe_count_history"
  ]

  @history_tables [
    "endpoint_inventory_scan_history",
    "endpoint_inventory_package_events",
    "endpoint_inventory_package_count_history",
    "endpoint_inventory_cpe_count_history"
  ]

  @spec ingest_event() :: [atom()]
  def ingest_event, do: @ingest_event

  @spec storage_event() :: [atom()]
  def storage_event, do: @storage_event

  @spec table_event() :: [atom()]
  def table_event, do: @table_event

  @spec emit_ingest_result(map()) :: :ok
  def emit_ingest_result(result) when is_map(result) do
    upload_reason = normalize_upload_reason(Map.get(result, :upload_reason))

    measurements = %{
      count: 1,
      changed_upload_count: if(upload_reason == "unchanged", do: 0, else: 1),
      unchanged_upload_count: if(upload_reason == "unchanged", do: 1, else: 0),
      package_count: non_negative_integer(Map.get(result, :package_count)),
      package_event_count: non_negative_integer(Map.get(result, :package_event_count)),
      package_rows_replaced_count: boolean_count(Map.get(result, :package_rows_replaced?)),
      artifact_uploaded_count: boolean_count(Map.get(result, :artifact_uploaded?)),
      package_set_hash_mismatch_count:
        boolean_count(Map.get(result, :package_set_hash_mismatch?)),
      reconcile_floor_count: boolean_count(Map.get(result, :reconcile_floor?)),
      package_change_signal_publish_count:
        non_negative_integer(Map.get(result, :package_change_signal_publish_count))
    }

    metadata =
      drop_nil_values(%{
        agent_id: Map.get(result, :agent_id),
        device_uid: Map.get(result, :device_uid),
        upload_reason: upload_reason,
        current?: Map.get(result, :current?, false)
      })

    :telemetry.execute(@ingest_event, measurements, metadata)
  end

  def emit_ingest_result(_result), do: :ok

  @spec measure_cost_volume(keyword()) :: :ok
  def measure_cost_volume(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    if repo_available?(repo) do
      emit_storage_measurements(repo)
      emit_table_health_measurements(repo)
    end

    :ok
  end

  defp emit_storage_measurements(repo) do
    case query(repo, storage_sql(), []) do
      {:ok, %{rows: [row]}} ->
        measurements =
          [
            :current_scan_count,
            :current_package_row_count,
            :current_package_count_rows,
            :current_cpe_count_rows,
            :artifact_content_count,
            :artifact_object_bytes,
            :artifact_reference_count,
            :recent_changed_scan_count,
            :recent_unchanged_scan_count,
            :recent_changed_ratio,
            :recent_unchanged_ratio
          ]
          |> Enum.zip(row)
          |> Map.new(fn {key, value} -> {key, numeric_value(value)} end)

        :telemetry.execute(@storage_event, measurements, %{})

      _ ->
        :ok
    end
  end

  defp emit_table_health_measurements(repo) do
    compression_lag = compression_lag_by_table(repo)

    case query(repo, table_health_sql(), [@inventory_tables]) do
      {:ok, %{rows: rows}} ->
        Enum.each(rows, fn [
                             table,
                             live_rows,
                             dead_rows,
                             autovacuum_lag_seconds,
                             analyze_lag_seconds
                           ] ->
          compression = Map.get(compression_lag, table, %{})

          :telemetry.execute(
            @table_event,
            %{
              live_rows: numeric_value(live_rows),
              dead_rows: numeric_value(dead_rows),
              autovacuum_lag_seconds: numeric_value(autovacuum_lag_seconds),
              analyze_lag_seconds: numeric_value(analyze_lag_seconds),
              uncompressed_chunk_count:
                numeric_value(Map.get(compression, :uncompressed_chunk_count, 0)),
              compression_lag_seconds:
                numeric_value(Map.get(compression, :compression_lag_seconds, 0))
            },
            %{
              table: table,
              table_kind: table_kind(table)
            }
          )
        end)

      _ ->
        :ok
    end
  end

  defp compression_lag_by_table(repo) do
    case query(repo, compression_lag_sql(), [@history_tables]) do
      {:ok, %{rows: rows}} ->
        Map.new(rows, fn [table, uncompressed_chunk_count, compression_lag_seconds] ->
          {table,
           %{
             uncompressed_chunk_count: numeric_value(uncompressed_chunk_count),
             compression_lag_seconds: numeric_value(compression_lag_seconds)
           }}
        end)

      _ ->
        %{}
    end
  end

  defp storage_sql do
    """
    WITH recent AS (
      SELECT
        count(*) FILTER (WHERE upload_reason IS DISTINCT FROM 'unchanged')::bigint AS changed,
        count(*) FILTER (WHERE upload_reason = 'unchanged')::bigint AS unchanged,
        count(*)::bigint AS total
      FROM platform.endpoint_inventory_scans
      WHERE ingested_at >= now() - interval '24 hours'
    )
    SELECT
      (SELECT count(*)::bigint FROM platform.endpoint_inventory_scans WHERE current = true),
      (SELECT count(*)::bigint FROM platform.endpoint_inventory_packages WHERE current = true),
      (SELECT count(*)::bigint FROM platform.endpoint_inventory_current_package_counts),
      (SELECT count(*)::bigint FROM platform.endpoint_inventory_current_cpe_counts),
      (SELECT count(*)::bigint FROM platform.endpoint_inventory_artifact_contents),
      (SELECT coalesce(sum(size_bytes), 0)::bigint FROM platform.endpoint_inventory_artifact_contents),
      (SELECT coalesce(sum(reference_count), 0)::bigint FROM platform.endpoint_inventory_artifact_contents),
      coalesce(recent.changed, 0)::bigint,
      coalesce(recent.unchanged, 0)::bigint,
      CASE WHEN recent.total > 0 THEN recent.changed::float / recent.total::float ELSE 0.0 END,
      CASE WHEN recent.total > 0 THEN recent.unchanged::float / recent.total::float ELSE 0.0 END
    FROM recent
    """
  end

  defp table_health_sql do
    """
    SELECT
      relname,
      n_live_tup::bigint,
      n_dead_tup::bigint,
      coalesce(extract(epoch FROM now() - coalesce(last_autovacuum, last_vacuum)), 0)::bigint,
      coalesce(extract(epoch FROM now() - coalesce(last_autoanalyze, last_analyze)), 0)::bigint
    FROM pg_stat_user_tables
    WHERE schemaname = 'platform'
      AND relname = ANY($1::text[])
    """
  end

  defp compression_lag_sql do
    """
    SELECT
      hypertable_name,
      count(*) FILTER (WHERE is_compressed = false)::bigint,
      coalesce(
        max(extract(epoch FROM now() - range_end)) FILTER (WHERE is_compressed = false),
        0
      )::bigint
    FROM timescaledb_information.chunks
    WHERE hypertable_schema = 'platform'
      AND hypertable_name = ANY($1::text[])
    GROUP BY hypertable_name
    """
  end

  defp query(repo, sql, params), do: SQL.query(repo, sql, params)

  defp repo_available?(repo) when is_atom(repo), do: is_pid(Process.whereis(repo))
  defp repo_available?(_repo), do: false

  defp table_kind(table) when table in @history_tables, do: :history
  defp table_kind(_table), do: :current

  defp normalize_upload_reason(reason) when is_binary(reason) do
    reason
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> "unknown"
      value -> value
    end
  end

  defp normalize_upload_reason(_reason), do: "unknown"

  defp boolean_count(true), do: 1
  defp boolean_count(_value), do: 0

  defp non_negative_integer(value) when is_integer(value) and value > 0, do: value
  defp non_negative_integer(_value), do: 0

  defp numeric_value(%Decimal{} = value), do: Decimal.to_float(value)
  defp numeric_value(value) when is_integer(value), do: value
  defp numeric_value(value) when is_float(value), do: value
  defp numeric_value(_value), do: 0

  defp drop_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end
end
