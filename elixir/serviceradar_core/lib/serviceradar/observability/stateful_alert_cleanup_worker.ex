defmodule ServiceRadar.Observability.StatefulAlertCleanupWorker do
  @moduledoc """
  Worker that cleans up stale stateful alert rule snapshots.

  This worker runs daily to delete StatefulAlertRuleState records
  that haven't been seen in `@stale_after_days` days.

  ## Scheduling

  This worker is scheduled when:
  - A stateful alert rule is created
  - A stateful alert rule is enabled

  The worker reschedules itself daily.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  import Ash.Expr
  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.StatefulAlertRuleState
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query
  require Logger

  @stale_after_days 30

  # Run daily (24 hours)
  @reschedule_interval_seconds 86_400

  @doc """
  Schedules alert state cleanup if not already scheduled.

  Called automatically when stateful alert rules are created or enabled.
  """
  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      if check_existing_job() do
        {:ok, :already_scheduled}
      else
        %{} |> new() |> ObanSupport.safe_insert()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  defp check_existing_job do
    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    Repo.exists?(query, prefix: ObanSupport.prefix())
  end

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -@stale_after_days * 86_400, :second)

    Logger.info("StatefulAlertCleanupWorker: Starting cleanup",
      cutoff: cutoff
    )

    count = cleanup_stale_states(cutoff)

    Logger.info("StatefulAlertCleanupWorker: Completed",
      deleted: count
    )

    # Reschedule for tomorrow
    schedule_next_cleanup()

    :ok
  end

  defp schedule_next_cleanup do
    %{}
    |> new(schedule_in: @reschedule_interval_seconds)
    |> ObanSupport.safe_insert()
  end

  defp cleanup_stale_states(cutoff) do
    actor = SystemActor.system(:alert_cleanup)

    query =
      Ash.Query.filter(
        StatefulAlertRuleState,
        expr(is_nil(last_seen_at) or last_seen_at < ^cutoff)
      )

    case Ash.read(query, actor: actor) do
      {:ok, %Ash.Page.Keyset{results: results}} ->
        destroy_states(results, actor)

      {:ok, results} when is_list(results) ->
        destroy_states(results, actor)

      {:error, reason} ->
        Logger.warning("Failed to load stale rule state",
          reason: inspect(reason)
        )

        0
    end
  end

  defp destroy_states(states, actor) do
    Enum.reduce(states, 0, fn state, count ->
      case Ash.destroy(state, actor: actor) do
        {:ok, _} ->
          count + 1

        {:error, reason} ->
          Logger.warning("Failed to delete stale rule state",
            reason: inspect(reason)
          )

          count
      end
    end)
  end
end
