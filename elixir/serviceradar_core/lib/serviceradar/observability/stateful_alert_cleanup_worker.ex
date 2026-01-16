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

  use ServiceRadar.Oban.TenantWorker,
    queue_type: :maintenance,
    max_attempts: 3,
    unique: [period: 3600, states: [:available, :scheduled, :executing, :retryable]]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.StatefulAlertRuleState
  alias ServiceRadar.Repo

  import Ash.Expr
  import Ecto.Query, only: [from: 2]

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
    case check_existing_job() do
      true ->
        {:ok, :already_scheduled}

      false ->
        enqueue(%{})
    end
  end

  defp check_existing_job do
    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    Repo.exists?(query)
  end

  @impl ServiceRadar.Oban.TenantWorker
  @spec perform_job(map(), Oban.Job.t()) ::
          :ok | {:ok, term()} | {:error, term()} | {:cancel, term()} | {:snooze, pos_integer()}
  def perform_job(_args, _job) do
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
    enqueue_in(%{}, @reschedule_interval_seconds)
  end

  defp cleanup_stale_states(cutoff) do
    actor = SystemActor.system(:alert_cleanup)

    query =
      StatefulAlertRuleState
      |> Ash.Query.filter(expr(is_nil(last_seen_at) or last_seen_at < ^cutoff))

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
