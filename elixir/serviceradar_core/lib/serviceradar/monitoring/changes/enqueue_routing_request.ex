defmodule ServiceRadar.Monitoring.Changes.EnqueueRoutingRequest do
  @moduledoc """
  Enqueues one `ServiceRadar.Notifications.RoutingWorker` job for the alert the
  action just wrote.

  This is the whole of an alert action's involvement in notification. It decides
  nothing: routing, deduplication, escalation, suppression, rendering, and the
  retry rule all belong to `ServiceRadar.Notifications.Dispatcher` and the pure
  cores behind it. Delivering inline would put a transport call inside the
  alert's own transaction, on a path that is already latency-sensitive, and hand
  the send a second retry budget that no operator configured.

  ## Why the hook, and why it may fail the action

  The job is inserted from an `after_action` hook, so it goes in **inside the
  action's transaction**: either the alert records the notification and the
  routing request exists, or neither happened.

  That coupling is the point rather than a side effect. `Alert.:send_notification`
  increments `notification_count`, and `Alert.:needs_notification` selects on
  `notification_count == 0`. If the counter were committed while the enqueue
  failed, the alert would leave the scan that is supposed to notice it and never
  be notified by anything - a silent drop, which design D5 forbids. So an
  enqueue failure propagates, the update rolls back, and the AshOban trigger
  finds the alert again on the next tick.

  Callers that must NOT be coupled that way - `AlertLifecycle`, where a
  notification problem may never break incident recording - call
  `RoutingWorker.enqueue/3` directly outside the write instead of using this
  change.

  ## Options

    * `:lifecycle_reason` (required) - one of `RoutingWorker.lifecycle_reasons/0`,
      validated in `init/1`. Half of `Dedupe.routing_request_key/1`, so a
      reason the worker does not know is not a cosmetic mismatch: the job is
      cancelled on arrival and the alert is never routed.
    * `:enqueue` - a two-argument function replacing `RoutingWorker.enqueue/2`.
      The seam that lets the hook be asserted without a queue or a database.

  ## Why `atomic/3` re-registers the hook instead of returning `:ok`

  An atomic update does not execute the changeset `change/3` was given. Ash
  builds a **second** changeset in `Ash.Changeset.fully_atomic_changeset/4` and
  runs it, carrying over only the hooks in `atomic_after_action` - and a hook
  registered from `change/3` never lands there, because
  `Ash.Changeset.after_action/3` only populates that list while the changeset is
  in the `:pending` phase and changes run in the `:validate` phase.

  So a change that registers its hook in `change/3` and answers `:ok` from
  `atomic/3` compiles, passes `require_atomic?`, updates the row - and never
  runs its hook. Nothing reports it. Here that would have been an alert whose
  `notification_count` said it had been notified and for which no routing
  request was ever enqueued.

  `atomic/3` therefore registers the hook on the changeset it is handed, which
  IS the changeset that will run. `change/3` covers the non-atomic path, and
  exactly one of the two applies per execution.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Notifications.RoutingWorker

  @impl true
  def init(opts) do
    reason = Keyword.get(opts, :lifecycle_reason)
    known = Map.values(RoutingWorker.lifecycle_reasons())

    if reason in known do
      {:ok, opts}
    else
      raise ArgumentError,
            "#{inspect(__MODULE__)} requires a :lifecycle_reason in #{inspect(known)}, " <>
              "got: #{inspect(reason)}"
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    reason = Keyword.fetch!(opts, :lifecycle_reason)
    enqueue = Keyword.get(opts, :enqueue, &RoutingWorker.enqueue/2)

    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      enqueue_for(record, reason, enqueue)
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp enqueue_for(%{id: alert_id} = record, reason, enqueue) when is_binary(alert_id) do
    case enqueue.(alert_id, reason) do
      {:ok, _job} ->
        {:ok, record}

      {:error, error} ->
        {:error,
         "could not enqueue the #{reason} notification routing request for alert " <>
           "#{alert_id}: #{inspect(error)}"}
    end
  end

  defp enqueue_for(record, _reason, _enqueue) do
    {:error,
     "cannot enqueue a notification routing request without an alert id: #{inspect(record)}"}
  end
end
