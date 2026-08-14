defmodule ServiceRadar.Repo.Migrations.AddLifecycleReasonToNotificationDeliveries do
  @moduledoc """
  Carries the routing lifecycle reason onto the delivery row (task 4.3.3b).

  ## The bug this exists to fix

  `Dispatcher.route/3` knows why it is routing - `:fire`, `:renotify`,
  `:escalate`, `:resolve` - and that knowledge stopped at routing. Nothing put it
  on the delivery, so nothing had it at render time, so every rendered
  notification was a trigger.

  For an incident API that is not cosmetic. The PagerDuty document sends
  `event_action` alongside a `dedup_key` of the alert id, so a ServiceRadar alert
  RESOLVING sent PagerDuty a trigger on the key of the incident it should have
  closed: the incident was updated and stayed open until a human closed it by
  hand.

  It cannot be fixed in the template. Templates are restricted substitution with
  no conditionals, so `:renotify -> "trigger"` and `:resolve -> "resolve"` cannot
  be written as a document expression and have to be derived from a value the
  renderer can see. This column is that value.

  ## Nullable on purpose

  Existing rows predate the concept and there is no honest value to backfill:
  guessing `fire` would assert something about deliveries nobody recorded. A null
  reason renders as `trigger`, which is what those rows already did.

  Note: this migration is hand-written, matching the rest of this tree.
  `priv/resource_snapshots/` is gitignored, so `mix ash.codegen` emits a
  whole-application migration rather than a scoped one.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    alter table(:notification_deliveries, prefix: @prefix) do
      add(:lifecycle_reason, :text)
    end

    # A closed set at the database level as well as in the resource. The value
    # decides what an incident API is told to do, so a typo here is an incident
    # that never closes.
    create(
      constraint(:notification_deliveries, :notification_deliveries_lifecycle_reason,
        check:
          "lifecycle_reason IS NULL OR lifecycle_reason IN ('fire','renotify','escalate','resolve')",
        prefix: @prefix
      )
    )
  end

  def down do
    drop_if_exists(
      constraint(:notification_deliveries, :notification_deliveries_lifecycle_reason,
        prefix: @prefix
      )
    )

    alter table(:notification_deliveries, prefix: @prefix) do
      remove(:lifecycle_reason)
    end
  end
end
