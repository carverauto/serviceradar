defmodule ServiceRadar.Ash.NotificationQueue do
  @moduledoc """
  Sends Ash notifications and runs deferred side effects after the transaction
  that produced them commits.

  An Ash action run inside a plain `Repo.transaction` cannot send its own
  notifications: Ash holds them back, logs `Missed N notifications in action
  ...`, and drops them, so no notifier sees the write. Such an action runs with
  `return_notifications?: true` and passes the notifications to
  `notify_after_commit/1`. Direct PubSub broadcasts, cache invalidations, and
  NATS publishes inside the transaction pass a zero-arity callback to
  `after_commit/1`. The code that opens the transaction wraps it in
  `with_queue/1`, which flushes the queued notifications and side effects once
  the transaction has committed and drops them when it rolls back.
  """

  alias Ash.Actions.Helpers
  alias Ash.Notifier.Notification
  alias ServiceRadar.Inventory.Device

  require Logger

  @pending {__MODULE__, :pending}

  defmodule EffectNotifier do
    @moduledoc false
    use Ash.Notifier

    @impl Ash.Notifier
    def notify(%Notification{metadata: %{effect: effect}}) when is_function(effect, 0) do
      _ = effect.()
      :ok
    end
  end

  @doc """
  Whether the current process has an open `with_queue/1` scope.
  """
  @spec queuing?() :: boolean()
  def queuing?, do: not is_nil(Process.get(@pending))

  @doc """
  Sends `notifications` once the outermost queue commits, and drops them if
  that transaction rolls back. A call nested in an open queue appends to it, so
  a savepoint commit does not send before the outermost transaction commits.
  With no queue open, sends them now, or hands them to an enclosing Ash
  transaction, which sends them once it commits.
  """
  @spec notify_after_commit([Notification.t()]) :: :ok
  def notify_after_commit(notifications) when is_list(notifications) do
    case Process.get(@pending) do
      nil -> send_now(notifications)
      pending -> Process.put(@pending, [{:notifications, notifications} | pending])
    end

    :ok
  end

  @doc """
  Runs `effect` once the outermost queue commits, and drops it if that
  transaction rolls back. A call nested in an open queue appends to it, so a
  savepoint commit does not run the effect before the outermost transaction
  commits. With no queue open, runs it now, or hands it to an enclosing Ash
  transaction, which runs it once that transaction commits.
  """
  @spec after_commit((-> term())) :: :ok
  def after_commit(effect) when is_function(effect, 0) do
    case Process.get(@pending) do
      nil -> run_effect(effect)
      pending -> Process.put(@pending, [{:effect, effect} | pending])
    end

    :ok
  end

  @doc """
  Owns the notification queue around one transaction result.

  The outermost call sends what `notify_after_commit/1` and `after_commit/1`
  queued only when `work` returns `{:ok, _}`. Any other result, a rollback
  included, drops the queue. A call nested inside an open queue leaves sending
  to that outer owner; one nested inside an Ash transaction hands its queue to
  that transaction.
  """
  @spec with_queue((-> result)) :: result when result: term()
  def with_queue(work) when is_function(work, 0) do
    if Process.get(@pending) do
      work.()
    else
      Process.put(@pending, [])

      try do
        result = work.()
        pending = Process.delete(@pending)

        if match?({:ok, _}, result) do
          flush(pending)
        end

        result
      after
        Process.delete(@pending)
      end
    end
  end

  defp flush(pending) when is_list(pending) do
    pending
    |> Enum.reverse()
    |> Enum.chunk_by(&elem(&1, 0))
    |> Enum.each(fn
      [{:notifications, _} | _] = chunk ->
        chunk
        |> Enum.flat_map(fn {:notifications, notifications} -> notifications end)
        |> send_now()

      [{:effect, _} | _] = chunk ->
        Enum.each(chunk, fn {:effect, effect} -> run_effect(effect) end)
    end)
  end

  defp run_effect(effect) do
    if Process.get(:ash_started_transaction?) do
      Helpers.queue_notifications([
        %Notification{
          resource: Device,
          domain: ServiceRadar.Inventory,
          for: [EffectNotifier],
          metadata: %{effect: effect}
        }
      ])
    else
      _ = effect.()
      :ok
    end
  end

  # Ash.Notifier.notify/1 returns, unsent, any notification whose resource is
  # still inside a transaction. An enclosing Ash transaction sends its own queue
  # once it commits and drops it on rollback, so the notification joins that
  # queue. Otherwise nothing owns the transaction: say so instead of dropping it
  # silently.
  defp send_now(notifications) do
    case Ash.Notifier.notify(notifications) do
      [] ->
        :ok

      unsent ->
        if Process.get(:ash_started_transaction?) do
          Helpers.queue_notifications(unsent)
        else
          Logger.warning(
            "NotificationQueue: dropped #{length(unsent)} notification(s) sent inside a " <>
              "transaction no queue owns: " <> describe(unsent)
          )
        end
    end
  end

  defp describe(notifications) do
    notifications
    |> Enum.map(fn notification ->
      "#{inspect(notification.resource)}.#{action_name(notification.action)}"
    end)
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  defp action_name(%{name: name}), do: name
  defp action_name(_action), do: "unknown"
end
