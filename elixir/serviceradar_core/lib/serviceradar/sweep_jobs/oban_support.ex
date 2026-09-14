defmodule ServiceRadar.SweepJobs.ObanSupport do
  @moduledoc """
  Helpers for safely interacting with Oban from sweep job workflows.

  This prevents user-facing actions from crashing when Oban isn't running
  in the current process (e.g., web-ng).
  """

  import Ecto.Query, warn: false

  alias ServiceRadar.Repo

  require Logger

  @default_stale_conflict_cutoff_seconds 14_400

  @spec available?() :: boolean()
  def available? do
    case Oban.Registry.whereis(Oban) do
      pid when is_pid(pid) -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @spec prefix() :: binary()
  def prefix do
    case Application.get_env(:serviceradar_core, Oban) do
      config when is_list(config) -> Keyword.get(config, :prefix, "platform")
      _ -> "platform"
    end
  rescue
    _ -> "platform"
  end

  @type oban_insertable :: Ecto.Changeset.t() | Oban.Job.t()

  @spec safe_insert(oban_insertable(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def safe_insert(job, opts \\ []) do
    if available_fun(opts).() do
      try do
        job
        |> insert_fun(opts).()
        |> maybe_retry_stale_executing_conflict(job, opts)
      rescue
        e in RuntimeError ->
          {:error, {:oban_unavailable, Exception.message(e)}}

        e ->
          {:error, {:oban_insert_failed, e}}
      end
    else
      {:error, :oban_unavailable}
    end
  end

  @spec stale_conflict_cutoff_seconds() :: pos_integer()
  def stale_conflict_cutoff_seconds do
    Application.get_env(
      :serviceradar_core,
      :oban_stale_conflict_cutoff_seconds,
      @default_stale_conflict_cutoff_seconds
    )
  end

  @spec recover_stale_executing_conflict(Oban.Job.t(), DateTime.t(), pos_integer()) ::
          {non_neg_integer(), nil | [term()]}
  def recover_stale_executing_conflict(
        %Oban.Job{id: id, state: "executing"},
        %DateTime{} = now,
        cutoff_seconds
      ) do
    cutoff =
      now
      |> DateTime.add(-cutoff_seconds, :second)
      |> DateTime.to_naive()

    query =
      Oban.Job
      |> where([j], j.id == ^id)
      |> where([j], j.state == "executing")
      |> where([j], not is_nil(j.attempted_at) and j.attempted_at < ^cutoff)
      |> lock("FOR UPDATE")

    case Repo.transaction(fn -> discard_stale_job(query, now) end) do
      {:ok, result} -> result
      {:error, reason} -> {0, [{:stale_oban_recovery_failed, reason}]}
    end
  rescue
    error -> {0, [{:stale_oban_recovery_failed, error}]}
  end

  def recover_stale_executing_conflict(_conflict_job, _now, _cutoff_seconds), do: {0, nil}

  @doc """
  Counts the incomplete (`available`, `scheduled`, `executing` or `retryable`) chain jobs of a
  worker designed to run as a single self-rescheduling chain.

  A chain job is any job of `worker` whose args do not carry `one_off_key`. Chain jobs cannot be
  recognised by comparing args with `%{}`: a successor usually carries bookkeeping args such as
  `"scheduled_at"`. A one-off run is recognised by its key instead (a `"day"` re-run, a `"force"`
  refresh) and is never counted.
  """
  @spec incomplete_chain_job_count(module(), String.t()) :: non_neg_integer()
  def incomplete_chain_job_count(worker, one_off_key)
      when is_atom(worker) and is_binary(one_off_key) do
    Oban.Job
    |> where([j], j.worker == ^Oban.Worker.to_string(worker))
    |> where([j], j.state in ["available", "scheduled", "executing", "retryable"])
    |> where([j], fragment("(? ->> ?) IS NULL", j.args, ^one_off_key))
    |> Repo.aggregate(:count, prefix: prefix())
  end

  @doc """
  Cancels every pending (`scheduled` or `available`) chain job of `worker` except the earliest
  due. Chain jobs are those whose args do not carry `one_off_key`, as in
  `incomplete_chain_job_count/2`, so a one-off run is never cancelled.

  A broken "already scheduled" guard lets every call insert another chain, and each chain keeps
  rescheduling itself, so repairing the guard does not remove the ones that already exist. Those
  workers call this when `incomplete_chain_job_count/2` finds more than one chain job.

  `executing` and `retryable` jobs are never touched: an executing job inserts its own successor
  when it finishes, and a later call trims that one. Pending rows are locked with
  `FOR UPDATE SKIP LOCKED`, so a call never waits on, or deadlocks with, a row held by Oban's
  stager or by a concurrent call on another node. Each call keeps the earliest of the rows it
  locked, so concurrent calls never cancel every pending job; under contention a duplicate can
  survive until the next call.

  Does nothing inside an open transaction, such as an Ash action's `after_action` hook, so the
  caller's save never holds `oban_jobs` row locks or fails because of the repair; the periodic
  schedulers repeat the call outside one. A database error is logged and cancels nothing.

  Returns the number of jobs cancelled, and logs it when non-zero.
  """
  @spec cancel_duplicate_pending_jobs(module(), String.t()) :: non_neg_integer()
  def cancel_duplicate_pending_jobs(worker, one_off_key)
      when is_atom(worker) and is_binary(one_off_key) do
    if Repo.in_transaction?() do
      0
    else
      cancel_duplicates(Oban.Worker.to_string(worker), one_off_key)
    end
  end

  defp cancel_duplicates(worker_name, one_off_key) do
    {:ok, cancelled} =
      Repo.transaction(fn -> cancel_all_but_earliest_pending(worker_name, one_off_key) end)

    if cancelled > 0 do
      Logger.warning("Cancelled duplicate pending Oban jobs",
        worker: worker_name,
        cancelled_jobs: cancelled
      )
    end

    cancelled
  rescue
    error ->
      Logger.warning("Failed to cancel duplicate pending Oban jobs",
        worker: worker_name,
        reason: inspect(error)
      )

      0
  end

  defp cancel_all_but_earliest_pending(worker_name, one_off_key) do
    query =
      Oban.Job
      |> where([j], j.worker == ^worker_name and j.state in ["scheduled", "available"])
      |> where([j], fragment("(? ->> ?) IS NULL", j.args, ^one_off_key))
      |> order_by([j], asc: j.scheduled_at, asc: j.id)
      |> lock("FOR UPDATE SKIP LOCKED")
      |> select([j], j.id)

    case Repo.all(query, prefix: prefix()) do
      [_earliest | [_ | _] = duplicate_ids] ->
        cancel = [set: [state: "cancelled", cancelled_at: DateTime.utc_now()]]

        {cancelled, _} =
          Oban.Job
          |> where([j], j.id in ^duplicate_ids)
          |> Repo.update_all(cancel, prefix: prefix())

        cancelled

      _at_most_one ->
        0
    end
  end

  defp maybe_retry_stale_executing_conflict(
         {:ok, %Oban.Job{conflict?: true, state: "executing"} = conflict_job},
         original_job,
         opts
       ) do
    cutoff_seconds =
      Keyword.get(opts, :stale_conflict_cutoff_seconds, stale_conflict_cutoff_seconds())

    now = now_fun(opts).()

    if stale_executing_conflict?(conflict_job, now, cutoff_seconds) do
      case recover_stale_conflict_fun(opts).(conflict_job, now, cutoff_seconds) do
        {count, _} when is_integer(count) and count > 0 ->
          Logger.warning("Retrying Oban insert after recovering stale executing conflict",
            stale_oban_job_id: conflict_job.id,
            worker: conflict_job.worker,
            queue: conflict_job.queue,
            stale_conflict_cutoff_seconds: cutoff_seconds
          )

          insert_fun(opts).(original_job)

        {_count, recovery_errors} ->
          Logger.warning("Oban insert hit a stale executing conflict that was not recovered",
            stale_oban_job_id: conflict_job.id,
            worker: conflict_job.worker,
            queue: conflict_job.queue,
            attempted_at: inspect(conflict_job.attempted_at),
            stale_conflict_cutoff_seconds: cutoff_seconds,
            recovery_errors: inspect(recovery_errors)
          )

          {:error, stale_conflict_error(conflict_job, opts)}
      end
    else
      {:ok, conflict_job}
    end
  end

  defp maybe_retry_stale_executing_conflict(result, _original_job, _opts), do: result

  defp discard_stale_job(query, now) do
    case Repo.one(query, prefix: prefix()) do
      nil ->
        {0, nil}

      %Oban.Job{} = job ->
        job
        |> Ecto.Changeset.change(state: "discarded", discarded_at: now)
        |> Repo.update(prefix: prefix())
        |> case do
          {:ok, _discarded} -> {1, nil}
          {:error, changeset} -> Repo.rollback({:invalid_stale_oban_job_update, changeset.errors})
        end
    end
  end

  defp stale_executing_conflict?(
         %Oban.Job{attempted_at: %DateTime{} = attempted_at},
         %DateTime{} = now,
         cutoff_seconds
       ) do
    DateTime.diff(now, attempted_at, :second) >= cutoff_seconds
  end

  defp stale_executing_conflict?(
         %Oban.Job{attempted_at: %NaiveDateTime{} = attempted_at},
         %DateTime{} = now,
         cutoff_seconds
       ) do
    NaiveDateTime.diff(DateTime.to_naive(now), attempted_at, :second) >= cutoff_seconds
  end

  defp stale_executing_conflict?(_job, _now, _cutoff_seconds), do: false

  defp stale_conflict_error(conflict_job, opts) do
    case Keyword.get(opts, :stale_conflict_error) do
      fun when is_function(fun, 1) -> fun.(conflict_job)
      nil -> {:stale_oban_job_conflict, conflict_job.id}
      reason -> reason
    end
  end

  defp available_fun(opts), do: Keyword.get(opts, :available_fun, &available?/0)
  defp insert_fun(opts), do: Keyword.get(opts, :insert_fun, &Oban.insert/1)

  defp recover_stale_conflict_fun(opts),
    do: Keyword.get(opts, :recover_stale_conflict_fun, &recover_stale_executing_conflict/3)

  defp now_fun(opts), do: Keyword.get(opts, :now_fun, &DateTime.utc_now/0)
end
