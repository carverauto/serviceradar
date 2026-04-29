defmodule ServiceRadar.Observability.DataRetentionWorker do
  @moduledoc """
  Recurring cleanup for high-volume observability tables that are not Timescale hypertables.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 3_600, states: [:available, :scheduled, :executing, :retryable]]

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Repo

  require Logger

  @default_batch_size 50_000
  @default_trace_summary_retention_days 3
  @default_sweep_host_result_retention_days 7
  @default_sweep_execution_retention_days 30
  @default_trivy_retention_days 30
  @default_dataset_snapshot_retention_days 14
  @default_topology_link_retention_days 30
  @query_timeout_ms 120_000

  @impl Oban.Worker
  def perform(_job) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    batch_size = Keyword.get(config, :batch_size, @default_batch_size)

    results = [
      prune_trace_summaries(config, batch_size),
      prune_sweep_host_results(config, batch_size),
      prune_sweep_group_executions(config, batch_size),
      prune_trivy_reports(config, batch_size),
      prune_inactive_dataset_snapshots(
        "netflow_provider_dataset_snapshots",
        config,
        batch_size
      ),
      prune_inactive_dataset_snapshots("netflow_oui_dataset_snapshots", config, batch_size),
      prune_mapper_topology_links(config, batch_size)
    ]

    deleted = Enum.sum(results)
    Logger.info("Observability data retention completed", deleted_rows: deleted)

    :ok
  end

  defp prune_trace_summaries(config, batch_size) do
    retention_days =
      Keyword.get(config, :trace_summary_retention_days, @default_trace_summary_retention_days)

    prune_by_timestamp(
      "otel_trace_summaries",
      "trace_id",
      "timestamp",
      retention_days,
      batch_size
    )
  end

  defp prune_sweep_host_results(config, batch_size) do
    retention_days =
      Keyword.get(
        config,
        :sweep_host_result_retention_days,
        @default_sweep_host_result_retention_days
      )

    prune_by_timestamp(
      "sweep_host_results",
      "id",
      "inserted_at",
      retention_days,
      batch_size
    )
  end

  defp prune_sweep_group_executions(config, batch_size) do
    retention_days =
      Keyword.get(
        config,
        :sweep_execution_retention_days,
        @default_sweep_execution_retention_days
      )

    prune_by_timestamp(
      "sweep_group_executions",
      "id",
      "started_at",
      retention_days,
      batch_size,
      "AND status IN ('completed', 'failed')"
    )
  end

  defp prune_trivy_reports(config, batch_size) do
    retention_days = Keyword.get(config, :trivy_retention_days, @default_trivy_retention_days)

    prune_by_timestamp(
      "trivy_reports",
      "event_uuid",
      "observed_at",
      retention_days,
      batch_size
    )
  end

  defp prune_inactive_dataset_snapshots(table_name, config, batch_size) do
    retention_days =
      Keyword.get(
        config,
        :dataset_snapshot_retention_days,
        @default_dataset_snapshot_retention_days
      )

    prune_by_timestamp(
      table_name,
      "id",
      "fetched_at",
      retention_days,
      batch_size,
      "AND is_active = FALSE"
    )
  end

  defp prune_mapper_topology_links(config, batch_size) do
    retention_days =
      Keyword.get(
        config,
        :topology_link_retention_days,
        @default_topology_link_retention_days
      )

    prune_by_timestamp(
      "mapper_topology_links",
      "id",
      "timestamp",
      retention_days,
      batch_size
    )
  end

  defp prune_by_timestamp(
         table_name,
         key_column,
         timestamp_column,
         retention_days,
         batch_size,
         extra_where \\ ""
       ) do
    sql = """
    WITH doomed AS (
      SELECT #{key_column}
      FROM platform.#{table_name}
      WHERE #{timestamp_column} < NOW() - ($1::int * INTERVAL '1 day')
      #{extra_where}
      ORDER BY #{timestamp_column} ASC
      LIMIT $2
    )
    DELETE FROM platform.#{table_name} AS target
    USING doomed
    WHERE target.#{key_column} = doomed.#{key_column}
    """

    case SQL.query(Repo, sql, [retention_days, batch_size], timeout: @query_timeout_ms) do
      {:ok, %{num_rows: deleted}} ->
        if deleted > 0 do
          Logger.info("Pruned retained observability data",
            table: table_name,
            deleted_rows: deleted,
            retention_days: retention_days
          )
        end

        deleted

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        0

      {:error, error} ->
        Logger.warning("Failed to prune retained observability data",
          table: table_name,
          reason: Exception.message(error)
        )

        0
    end
  end
end
