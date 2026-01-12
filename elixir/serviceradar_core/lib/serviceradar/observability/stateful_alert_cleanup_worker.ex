defmodule ServiceRadar.Observability.StatefulAlertCleanupWorker do
  @moduledoc """
  Tenant-scoped worker that cleans up stale stateful alert rule snapshots.

  This worker runs daily for each tenant to delete StatefulAlertRuleState records
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
    unique: [period: 3600, keys: [:tenant_id], states: [:available, :scheduled, :executing, :retryable]]

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
  Schedules alert state cleanup for a tenant if not already scheduled.

  Called automatically when stateful alert rules are created or enabled.
  """
  @spec ensure_scheduled(String.t()) :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled(tenant_id) when is_binary(tenant_id) do
    case check_existing_job(tenant_id) do
      true ->
        {:ok, :already_scheduled}

      false ->
        enqueue(tenant_id, %{})
    end
  end

  defp check_existing_job(tenant_id) do
    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        where: fragment("? ->> 'tenant_id' = ?", j.meta, ^tenant_id),
        limit: 1
      )

    Repo.exists?(query)
  end

  @impl ServiceRadar.Oban.TenantWorker
  @spec perform_for_tenant(map(), String.t(), Oban.Job.t()) ::
          :ok | {:ok, term()} | {:error, term()} | {:cancel, term()} | {:snooze, pos_integer()}
  def perform_for_tenant(_args, tenant_id, _job) do
    cutoff = DateTime.add(DateTime.utc_now(), -@stale_after_days * 86_400, :second)

    Logger.info("StatefulAlertCleanupWorker: Starting cleanup",
      tenant_id: tenant_id,
      cutoff: cutoff
    )

    count = cleanup_tenant(tenant_id, cutoff)

    Logger.info("StatefulAlertCleanupWorker: Completed",
      tenant_id: tenant_id,
      deleted: count
    )

    # Reschedule for tomorrow
    schedule_next_cleanup(tenant_id)

    :ok
  end

  defp schedule_next_cleanup(tenant_id) do
    enqueue_in(tenant_id, %{}, @reschedule_interval_seconds)
  end

  defp cleanup_tenant(tenant_id, cutoff) do
    actor = SystemActor.for_tenant(tenant_id, :alert_cleanup)

    query =
      StatefulAlertRuleState
      |> Ash.Query.filter(expr(is_nil(last_seen_at) or last_seen_at < ^cutoff))

    case Ash.read(query, tenant: tenant_id, actor: actor) do
      {:ok, %Ash.Page.Keyset{results: results}} ->
        destroy_states(results, tenant_id, actor)

      {:ok, results} when is_list(results) ->
        destroy_states(results, tenant_id, actor)

      {:error, reason} ->
        Logger.warning("Failed to load stale rule state",
          tenant_id: tenant_id,
          reason: inspect(reason)
        )

        0
    end
  end

  defp destroy_states(states, tenant_id, actor) do
    Enum.reduce(states, 0, fn state, count ->
      case Ash.destroy(state, tenant: tenant_id, actor: actor) do
        {:ok, _} ->
          count + 1

        {:error, reason} ->
          Logger.warning("Failed to delete stale rule state",
            tenant_id: tenant_id,
            reason: inspect(reason)
          )

          count
      end
    end)
  end
end
