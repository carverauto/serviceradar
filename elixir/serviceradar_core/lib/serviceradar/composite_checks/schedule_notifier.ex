defmodule ServiceRadar.CompositeChecks.ScheduleNotifier do
  @moduledoc """
  Keeps a composite check's periodic evaluation schedule in step with its state.

  Enabling schedules the pass; disabling, drafting, or deleting cancels it.

  This is a notifier rather than an `after_action` change on purpose. Ash runs
  updates atomically by default, and a built-in `after_action` change does not
  implement `atomic/3`, so attaching one forces the whole action non-atomic
  (`require_atomic? false`) just to hang a side effect off it. A notifier runs
  after the transaction commits, receives the record, and leaves the action
  atomic.

  Scheduling failures are swallowed: a check must stay saveable when Oban is
  down, matching the contract sweep groups already have. Surfacing "scheduling
  is deferred" to the operator is the UI's job.
  """

  use Ash.Notifier

  alias Ash.Notifier.Notification
  alias ServiceRadar.CompositeChecks.EvaluationWorker

  require Logger

  # Patterns here match plain maps rather than %CompositeCheck{} on purpose.
  # A struct pattern is a compile-time dependency, and CompositeCheck already
  # depends on this notifier, so matching the struct closes a compile cycle
  # (CompositeCheck -> ScheduleNotifier -> EvaluationWorker -> CompositeCheck)
  # and deadlocks the build.
  @impl Ash.Notifier
  def notify(%Notification{action: %{type: :destroy}, data: %{id: id}}) do
    EvaluationWorker.cancel(id)
    :ok
  end

  def notify(%Notification{data: %{state: :enabled, id: id} = check}) do
    case EvaluationWorker.ensure_scheduled(check) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.debug("composite check schedule deferred",
          check_id: id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  def notify(%Notification{data: %{id: id}}) do
    EvaluationWorker.cancel(id)
    :ok
  end

  def notify(_notification), do: :ok
end
