defmodule ServiceRadar.Automation.Ansible.RunWatchdog do
  @moduledoc """
  Sweeps for `PlaybookRun`s stuck in non-terminal states past their watchdog
  threshold and transitions them to `:unreachable`.

  Per openspec change `add-ansible-integration` (Run Lifecycle State
  Machine + Event Ingestion Watchdog requirements): a run that's been in
  `:pending` / `:launching` / `:running` for longer than its job
  template's timeout (or a 1h fallback when the timeout is unknown) is
  almost certainly orphaned -- AWX hung, the agent vanished, or something
  ate the events. We mark it `:unreachable` with a diagnostic so the UI
  reflects reality and operators can move on.

  Single global worker, runs on a cron-like cadence (default 60s, per
  app env `:awx_run_watchdog_interval_seconds`).
  """

  use Oban.Worker,
    queue: :ansible_pulse,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.PlaybookRun
  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query
  require Logger

  @default_interval_seconds 60
  @default_fallback_timeout_seconds 3_600
  @min_interval_seconds 30

  @spec ensure_scheduled() ::
          {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if scheduled?() do
      {:ok, :already_scheduled}
    else
      %{} |> new() |> ObanSupport.safe_insert()
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    actor = SystemActor.system(:awx_run_watchdog)
    now = DateTime.utc_now()

    case load_non_terminal_runs(actor) do
      {:ok, runs} ->
        Enum.each(runs, fn run ->
          if stuck?(run, now) do
            mark_unreachable(run, now, actor)
          end
        end)

        schedule_next()
        :ok

      {:error, reason} ->
        Logger.warning("AWX RunWatchdog: could not list non-terminal runs",
          reason: inspect(reason)
        )

        schedule_next()
        {:error, reason}
    end
  end

  @doc """
  Pure predicate: is the run past its watchdog threshold? Exposed for
  unit tests so production logic can be exercised without a database.

  A run is considered "stuck" when its `started_at` (or `inserted_at`
  fallback) is older than `2 × job_template_timeout`, or older than the
  configured fallback (default 1h) if no job-template timeout is known.

  Options:
    * `:fallback_timeout_seconds` — default 3600.
  """
  @spec stuck?(map(), DateTime.t(), keyword()) :: boolean()
  def stuck?(run, now, opts \\ []) do
    threshold_seconds = threshold_seconds(run, opts)
    reference_time = run_started_at(run)

    case reference_time do
      nil -> false
      %DateTime{} = ts -> DateTime.diff(now, ts, :second) >= threshold_seconds
    end
  end

  ## Internals -----------------------------------------------------------------

  defp threshold_seconds(run, opts) do
    fallback = Keyword.get(opts, :fallback_timeout_seconds, @default_fallback_timeout_seconds)
    template_timeout = job_template_timeout_seconds(run)

    if template_timeout, do: template_timeout * 2, else: fallback
  end

  defp job_template_timeout_seconds(run) do
    case run do
      %{metadata: %{"job_template_timeout_seconds" => v}} when is_integer(v) and v > 0 -> v
      %{metadata: %{job_template_timeout_seconds: v}} when is_integer(v) and v > 0 -> v
      _ -> nil
    end
  end

  defp run_started_at(%{started_at: %DateTime{} = ts}), do: ts
  defp run_started_at(%{inserted_at: %DateTime{} = ts}), do: ts
  defp run_started_at(_), do: nil

  defp load_non_terminal_runs(actor) do
    # `actor` is the SystemActor struct itself — `actor[:actor]` was a leftover
    # keyword-style access that always yielded nil, so every watchdog tick read
    # with no actor, was denied by policy, and logged "could not list
    # non-terminal runs" forever.
    #
    # The read must also name the :read action explicitly: PlaybookRun has no
    # primary read action, so a bare filter pipeline raised
    # Ash.Error.Invalid.NoPrimaryAction on every tick and the watchdog never
    # swept anything.
    PlaybookRun
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(state in [:pending, :launching, :running])
    |> Ash.read(actor: actor)
  end

  defp mark_unreachable(run, now, actor) do
    diagnostics = %{
      "watchdog" => "exceeded watchdog threshold",
      "marked_at" => DateTime.to_iso8601(now)
    }

    case PlaybookRun.record_unreachable(run, %{diagnostics: diagnostics}, actor: actor) do
      {:ok, _} ->
        Logger.info("AWX RunWatchdog marked run unreachable",
          run_id: run.id,
          awx_job_id: run.awx_job_id
        )

        :ok

      {:error, reason} ->
        Logger.warning("AWX RunWatchdog could not mark run unreachable",
          run_id: run.id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp schedule_next do
    _ =
      ObanSupport.safe_insert(
        SelfScheduling.successor_changeset(__MODULE__, %{}, interval_seconds())
      )

    :ok
  end

  defp interval_seconds do
    seconds =
      Application.get_env(
        :serviceradar_core,
        :awx_run_watchdog_interval_seconds,
        @default_interval_seconds
      )

    max(@min_interval_seconds, seconds)
  end

  defp scheduled? do
    import Ecto.Query

    query =
      from job in Oban.Job,
        where:
          job.worker == ^to_string(__MODULE__) and
            job.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1

    ServiceRadar.Repo.exists?(query, prefix: ObanSupport.prefix())
  end
end
