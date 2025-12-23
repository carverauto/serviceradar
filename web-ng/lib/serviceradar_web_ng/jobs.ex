defmodule ServiceRadarWebNG.Jobs do
  @moduledoc """
  Background job scheduling and catalog management.
  """

  import Ecto.Query, warn: false

  alias Oban.Cron.Expression
  alias Oban.Job
  alias ServiceRadarWebNG.Edge.Workers.ExpirePackagesWorker
  alias ServiceRadarWebNG.Jobs.{RefreshTraceSummariesWorker, Schedule}
  alias ServiceRadarWebNG.Repo

  require Logger

  @default_timezone "Etc/UTC"

  @job_catalog %{
    "refresh_trace_summaries" => %{
      key: "refresh_trace_summaries",
      label: "Trace summaries refresh",
      description: "Refresh the otel_trace_summaries materialized view.",
      worker: RefreshTraceSummariesWorker,
      queue: :maintenance,
      args: %{},
      default_cron: "*/2 * * * *",
      unique_period_seconds: 180
    },
    "expire_packages" => %{
      key: "expire_packages",
      label: "Expire onboarding packages",
      description:
        "Marks edge onboarding packages as expired when their tokens have passed expiration.",
      worker: ExpirePackagesWorker,
      queue: :maintenance,
      args: %{},
      default_cron: "0 * * * *",
      unique_period_seconds: 3600
    }
  }

  def list_schedules do
    Repo.all(Schedule)
  rescue
    error in Postgrex.Error ->
      Logger.warning("Failed to load job schedules: #{Exception.message(error)}")
      []
  end

  def list_enabled_schedules do
    from(s in Schedule, where: s.enabled)
    |> Repo.all()
  rescue
    error in Postgrex.Error ->
      Logger.warning("Failed to load job schedules: #{Exception.message(error)}")
      []
  end

  def get_schedule!(id), do: Repo.get!(Schedule, id)

  def change_schedule(%Schedule{} = schedule, attrs \\ %{}) do
    Schedule.changeset(schedule, attrs)
  end

  def update_schedule(%Schedule{} = schedule, attrs) do
    schedule
    |> Schedule.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        refresh_scheduler()
        {:ok, updated}

      error ->
        error
    end
  end

  def list_schedule_entries(opts \\ []) do
    run_limit = Keyword.get(opts, :run_limit, 5)

    list_schedules()
    |> Enum.map(fn schedule ->
      %{
        schedule: schedule,
        job: Map.get(@job_catalog, schedule.job_key),
        next_run_at: next_run_at(schedule),
        recent_runs: list_recent_runs(schedule.job_key, limit: run_limit)
      }
    end)
  end

  def job_catalog, do: @job_catalog

  def job_definition(job_key), do: Map.get(@job_catalog, job_key)

  def list_recent_runs(job_key, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)

    case job_definition(job_key) do
      %{worker: worker} ->
        from(j in Job,
          where: j.worker == ^inspect(worker),
          order_by: [desc: j.inserted_at],
          limit: ^limit
        )
        |> Repo.all()

      _ ->
        []
    end
  rescue
    error in Postgrex.Error ->
      Logger.warning("Failed to load recent job runs: #{Exception.message(error)}")
      []
  end

  def apply_env_overrides do
    cron_override = System.get_env("TRACE_SUMMARIES_REFRESH_CRON")

    if cron_override do
      apply_cron_override("refresh_trace_summaries", cron_override)
    else
      :ok
    end
  rescue
    error in Postgrex.Error ->
      Logger.warning("Failed to apply schedule overrides: #{Exception.message(error)}")
      :error
  end

  def refresh_scheduler(oban_name \\ Oban) do
    case Oban.Registry.whereis(oban_name, {:plugin, ServiceRadarWebNG.Jobs.Scheduler}) do
      nil ->
        :noop

      pid ->
        GenServer.cast(pid, :refresh)
    end
  end

  def enqueue_due_schedules(oban_name \\ Oban) do
    now = DateTime.utc_now()

    list_enabled_schedules()
    |> Enum.reduce(%{enqueued: 0, errors: []}, fn schedule, acc ->
      case enqueue_if_due(schedule, now, oban_name) do
        {:ok, _job} ->
          %{acc | enqueued: acc.enqueued + 1}

        {:skip, _reason} ->
          acc

        {:error, reason} ->
          %{acc | errors: [reason | acc.errors]}
      end
    end)
  end

  def next_run_at(%Schedule{} = schedule, now \\ DateTime.utc_now()) do
    with {:ok, expr} <- Expression.parse(schedule.cron),
         timezone <- schedule.timezone || @default_timezone,
         now_tz <- now_in_zone(now, timezone),
         base_time <- schedule.last_enqueued_at || DateTime.add(now_tz, -60, :second),
         base_time <- shift_zone(base_time, timezone) do
      case Expression.next_at(expr, base_time) do
        %DateTime{} = next_at -> next_at
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp enqueue_if_due(%Schedule{} = schedule, now, oban_name) do
    if schedule.enabled do
      with {:ok, expr} <- Expression.parse(schedule.cron),
           timezone <- schedule.timezone || @default_timezone,
           job_def when is_map(job_def) <- job_definition(schedule.job_key),
           now_tz <- now_in_zone(now, timezone),
           base_time <- schedule.last_enqueued_at || DateTime.add(now_tz, -60, :second),
           base_time <- shift_zone(base_time, timezone),
           %DateTime{} = next_at <- Expression.next_at(expr, base_time),
           true <- DateTime.compare(next_at, now_tz) in [:lt, :eq] do
        enqueue_schedule(schedule, job_def, next_at, oban_name)
      else
        nil ->
          {:skip, :unknown_job}

        false ->
          {:skip, :not_due}

        {:error, reason} ->
          {:error, reason}

        :unknown ->
          {:skip, :unknown_next_at}
      end
    else
      {:skip, :disabled}
    end
  end

  defp apply_cron_override(job_key, cron_override) do
    job_def = job_definition(job_key)

    case {job_def, Repo.get_by(Schedule, job_key: job_key)} do
      {%{default_cron: default_cron}, %Schedule{} = schedule}
      when schedule.cron == default_cron ->
        schedule
        |> Schedule.changeset(%{cron: cron_override})
        |> Repo.update()
        |> case do
          {:ok, _updated} ->
            Logger.info("Applied cron override for #{job_key}")
            refresh_scheduler()
            :ok

          {:error, changeset} ->
            Logger.warning("Failed to apply cron override for #{job_key}: #{inspect(changeset)}")

            :error
        end

      _ ->
        :ok
    end
  end

  defp enqueue_schedule(%Schedule{} = schedule, job_def, next_at, oban_name) do
    args = Map.merge(job_def.args || %{}, schedule.args || %{})
    unique = unique_opts(schedule, job_def)

    scheduled_at = shift_zone(next_at, @default_timezone)

    job_opts =
      [
        queue: job_def.queue || :default,
        meta: %{"cron" => true, "cron_expr" => schedule.cron}
      ]
      |> maybe_put(:unique, unique)
      |> maybe_put(:scheduled_at, scheduled_at)

    changeset = job_def.worker.new(args, job_opts)

    case Oban.insert(oban_name, changeset) do
      {:ok, job} ->
        update_last_enqueued_at(schedule, scheduled_at)
        {:ok, job}

      {:error, reason} ->
        Logger.warning("Failed to enqueue #{schedule.job_key} job: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp unique_opts(schedule, job_def) do
    period = schedule.unique_period_seconds || job_def.unique_period_seconds

    if is_integer(period) and period > 0 do
      [
        period: period,
        states: [:available, :scheduled, :executing],
        keys: [:worker, :args, :queue]
      ]
    end
  end

  defp now_in_zone(%DateTime{} = now, timezone) do
    case DateTime.shift_zone(now, timezone) do
      {:ok, shifted} -> shifted
      {:error, _} -> now
    end
  end

  defp shift_zone(%DateTime{} = dt, timezone) do
    case DateTime.shift_zone(dt, timezone) do
      {:ok, shifted} -> shifted
      {:error, _} -> dt
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp update_last_enqueued_at(%Schedule{} = schedule, scheduled_at) do
    updated_at = DateTime.utc_now()

    from(s in Schedule, where: s.id == ^schedule.id)
    |> Repo.update_all(set: [last_enqueued_at: scheduled_at, updated_at: updated_at])
    |> case do
      {0, _} ->
        Logger.warning("Failed to update schedule #{schedule.job_key}: no rows updated")

      {_count, _} ->
        :ok
    end
  rescue
    error in Postgrex.Error ->
      Logger.warning("Failed to update schedule #{schedule.job_key}: #{Exception.message(error)}")
      :error
  end
end
