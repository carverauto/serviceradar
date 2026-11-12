defmodule ServiceRadar.Inventory.ExposureSnapshotPublisherWorker do
  @moduledoc """
  Drains pending exposure snapshot scopes, one serial generation at a time.

  Replaces the per-device `ExposureSnapshotWorker` Oban fan-out, whose waiting
  jobs returned `{:snooze, 5}` millions of times against one deployment-wide
  serial lock. One execution takes the session lock once, adopts orphaned
  scopes, publishes due scopes oldest-first through the
  `ExposureSnapshotWorker` engine, and exits when the table is quiet. No
  `{:snooze, _}` on this path: blocking states become bounded in-execution
  waits, and anything still blocked is picked up through the demand ensures
  (including the maintenance backstop) on a later pass.

  Uniqueness covers available/scheduled only: an executing row left by a
  crashed run never blocks the next ensure. The session advisory lock is the
  serializing mutex — a run that finds it held exits quietly because the
  running drain already covers the table.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 20,
    unique: [period: :infinity, fields: [:worker], states: [:available, :scheduled]]

  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.Inventory.ExposurePublicationPrepareWorker
  alias ServiceRadar.Inventory.ExposureSnapshotScopes, as: Scopes
  alias ServiceRadar.Inventory.ExposureSnapshotState, as: State
  alias ServiceRadar.Inventory.ExposureSnapshotWorker, as: Engine
  alias ServiceRadar.Repo.DirectSession

  @lock_namespace 74_526
  @wait_check_ms 5_000
  @default_completion_budget_ms 600_000
  @default_pipeline_budget_ms 300_000

  @impl Oban.Worker
  def perform(%Oban.Job{id: id}) do
    if Destination.enabled?() do
      DirectSession.run(fn session ->
        case Postgrex.query!(session, "SELECT pg_try_advisory_lock($1, 0)", [@lock_namespace]).rows do
          [[false]] ->
            :ok

          [[true]] ->
            with :ok <- adopt_orphans() do
              drain(session, id, 0)
            end
        end
      end)
    else
      :ok
    end
  end

  defp adopt_orphans do
    Enum.reduce_while(Scopes.expired_publishing(), :ok, fn [id, scope, generation_id], :ok ->
      case adopt(id, scope, generation_id) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp adopt(id, _scope, nil), do: Scopes.requeue(id)

  defp adopt(id, _scope, generation_id) do
    case State.get(generation_id) do
      {:ok, %{"status" => "complete"}} ->
        Scopes.complete(id, generation_id)

      {:ok, %{"status" => "aborted"}} ->
        Scopes.requeue(id)

      {:ok, %{"status" => "publishing", "owner" => owner}} ->
        # Holding the session lock proves the recorded reader is gone, the
        # same proof the old per-scope jobs used before publishing.
        case State.abort(generation_id, owner, :reader_lost) do
          {:ok, :ok} -> Scopes.requeue(id)
          {:error, _} -> Scopes.requeue(id)
        end

      {:ok, _} ->
        # Published or finalizing: owned by the maintenance/finalizer
        # pipeline, not a stuck reader. Leave it; the backstop re-ensures
        # until its completion marks the scope complete.
        :ok

      {:error, _} ->
        Scopes.requeue(id)
    end
  end

  defp drain(session, job_id, completed) do
    case Scopes.claim(job_id) do
      :none ->
        emit_drained(completed)
        :ok

      {:ok, %{id: id, scope_ord: scope}} ->
        case drive_scope(session, id, scope) do
          :ok -> drain(session, job_id, completed + 1)
          {:exit, reason} -> exit_drain(completed, reason)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp exit_drain(completed, :quiet) do
    emit_drained(completed)
    :ok
  end

  defp exit_drain(completed, {:error, reason}) do
    emit_drained(completed)
    {:error, reason}
  end

  defp emit_drained(completed) do
    :telemetry.execute(
      [:serviceradar, :exposure, :snapshot, :publisher_drained],
      %{scopes: completed},
      %{}
    )
  end

  defp drive_scope(session, id, scope), do: drive_scope(session, id, scope, 0)

  defp drive_scope(session, id, scope, waits) do
    case Engine.publish_scope(session, scope) do
      {:ok, generation_id} ->
        Scopes.track_generation(id, generation_id)
        await_completion(id, generation_id)

      {:defer, :preparing} ->
        with :ok <- Scopes.defer_preparing(id),
             {:ok, _} <- %{} |> ExposurePublicationPrepareWorker.new() |> Oban.insert() do
          :ok
        end

      {:defer, :wait} when waits < 3 ->
        case wait_while(&pipeline_busy?/0, pipeline_budget_ms()) do
          :ok ->
            drive_scope(session, id, scope, waits + 1)

          :timeout ->
            Scopes.release(id)
            {:exit, :quiet}
        end

      {:defer, :wait} ->
        Scopes.release(id)
        {:exit, :quiet}

      {:error, reason} ->
        case Scopes.fail(id, reason) do
          :ok -> :ok
          {:failed, _} -> :ok
          {:dead, _} -> :ok
          {:error, error} -> {:exit, {:error, error}}
        end
    end
  end

  defp await_completion(id, generation_id) do
    case wait_while(fn -> not generation_settled?(generation_id) end, completion_budget_ms()) do
      :ok ->
        case State.get(generation_id) do
          {:ok, %{"status" => "complete"}} -> Scopes.complete(id, generation_id)
          _ -> Scopes.fail(id, :exposure_snapshot_generation_aborted)
        end

        :ok

      :timeout ->
        Scopes.release(id)
        {:exit, :quiet}
    end
  end

  defp generation_settled?(generation_id) do
    case State.get(generation_id) do
      {:ok, %{"status" => status}} -> status in ["complete", "aborted"]
      _ -> false
    end
  end

  defp pipeline_busy? do
    case State.active() do
      :none -> not settled_lanes?()
      {:ok, _} -> true
    end
  end

  defp settled_lanes? do
    not State.unsettled?()
  end

  # Budgets follow the `:exposure_snapshot_timeout_ms` precedent: application
  # config with production defaults, so a stuck pipeline bounds one pass.
  defp completion_budget_ms do
    Application.get_env(
      :serviceradar_core,
      :exposure_publisher_completion_budget_ms,
      @default_completion_budget_ms
    )
  end

  defp pipeline_budget_ms do
    Application.get_env(
      :serviceradar_core,
      :exposure_publisher_pipeline_budget_ms,
      @default_pipeline_budget_ms
    )
  end

  defp wait_while(fun, budget_ms),
    do: wait_while(fun, budget_ms, System.monotonic_time(:millisecond))

  defp wait_while(fun, budget_ms, started) do
    cond do
      not fun.() ->
        :ok

      System.monotonic_time(:millisecond) - started >= budget_ms ->
        :timeout

      true ->
        Process.sleep(@wait_check_ms)
        wait_while(fun, budget_ms, started)
    end
  end
end
