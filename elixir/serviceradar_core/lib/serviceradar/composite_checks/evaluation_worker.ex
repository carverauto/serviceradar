defmodule ServiceRadar.CompositeChecks.EvaluationWorker do
  @moduledoc """
  Evaluates one composite check on its configured interval, then reschedules
  itself.

  The periodic pass is required even though inputs also drive an event-driven
  refresh, and it is not a fallback. Two transitions produce no event at all:

    * an input aging past its `max_age` — nothing happens, the clock just moves
    * a device entering or leaving the scope as inventory syncs — the device did
      not change from this check's perspective

  Both are only discoverable by re-evaluating. Do not delete this worker in
  favour of the event path.
  """

  use Oban.Worker,
    queue: :monitoring,
    max_attempts: 3,
    unique: [period: 30, keys: [:check_id], states: :incomplete]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.Evaluation
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"check_id" => check_id}}) do
    actor = SystemActor.system(:composite_check_evaluation)

    case CompositeCheck.get_by_id(check_id, actor: actor) do
      {:ok, %{state: :enabled} = check} ->
        result = Evaluation.run(check, actor: actor)
        reschedule(check)
        handle_result(check, result)

      {:ok, _check} ->
        {:ok, :skipped}

      {:error, _reason} ->
        {:cancel, "composite check #{check_id} no longer exists"}
    end
  end

  defp handle_result(check, {:ok, summary}) do
    Logger.debug("composite check evaluated",
      check_id: check.id,
      evaluated: summary.evaluated,
      transitions: length(summary.transitions),
      removed: summary.removed
    )

    {:ok, summary}
  end

  defp handle_result(check, {:error, reason} = error) do
    Logger.warning("composite check evaluation failed",
      check_id: check.id,
      reason: inspect(reason)
    )

    error
  end

  @doc """
  Schedules the next evaluation for a check.

  Safe to call when Oban is unavailable: a check must stay saveable when the
  scheduler is down, matching the contract sweep groups already have.
  """
  # Matches a plain map rather than %CompositeCheck{}: a struct pattern here is
  # a compile-time dependency that closes a cycle with ScheduleNotifier.
  def ensure_scheduled(check)

  def ensure_scheduled(%{state: :enabled, id: id, evaluation_interval_seconds: interval}) do
    if ObanSupport.available?() do
      %{check_id: id}
      |> new(schedule_in: interval)
      |> ObanSupport.safe_insert()
    else
      {:error, :oban_unavailable}
    end
  end

  def ensure_scheduled(%{}), do: {:ok, :not_enabled}

  @doc "Cancels any pending evaluation jobs for a check."
  def cancel(check_id) do
    import Ecto.Query

    Oban.Job
    |> where([j], j.worker == ^to_string(__MODULE__))
    |> where([j], j.state in ["available", "scheduled", "retryable"])
    |> where([j], fragment("? ->> 'check_id' = ?", j.args, ^to_string(check_id)))
    |> Oban.cancel_all_jobs()

    :ok
  rescue
    _ -> :ok
  end

  defp reschedule(check), do: ensure_scheduled(check)
end
