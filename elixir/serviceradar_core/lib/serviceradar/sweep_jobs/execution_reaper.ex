defmodule ServiceRadar.SweepJobs.ExecutionReaper do
  @moduledoc """
  Fails sweep executions that stay `:running` after their agent stopped reporting.

  An execution leaves `:running` only when its agent reports the last result
  chunk, when the same agent starts a newer run of the same group (the
  results ingestor marks the older one "superseded by new execution"), or when
  an operator cancels it from the running-scans panel. A group
  disabled mid-scan, or an agent that dies or stops reporting, leaves neither,
  so the row stays `:running` forever and the running-scans views keep listing
  it with an ever-growing duration.

  Every result chunk the ingestor writes bumps `updated_at`, so `updated_at` is
  the execution's progress heartbeat. A running execution is abandoned when:

    * its sweep group is disabled and it has made no progress for
      `disabled_grace_seconds` (agents still in flight may deliver a last chunk
      just after the config change), or
    * it has made no progress for the group's bound: three times the group's
      interval, clamped to `[min_stale_seconds, max_stale_seconds]`. A
      cron-scheduled group has no interval to scale by, so it uses
      `max_stale_seconds`: a running scan reports a chunk well within that.

  Each failure goes through the execution's `:fail` action with a
  compare-and-set filter on `status` and `updated_at`, so an execution that
  reported progress between the read and the update is left alone.
  """

  import Ash.Expr
  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepGroupExecution
  alias ServiceRadar.SweepJobs.SweepMonitorWorker

  require Logger

  @actor_component :sweep_execution_reaper
  @default_batch_size 200
  @default_disabled_grace_seconds 600
  @default_min_stale_seconds 1_800
  @default_max_stale_seconds 21_600
  @interval_multiplier 3

  @type result :: %{
          failed: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer()
        }

  @spec reap(keyword()) :: {:ok, result()} | {:error, term()}
  def reap(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    actor = Keyword.get(opts, :actor, SystemActor.system(@actor_component))
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    lister = Keyword.get(opts, :lister, &list_running/1)

    bounds = %{
      disabled_grace: Keyword.get(opts, :disabled_grace_seconds, @default_disabled_grace_seconds),
      min_stale: Keyword.get(opts, :min_stale_seconds, @default_min_stale_seconds),
      max_stale: Keyword.get(opts, :max_stale_seconds, @default_max_stale_seconds)
    }

    with {:ok, candidates} <- lister.(batch_size) do
      result =
        Enum.reduce(candidates, %{failed: 0, skipped: 0, errors: 0}, fn candidate, acc ->
          case abandon_reason(candidate, now, bounds) do
            nil -> acc
            reason -> candidate |> fail(reason, actor) |> tally(candidate, acc)
          end
        end)

      {:ok, result}
    end
  end

  @doc false
  @spec abandon_reason(map(), DateTime.t(), map()) :: String.t() | nil
  def abandon_reason(%{updated_at: updated_at} = candidate, now, bounds) do
    idle_seconds = DateTime.diff(now, updated_at, :second)

    cond do
      candidate.group_enabled == false and idle_seconds >= bounds.disabled_grace ->
        "abandoned: sweep group disabled"

      idle_seconds >= stale_bound_seconds(candidate, bounds) ->
        "abandoned: no progress since #{DateTime.to_iso8601(updated_at)}"

      true ->
        nil
    end
  end

  defp stale_bound_seconds(%{schedule_type: type}, bounds) when type in [:cron, "cron"],
    do: bounds.max_stale

  defp stale_bound_seconds(candidate, bounds) do
    (@interval_multiplier * SweepMonitorWorker.parse_interval_to_seconds(candidate.interval))
    |> max(bounds.min_stale)
    |> min(bounds.max_stale)
  end

  # Oldest heartbeat first, so a large backlog drains in the order it went quiet.
  defp list_running(batch_size) do
    candidates =
      Repo.all(
        from(e in SweepGroupExecution,
          join: g in SweepGroup,
          on: g.id == e.sweep_group_id,
          where: e.status == :running,
          order_by: [asc: e.updated_at],
          limit: ^batch_size,
          select: %{
            id: e.id,
            updated_at: e.updated_at,
            group_enabled: g.enabled,
            interval: g.interval,
            schedule_type: g.schedule_type
          }
        )
      )

    {:ok, candidates}
  end

  defp fail(candidate, reason, actor) do
    seen_updated_at = candidate.updated_at

    with_result =
      with {:ok, execution} <- Ash.get(SweepGroupExecution, candidate.id, actor: actor) do
        execution
        |> Ash.Changeset.for_update(:fail, %{error_message: reason}, actor: actor)
        |> Ash.Changeset.filter(expr(status == :running and updated_at == ^seen_updated_at))
        |> Ash.update()
      end

    case with_result do
      {:ok, updated} ->
        {:ok, updated}

      {:error, %Ash.Error.Invalid{errors: errors} = error} ->
        if Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)),
          do: {:skip, :progressed_or_changed},
          else: {:error, error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tally({:ok, _execution}, _candidate, acc), do: Map.update!(acc, :failed, &(&1 + 1))
  defp tally({:skip, _reason}, _candidate, acc), do: Map.update!(acc, :skipped, &(&1 + 1))

  defp tally({:error, reason}, candidate, acc) do
    Logger.warning("Sweep execution reaper failed to close execution",
      sweep_group_execution_id: candidate.id,
      reason: inspect(reason)
    )

    Map.update!(acc, :errors, &(&1 + 1))
  end
end
