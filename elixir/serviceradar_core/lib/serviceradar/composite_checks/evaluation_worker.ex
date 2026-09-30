defmodule ServiceRadar.CompositeChecks.EvaluationWorker do
  @moduledoc """
  Runs one evaluation pass for one composite check.

  `ServiceRadar.CompositeChecks.TickWorker` inserts this job for every enabled
  check once a minute, and enabling a check inserts it for an immediate first
  run. The job decides which pass to run:

    * the **full pass** when `last_evaluated_at` or `last_incremental_at` is nil,
      or when `evaluation_interval_seconds` has elapsed since
      `last_evaluated_at` (the completion time of the last successful full
      pass);
    * otherwise the **incremental pass**, over the devices whose inputs changed
      since `last_incremental_at`.

  The periodic full pass is required even though the incremental pass follows
  input changes, and it is not a fallback. Two transitions produce no input
  write at all:

    * an input aging past its `max_age` -- nothing happens, the clock just moves
    * a device entering or leaving the scope as inventory syncs -- the device did
      not change from this check's perspective

  Both are only discoverable by re-evaluating the whole scope. Do not delete the
  full pass in favour of the incremental one.

  The job has one attempt and never inserts a successor: the next minute tick
  is the retry, which is safe because a failed pass advances neither mark.
  Uniqueness over available, scheduled and executing jobs keeps at most one job
  per check in flight, so a tick that lands while a pass is still running
  inserts nothing and two passes for one check never overlap.
  """

  # The contract is uniqueness over available, scheduled and executing. With
  # max_attempts: 1 a job can never become retryable, and nothing here
  # suspends jobs, so Oban's :incomplete group is exactly those three states;
  # naming it avoids Oban's warning that a partial list can break uniqueness.
  use Oban.Worker,
    queue: :monitoring,
    max_attempts: 1,
    unique: [keys: [:check_id], states: :incomplete, period: :infinity]

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
        pass = pass_for(check, Evaluation.db_now())
        handle_result(check, pass, run_pass(pass, check, actor))

      {:ok, _check} ->
        {:ok, :skipped}

      {:error, _reason} ->
        {:cancel, "composite check #{check_id} no longer exists"}
    end
  end

  @doc """
  Which pass a job for `check` runs at `now`.

  Measured from `last_evaluated_at`, which a successful full pass stamps at
  completion, so a full pass that ran longer than the interval is not due
  again on the next tick.
  """
  @spec pass_for(map(), DateTime.t()) :: :full | :incremental
  def pass_for(%{last_evaluated_at: nil}, _now), do: :full
  def pass_for(%{last_incremental_at: nil}, _now), do: :full

  def pass_for(%{last_evaluated_at: last, evaluation_interval_seconds: interval}, now) do
    if DateTime.diff(now, last, :second) >= interval, do: :full, else: :incremental
  end

  defp run_pass(:full, check, actor), do: Evaluation.run_full(check, actor: actor)
  defp run_pass(:incremental, check, actor), do: Evaluation.run_incremental(check, actor: actor)

  defp handle_result(check, pass, {:ok, summary}) do
    Logger.debug("composite check evaluated",
      check_id: check.id,
      pass: pass,
      evaluated: summary.evaluated,
      transitions: length(summary.transitions),
      removed: summary.removed
    )

    {:ok, summary}
  end

  defp handle_result(check, pass, {:error, reason} = error) do
    Logger.warning("composite check evaluation failed",
      check_id: check.id,
      pass: pass,
      reason: inspect(reason)
    )

    error
  end

  @doc """
  Inserts an evaluation job for an enabled check to run now.

  Uniqueness makes this a no-op while a job for the check is available,
  scheduled or executing, so a save during a pass does not fork the schedule.

  Safe to call when Oban is unavailable: a check must stay saveable when the
  scheduler is down, matching the contract sweep groups already have.
  """
  # Matches a plain map rather than %CompositeCheck{}: a struct pattern here is
  # a compile-time dependency that closes a cycle with ScheduleNotifier.
  def ensure_scheduled(check)

  def ensure_scheduled(%{state: :enabled, id: id}) do
    if ObanSupport.available?() do
      %{check_id: id}
      |> new()
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
    |> where([j], j.worker == ^Oban.Worker.to_string(__MODULE__))
    |> where([j], j.state in ["available", "scheduled", "retryable"])
    |> where([j], fragment("? ->> 'check_id' = ?", j.args, ^to_string(check_id)))
    |> Oban.cancel_all_jobs()

    :ok
  rescue
    _ -> :ok
  end
end
