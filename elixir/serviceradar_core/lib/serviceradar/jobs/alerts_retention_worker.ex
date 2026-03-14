defmodule ServiceRadar.Jobs.AlertsRetentionWorker do
  @moduledoc """
  Oban worker that prunes alerts older than the configured retention window.

  Alerts are currently stored in a regular table, so retention is enforced
  through batched deletes rather than a Timescale policy.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias Ecto.Adapters.SQL

  require Logger

  @default_retention_days 3
  @default_batch_size 10_000
  @default_max_batches 100

  @delete_batch_sql """
  WITH doomed AS (
    SELECT id
    FROM alerts
    WHERE triggered_at < $1
    ORDER BY triggered_at ASC
    LIMIT $2
  )
  DELETE FROM alerts AS alerts
  USING doomed
  WHERE alerts.id = doomed.id
  """

  def delete_batch_sql, do: @delete_batch_sql

  def config do
    app_config = Application.get_env(:serviceradar_core, __MODULE__, [])

    %{
      retention_days: Keyword.get(app_config, :retention_days, @default_retention_days),
      batch_size: Keyword.get(app_config, :batch_size, @default_batch_size),
      max_batches: Keyword.get(app_config, :max_batches, @default_max_batches)
    }
  end

  @impl Oban.Worker
  def perform(_job) do
    %{retention_days: retention_days, batch_size: batch_size, max_batches: max_batches} = config()

    cutoff = DateTime.add(DateTime.utc_now(), -retention_days * 86_400, :second)

    Logger.info("Starting alerts retention cleanup",
      retention_days: retention_days,
      batch_size: batch_size,
      max_batches: max_batches,
      cutoff: cutoff
    )

    case prune_batches(cutoff, batch_size, max_batches, 0, 0) do
      {:ok, deleted, batches, truncated?} ->
        Logger.info("Completed alerts retention cleanup",
          deleted_rows: deleted,
          batches: batches,
          truncated: truncated?,
          cutoff: cutoff
        )

        :ok

      {:error, error} ->
        Logger.error("Failed alerts retention cleanup", reason: Exception.message(error))
        {:error, error}
    end
  end

  defp prune_batches(_cutoff, _batch_size, max_batches, deleted, batches)
       when batches >= max_batches do
    {:ok, deleted, batches, true}
  end

  defp prune_batches(cutoff, batch_size, max_batches, deleted, batches) do
    case SQL.query(ServiceRadar.Repo, @delete_batch_sql, [cutoff, batch_size], timeout: 60_000) do
      {:ok, %{num_rows: num_rows}} ->
        total_deleted = deleted + num_rows
        total_batches = if num_rows > 0, do: batches + 1, else: batches

        if num_rows > 0 do
          Logger.info("Pruned expired alerts batch",
            deleted_rows: num_rows,
            batch: total_batches,
            cutoff: cutoff
          )
        end

        if num_rows < batch_size do
          {:ok, total_deleted, total_batches, false}
        else
          prune_batches(cutoff, batch_size, max_batches, total_deleted, total_batches)
        end

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        Logger.debug("alerts table missing; skipping retention cleanup")
        {:ok, deleted, batches, false}

      {:error, error} ->
        {:error, error}
    end
  end
end
