defmodule ServiceRadar.Monitoring.Changes.RecordNotificationSent do
  @moduledoc """
  Records that an alert has been handed to the notification platform:
  `notification_count + 1` and `last_notification_at = now()`.

  Both are expressed as atomic updates and nothing else, which is what lets
  `Alert.:send_notification` and `Alert.:record_notification` drop
  `require_atomic? false`. The increment they used to perform read
  `changeset.data.notification_count` in Elixir and wrote back `current + 1`, so
  two concurrent notifications for the same alert - the AshOban scheduler tick
  and an `AlertLifecycle` renotify landing together - could both read 0 and both
  write 1.

  That counter is not decorative. `Alert.:needs_notification` filters on
  `notification_count == 0`, so it is the flag that stops the scheduler
  originating a second first-notification. A lost increment re-arms it.

  The increment is nil-safe. The attribute defaults to 0 and every write goes
  through here, but `notification_count + 1` is `NULL` for a `NULL` row in SQL,
  and a `NULL` count silently drops back out of `notification_count == 0` - the
  alert would then never notify and never be seen again by the scan that exists
  to catch exactly that.

  Deliberately no `change/3`: the atomic expression is the only definition, so
  there is no second Elixir-side increment that could drift from it.
  """

  use Ash.Resource.Change

  import Ash.Expr

  @impl true
  def atomic(_changeset, _opts, _context) do
    {:atomic,
     %{
       notification_count:
         expr(
           if is_nil(^atomic_ref(:notification_count)) do
             1
           else
             ^atomic_ref(:notification_count) + 1
           end
         ),
       last_notification_at: expr(now())
     }}
  end
end
