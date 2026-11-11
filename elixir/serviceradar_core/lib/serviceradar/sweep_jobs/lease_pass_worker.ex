defmodule ServiceRadar.SweepJobs.LeasePassWorker do
  @moduledoc """
  Runs `ServiceRadar.SweepJobs.LeasePass` from the Oban crontab every five minutes, which keeps
  a connected agent's lease horizon full and applies group, agent and setting changes.

  The pass is idempotent, so a skipped or failed run is caught up by the next one.

  A run holds the pass advisory lock on a dedicated direct session
  (`ServiceRadar.Repo.DirectSession`, outside the pool, owned by the job process) for the
  whole pass and releases it in an `ensure` block. Death of the process or node closes the
  socket and PostgreSQL releases the lock — this covers the observed orphan source, runs
  outlasting the shutdown grace at pod stop. `rescue_orphaned/1` proves an `executing`
  row dead the same way: past the grace with nobody holding the lock, the row goes back
  to `available`. A run that starts while another holds the lock skips its tick: the
  holder covers it, and two passes never grind against each other.

  The run is killed after `timeout/1` (Oban `TimeoutError`, a failed attempt like any
  other): with `max_attempts: 1` the row ends terminal, never `executing`, so the timeout
  leaves no orphan behind and the next tick enqueues normally.
  """

  @behaviour ServiceRadar.Jobs.OrphanRescue

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: :infinity, states: [:available, :scheduled]]

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Jobs.ReapStalePeriodicJobsWorker
  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.DirectSession
  alias ServiceRadar.SweepJobs.LeasePass
  alias ServiceRadar.SweepJobs.ObanSupport
  alias ServiceRadar.SweepJobs.RecoveryRetryIntents

  require Logger

  @worker_name inspect(__MODULE__)

  # Stable lock key, hashed the same way for the run and the rescue probe. Session scope
  # (not `pg_advisory_xact_lock`): the pass spans many transactions on pooled connections,
  # while the lock lives on the dedicated session.
  @advisory_lock_key "sweep_lease_pass"
  @take_lock_sql "SELECT pg_try_advisory_lock(hashtextextended($1, 0))"
  @unlock_lock_sql "SELECT pg_advisory_unlock(hashtextextended($1, 0))"

  # Covers only the mark-executing-to-lock window: a live run holds the lock from its
  # first statement, so anything older than this with a free lock is not running.
  @orphan_grace_seconds 60
  @lock_timeout_ms 10_000
  @probe_timeout_ms 10_000

  # Provisional backstop (task 1.9 measures the post-fix pass and tightens it): well
  # above the slowest measured full re-issue (169 s pre-fix) and a whole pass over all
  # agents, comfortably under the 4-hour age rescue.
  @timeout_ms 15 * 60_000

  @doc "Provisional execution backstop in milliseconds (see task 1.9)."
  @spec timeout_ms() :: pos_integer()
  def timeout_ms, do: @timeout_ms

  @impl Oban.Worker
  def timeout(_job), do: @timeout_ms

  @impl Oban.Worker
  def perform(_job) do
    case with_pass_lock(&run_pass/0) do
      {:error, {:direct_session_unavailable, reason}} ->
        {:error, {:lease_pass_lock_session_unavailable, reason}}

      result ->
        result
    end
  end

  @doc """
  Put this worker's orphaned `executing` rows back to `available`.

  A row is an orphan when it was attempted more than the grace ago and nobody holds the
  pass advisory lock, probed with the same `pg_try_advisory_lock` the run takes on a
  short direct session: acquiring it proves no run holds it, and closing the session
  releases it again. A row whose lock is held is never touched.

  Rescue is Lifeline's — the row goes back to `available` with `max_attempts` raised by
  one (a deploy is not the job's failure, and Oban only fetches rows with
  `attempt < max_attempts`), and the row's `errors` records why. Options: `:grace_seconds`
  overrides the grace, `:now` the clock the row age is measured against. Never raises;
  a failure is returned as `{:error, reason}`.

  ## Races

    * A run that starts after the probe sees the rescued row, or its own row, exactly
      as any run would: it takes the lock or skips its tick on a busy lock.
    * Two probes serialize on the lock: the second fails to acquire it and rescues
      nothing. Candidate rows are locked `FOR UPDATE SKIP LOCKED` and the update
      re-checks `state = 'executing'`, so a row Oban finished meanwhile is left alone.
    * A run that was live after all (it outlasted the grace before reaching the lock)
      runs a redundant pass alongside the rescued row. The pass is idempotent and
      per-agent delivery serializes through the try-lock, so they stay complementary
      and share one row — the last to finish records its outcome.
  """
  @impl ServiceRadar.Jobs.OrphanRescue
  @spec rescue_orphaned(keyword()) ::
          {:ok, [ReapStalePeriodicJobsWorker.job_ref()]} | {:error, term()}
  def rescue_orphaned(opts \\ []) do
    grace_seconds = Keyword.get(opts, :grace_seconds, @orphan_grace_seconds)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    cutoff = DateTime.shift(now, second: -grace_seconds)

    result =
      Repo.transact(
        fn ->
          case executing_candidates(cutoff) do
            [] -> {:ok, []}
            ids -> {:ok, rescue_if_orphaned(ids)}
          end
        end,
        timeout: @probe_timeout_ms
      )

    with {:ok, [_ | _] = rescued} <- result do
      Logger.warning(
        "Rescued orphaned sweep lease pass: executing with the pass lock free",
        rescued_jobs: rescued,
        orphan_grace_seconds: grace_seconds
      )
    end

    result
  rescue
    error -> {:error, error}
  end

  defp run_pass do
    started_at = DateTime.utc_now()

    case LeasePass.run(started_at) do
      {:ok, summary} ->
        if summary.scheduled + summary.dropped + summary.revoked + summary.pushed +
             summary.withdrawn + summary.missed_offline + summary.missed_exhausted +
             summary.errors > 0 do
          Logger.info("Sweep lease pass: #{inspect(summary)}")
        end

        if summary.errors == 0 do
          case RecoveryRetryIntents.reconciled_before(started_at) do
            {:ok, _count} -> :ok
            {:error, _} = error -> error
          end
        else
          :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The pass lock lives on a dedicated direct session, never on a pooled connection
  # (through a transaction-mode pooler an unlock could land on another backend and
  # miss). A second run that finds the lock held skips its tick: the holder covers it.
  defp with_pass_lock(fun) do
    DirectSession.run(fn session ->
      case Postgrex.query(session, @take_lock_sql, [@advisory_lock_key],
             timeout: @lock_timeout_ms
           ) do
        {:ok, %{rows: [[true]]}} ->
          try do
            fun.()
          after
            release_pass_lock(session)
          end

        {:ok, %{rows: [[false]]}} ->
          Logger.info("Sweep lease pass: another run holds the pass lock, skipping this tick")
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  # Best effort: the session closes when `DirectSession.run/1` returns (releasing the
  # lock either way), and on a timeout kill the socket may already be gone.
  defp release_pass_lock(session) do
    try do
      Postgrex.query(session, @unlock_lock_sql, [@advisory_lock_key], timeout: @lock_timeout_ms)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp executing_candidates(cutoff) do
    Repo.all(
      from(j in Oban.Job,
        where: j.worker == ^@worker_name,
        where: j.state == "executing",
        where: not is_nil(j.attempted_at) and j.attempted_at < ^cutoff,
        lock: "FOR UPDATE SKIP LOCKED",
        select: j.id
      ),
      prefix: ObanSupport.prefix()
    )
  end

  defp rescue_if_orphaned(ids) do
    if pass_lock_free?() do
      mark_available(ids)
    else
      []
    end
  end

  defp pass_lock_free? do
    case DirectSession.run(fn session ->
           Postgrex.query(session, @take_lock_sql, [@advisory_lock_key],
             timeout: @probe_timeout_ms
           )
         end) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp mark_available(ids) do
    reason =
      "orphaned: executing with the sweep lease pass lock free; " <>
        "rescued to available without charging the attempt"

    {_count, rescued} =
      Repo.update_all(
        from(j in Oban.Job,
          where: j.id in ^ids and j.state == "executing",
          update: [
            set: [
              state: "available",
              max_attempts: fragment("GREATEST(?, ?) + 1", j.max_attempts, j.attempt),
              errors:
                fragment(
                  "? || jsonb_build_object('attempt', ?, 'at', now(), 'error', ?::text)",
                  j.errors,
                  j.attempt,
                  ^reason
                )
            ]
          ],
          select: %{
            id: j.id,
            worker: j.worker,
            queue: j.queue,
            attempt: j.attempt,
            max_attempts: j.max_attempts
          }
        ),
        [],
        prefix: ObanSupport.prefix()
      )

    rescued
  end
end
