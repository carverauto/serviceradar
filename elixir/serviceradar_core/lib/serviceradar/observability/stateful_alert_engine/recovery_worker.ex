defmodule ServiceRadar.Observability.StatefulAlertEngine.RecoveryWorker do
  @moduledoc """
  Reconciles inbox heads with disposable evaluation wake-ups.

  The periodic scan recovers node death, timed-out jobs, discarded wake-ups and
  queue restarts. It never relies on a single self-rescheduling job remaining
  alive. Accepted work and receipt retention are independent of Oban pruning.

  The scan is driven by an every-minute cron entry, so a run that finds the
  consumers disabled simply completes: the next tick checks again. It must not
  snooze. A snoozed job never completes and does not consume an attempt, so a
  cron that inserts one per minute grew an unbounded backlog of permanently
  pending priority-0 jobs while the deployment sat in `:prepared` mode. That
  backlog held every slot of the queue it ran on and starved the priority-3
  AshOban schedulers sharing it, which silently stopped device identity
  reconciliation. The uniqueness below keeps at most one pending scan even when
  no node consumes the queue.
  """

  use Oban.Worker,
    queue: :alert_recovery,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable]]

  alias ServiceRadar.Observability.AlertEvaluationReceipt
  alias ServiceRadar.Observability.StatefulAlertEngine.EvaluationWorker
  alias ServiceRadar.Observability.StatefulAlertEngine.Rollout
  alias ServiceRadar.Observability.StatefulAlertEngine.RuntimeMetrics
  alias ServiceRadar.Repo

  require Logger

  @batch_size 100
  @ready_query_timeout_ms 2_000
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
    maybe_set_process_label({__MODULE__, :perform})
    if Rollout.consumers_enabled?(), do: recover(), else: :ok
  end

  defp recover do
    case query_ready_rules() do
      {:ok, %{rows: rows}} ->
        result =
          Enum.reduce_while(rows, :ok, fn [raw_id], :ok ->
            case EvaluationWorker.enqueue(Ecto.UUID.load!(raw_id)) do
              {:ok, _job} -> {:cont, :ok}
              {:error, _reason} = error -> {:halt, error}
            end
          end)

        # Retention and observability must not stop the recovery wake-ups.
        _ = RuntimeMetrics.sample_health()
        _ = AlertEvaluationReceipt.prune()

        result

      {:error, _reason} = error ->
        error
    end
  end

  defp query_ready_rules do
    caller = {__MODULE__, :recover_ready_rules}
    maybe_set_process_label(caller)

    try do
      case Repo.query(
             @ready_sql,
             [@batch_size, Oban.Worker.to_string(EvaluationWorker)],
             timeout: @ready_query_timeout_ms,
             telemetry_options: [caller: caller, timeout_ms: @ready_query_timeout_ms]
           ) do
        {:ok, _} = ok ->
          ok

        {:error, reason} = error ->
          recovery_failed(caller, reason)
          error
      end
    rescue
      error ->
        recovery_failed(caller, error)
        {:error, error}
    catch
      :exit, reason ->
        recovery_failed(caller, {:exit, reason})
        {:error, {:exit, reason}}
    end
  end

  defp recovery_failed(caller, reason) do
    RuntimeMetrics.store_failure()
    RuntimeMetrics.retry()

    :telemetry.execute(
      [:serviceradar, :stateful_alert_engine, :recovery_failed],
      %{count: 1},
      %{caller: caller, reason: reason}
    )

    Logger.warning(
      "Alert evaluation recovery scan failed (#{inspect(caller)}): " <>
        inspect(reason, limit: 10, printable_limit: 500),
      caller: inspect(caller)
    )
  end

  defp maybe_set_process_label(caller) do
    case Process.info(self(), :registered_name) do
      {:registered_name, []} -> Process.set_label(caller)
      _ -> :ok
    end
  end
end
