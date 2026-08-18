defmodule ServiceRadar.Repo.Migrations.AddAlertSnoozeAndAckUser do
  @moduledoc """
  Adds notification-platform lifecycle columns to `platform.alerts`.

  `snooze_until` backs a plain `update :snooze` action rather than a
  state-machine state. The machine's `state_attribute` is `:status` with states
  pending/acknowledged/resolved/escalated/suppressed, and there is no state a
  `:snooze` transition could target. Adding one would force an audit of every
  existing `status` renderer, filter, and read action for the new value, whereas
  a timestamp keeps snooze-expiry resumption a pure comparison:
  `status in [:pending, :escalated] and snooze_until > now()`.

  `acknowledged_by_user_id` is a real foreign key alongside the retained
  free-text `acknowledged_by`, which stays for external principals (a chat or
  paging identity that does not map to a platform user).
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    alter table(:alerts, prefix: @prefix) do
      add(:snooze_until, :utc_datetime_usec)

      add(
        :acknowledged_by_user_id,
        references(:ng_users, type: :uuid, on_delete: :nilify_all, prefix: @prefix)
      )
    end

    # Drives the first-notify scan's snooze exclusion and the snooze-expiry sweeper.
    create(
      index(:alerts, [:snooze_until],
        name: :alerts_snooze_until_idx,
        prefix: @prefix,
        where: "snooze_until IS NOT NULL"
      )
    )

    create(
      index(:alerts, [:acknowledged_by_user_id],
        prefix: @prefix,
        where: "acknowledged_by_user_id IS NOT NULL"
      )
    )
  end

  def down do
    drop_if_exists(index(:alerts, [:acknowledged_by_user_id], prefix: @prefix))

    drop_if_exists(
      index(:alerts, [:snooze_until], name: :alerts_snooze_until_idx, prefix: @prefix)
    )

    alter table(:alerts, prefix: @prefix) do
      remove(:acknowledged_by_user_id)
      remove(:snooze_until)
    end
  end
end
