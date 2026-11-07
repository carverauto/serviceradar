defmodule ServiceRadar.Ash.NotificationQueue do
  @moduledoc """
  Sends Ash notifications after the transaction that produced them commits.

  An Ash action run inside a plain `Repo.transaction` cannot send its own
  notifications: Ash holds them back, logs `Missed N notifications in action
  ...`, and drops them, so no notifier sees the write. Such an action runs with
  `return_notifications?: true` and passes the notifications to
  `notify_after_commit/1`. The code that opens the transaction wraps it in
  `with_queue/1`, which sends the queued notifications once the transaction has
  committed and drops them when it rolls back.
  """

  require Logger

  @pending {__MODULE__, :pending}

  @doc """
  Sends `notifications` once the outermost queue commits, and drops them if
  that transaction rolls back. A call nested in an open queue appends to it, so
  a savepoint commit does not send before the outermost transaction commits.
  With no queue open, sends them now.
  """
  @spec notify_after_commit([Ash.Notifier.Notification.t()]) :: :ok
  def notify_after_commit(notifications) when is_list(notifications) do
    case Process.get(@pending) do
      nil -> send_now(notifications)
      pending -> Process.put(@pending, [notifications | pending])
    end

    :ok
  end

  @doc """
  Owns the notification queue around one transaction result.

  The outermost call sends what `notify_after_commit/1` queued only when `work`
  returns `{:ok, _}`. Any other result, a rollback included, drops the queue. A
  call nested inside an open queue leaves sending to that outer owner.
  """
  @spec with_queue((-> result)) :: result when result: term()
  def with_queue(work) when is_function(work, 0) do
    if Process.get(@pending) do
      work.()
    else
      Process.put(@pending, [])

      try do
        result = work.()
        pending = Process.get(@pending)

        if match?({:ok, _}, result) do
          pending |> Enum.reverse() |> List.flatten() |> send_now()
        end

        result
      after
        Process.delete(@pending)
      end
    end
  end

  # Ash.Notifier.notify/1 returns, unsent, any notification whose resource is
  # still inside a transaction: one that no queue owns. Say so instead of
  # dropping it silently, as Ash would for the action itself.
  defp send_now(notifications) do
    case Ash.Notifier.notify(notifications) do
      [] ->
        :ok

      unsent ->
        Logger.warning(
          "NotificationQueue: dropped #{length(unsent)} notification(s) sent inside a " <>
            "transaction no queue owns: " <> describe(unsent)
        )
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
