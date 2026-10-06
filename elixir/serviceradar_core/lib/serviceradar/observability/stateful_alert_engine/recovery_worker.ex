defmodule ServiceRadar.Observability.StatefulAlertEngine.RecoveryWorker do
  @moduledoc """
  Reconciles inbox heads with disposable evaluation wake-ups.

  The periodic scan recovers node death, timed-out jobs, discarded wake-ups and
  queue restarts. It never relies on a single self-rescheduling job remaining
  alive. Accepted work and receipt retention are independent of Oban pruning.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias ServiceRadar.Observability.AlertEvaluationReceipt
  alias ServiceRadar.Observability.StatefulAlertEngine.EvaluationWorker
  alias ServiceRadar.Observability.StatefulAlertEngine.Rollout
  alias ServiceRadar.Observability.StatefulAlertEngine.RuntimeMetrics
  alias ServiceRadar.Repo

  require Logger

  @batch_size 100
  @ready_sql """
  SELECT rule_id FROM (
    SELECT DISTINCT ON (rule_id) rule_id, available_at, accepted_at
    FROM platform.alert_evaluation_work
    ORDER BY rule_id, position
  ) heads
  WHERE available_at <= timezone('utc', now())
    AND NOT EXISTS (
      SELECT 1 FROM platform.oban_jobs job
      WHERE job.worker = $2 AND job.args->>'rule_id' = heads.rule_id::text
        AND job.state IN ('available', 'scheduled', 'retryable')
    )
  ORDER BY accepted_at, rule_id
  LIMIT $1
  """

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if Rollout.consumers_enabled?(), do: recover(), else: {:snooze, 5}
  end

  defp recover do
    with {:ok, %{rows: rows}} <-
           Repo.query(@ready_sql, [@batch_size, Oban.Worker.to_string(EvaluationWorker)]) do
      result =
        Enum.reduce_while(rows, :ok, fn [raw_id], :ok ->
          case EvaluationWorker.enqueue(Ecto.UUID.load!(raw_id)) do
            {:ok, _job} -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end
        end)

      # Retention and observability must not stop the recovery wake-ups.
      case RuntimeMetrics.sample_health() do
        :ok -> :ok
        {:error, _} -> Logger.warning("Could not sample alert evaluation health")
      end

      case AlertEvaluationReceipt.prune() do
        {:ok, :ok} -> :ok
        {:error, _} -> Logger.warning("Could not prune expired alert evaluation receipts")
      end

      result
    end
  end
end
