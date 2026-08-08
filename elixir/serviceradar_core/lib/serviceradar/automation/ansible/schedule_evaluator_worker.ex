defmodule ServiceRadar.Automation.Ansible.ScheduleEvaluatorWorker do
  @moduledoc """
  Evaluates `PlaybookSchedule`s and fires `PlaybookRun`s when their cron
  expression next fires.

  Single global worker, runs on a 60-second cadence (override via
  `:awx_schedule_evaluator_interval_seconds`). Each tick:

    1. Reads enabled schedules whose `next_run_at <= now` via the
       `due` read action.
    2. Per schedule:
       a. Loads the linked Playbook + (when `:awx`-sourced) its
          Controller. Schedules pointing at git-sourced playbooks
          without an AWX template binding fail with outcome `:error`
          (v1 limitation: schedules require an AWX-resolvable launch
          target; bind your git playbook to a job template first).
       b. Loads the previous `PlaybookRun` (if any). If the schedule
          has `allow_concurrent: false` and the previous run is still
          non-terminal, records outcome `:skipped_overlap` -- no new
          run is created.
       c. Otherwise creates a `PlaybookRun` in `:pending` and one
          `PlaybookRunTarget` per device_uid (resolving the device's
          AWX host name from `ansible_inventory_ref`), then dispatches
          `awx.launch_job` via AwxClient.
    3. Computes the schedule's `next_run_at` from cron + timezone via
       `Oban.Cron.Expression.next_at/2` and persists it via
       `record_evaluation`.

  See openspec change `add-ansible-integration` -- proposal "Affected
  code" includes `ScheduleEvaluatorWorker (AshOban)`. Pure helpers
  (`decide_outcome/3`, `compute_next_run_at/2`, `build_host_limit/1`)
  are exposed for unit tests; `perform/1` does the Ash + AwxClient I/O.
  """

  use Oban.Worker,
    queue: :ansible_pulse,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias Oban.Cron.Expression
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.PlaybookRun
  alias ServiceRadar.Automation.Ansible.PlaybookSchedule
  alias ServiceRadar.Automation.Ansible.RunLauncher
  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @default_interval_seconds 60
  @min_interval_seconds 30
  @non_terminal_states [:pending, :launching, :running]

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
    actor = SystemActor.system(:awx_schedule_evaluator)
    now = DateTime.utc_now()

    case PlaybookSchedule.list_due(actor: actor) do
      {:ok, schedules} ->
        Enum.each(schedules, &evaluate_schedule(&1, now, actor))
        schedule_next()
        :ok

      {:error, reason} ->
        Logger.warning("AWX ScheduleEvaluatorWorker: could not list due schedules",
          reason: inspect(reason)
        )

        schedule_next()
        {:error, reason}
    end
  end

  ## Pure helpers (testable without DB) ----------------------------------------

  @doc """
  Decide what to do with a due schedule given its previous run.
  Returns one of:

    * `:fire` — proceed with launch
    * `:skip_overlap` — `allow_concurrent: false` AND last run is still non-terminal
    * `:skip_disabled` — schedule is no longer enabled
  """
  @spec decide_outcome(map(), map() | nil, DateTime.t()) ::
          :fire | :skip_overlap | :skip_disabled
  def decide_outcome(schedule, last_run, _now)

  def decide_outcome(%{enabled: false}, _last_run, _now), do: :skip_disabled

  def decide_outcome(%{allow_concurrent: true}, _last_run, _now), do: :fire

  def decide_outcome(%{allow_concurrent: _}, nil, _now), do: :fire

  def decide_outcome(%{allow_concurrent: _}, %{state: state}, _now) do
    if state in @non_terminal_states, do: :skip_overlap, else: :fire
  end

  @doc """
  Computes the next firing time for the schedule's cron + timezone.

  Returns `{:ok, %DateTime{}}` or `{:error, reason}`. Uses
  `Oban.Cron.Expression` so syntax is the same as the rest of our
  cron-driven jobs.
  """
  @spec compute_next_run_at(map(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, term()}
  def compute_next_run_at(%{cron: cron, timezone: timezone}, %DateTime{} = now)
      when is_binary(cron) and is_binary(timezone) do
    with :ok <- ensure_utc_only(timezone),
         {:ok, expr} <- Expression.parse(cron) do
      safe_next_at(expr, now)
    end
  end

  def compute_next_run_at(_, _now), do: {:error, :invalid_schedule}

  # v1 only supports UTC schedules. Non-UTC requires `:tzdata` (or another
  # configured `Calendar.TimeZoneDatabase`) which we haven't added yet.
  defp ensure_utc_only(tz) when tz in ["UTC", "Etc/UTC"], do: :ok

  defp ensure_utc_only(_), do: {:error, :timezone_database_unavailable}

  defp safe_next_at(expr, %DateTime{} = base) do
    base = DateTime.shift_zone!(base, "Etc/UTC")

    case Expression.next_at(expr, base) do
      %DateTime{} = ts -> {:ok, ts}
      :unknown -> {:error, :unknown_next_time}
      other -> {:error, {:unexpected_next_at, other}}
    end
  end

  @doc """
  Builds the AWX `limit:` string from a list of devices. Falls back to
  device hostname when `ansible_inventory_ref["host_name"]` is missing.
  Returns `""` when no usable host names can be derived (caller should
  fail loudly in that case).
  """
  @spec build_host_limit([map()]) :: String.t()
  def build_host_limit(devices) when is_list(devices) do
    devices
    |> Enum.map(&device_host_name/1)
    |> Enum.reject(&(&1 == nil or &1 == ""))
    |> Enum.uniq()
    |> Enum.join(",")
  end

  defp device_host_name(device) do
    case device do
      %{ansible_inventory_ref: %{"host_name" => name}} when is_binary(name) and name != "" ->
        name

      %{ansible_inventory_ref: %{host_name: name}} when is_binary(name) and name != "" ->
        name

      %{hostname: name} when is_binary(name) and name != "" ->
        name

      _ ->
        nil
    end
  end

  ## Internals -----------------------------------------------------------------

  defp evaluate_schedule(schedule, now, actor) do
    last_run = load_last_run(schedule, actor)
    outcome = decide_outcome(schedule, last_run, now)

    case outcome do
      :skip_disabled ->
        record_evaluation(schedule, last_run, now, :skipped_disabled, actor)

      :skip_overlap ->
        Logger.info("AWX schedule fire skipped (overlap)",
          schedule_id: schedule.id,
          last_run_id: last_run && last_run.id
        )

        record_evaluation(schedule, last_run, now, :skipped_overlap, actor)

      :fire ->
        case fire_schedule(schedule, actor) do
          {:ok, run} ->
            record_evaluation(schedule, run, now, :fired, actor)

          {:error, reason} ->
            Logger.warning("AWX schedule fire failed",
              schedule_id: schedule.id,
              reason: inspect(reason)
            )

            record_evaluation(schedule, last_run, now, :error, actor)
        end
    end
  end

  defp load_last_run(%{last_run_id: nil}, _actor), do: nil

  defp load_last_run(%{last_run_id: id}, actor) do
    case PlaybookRun.get_by_id(id, actor: actor) do
      {:ok, run} -> run
      _ -> nil
    end
  end

  defp fire_schedule(schedule, actor) do
    RunLauncher.launch(
      %{
        playbook_id: schedule.playbook_id,
        device_uids: schedule.target_device_uids,
        extra_vars: schedule.requested_extra_vars,
        schedule_id: schedule.id,
        requested_by_actor_id: schedule.owner_id
      },
      actor: actor
    )
  end

  defp record_evaluation(schedule, last_run, now, outcome, actor) do
    next_run_at =
      case compute_next_run_at(schedule, now) do
        {:ok, ts} -> ts
        {:error, _} -> nil
      end

    last_run_id =
      case last_run do
        %{id: id} -> id
        _ -> nil
      end

    PlaybookSchedule.record_evaluation(
      schedule,
      %{
        last_run_id: last_run_id,
        next_run_at: next_run_at,
        last_evaluation_outcome: outcome
      },
      actor: actor
    )
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
        :awx_schedule_evaluator_interval_seconds,
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
