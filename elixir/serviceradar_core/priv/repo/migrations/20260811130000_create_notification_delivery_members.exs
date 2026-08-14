defmodule ServiceRadar.Repo.Migrations.CreateNotificationDeliveryMembers do
  @moduledoc """
  Adds durable alert membership for grouped notification deliveries.

  The delivery row keeps a bounded aggregate snapshot for rendering. This table
  keeps every member identity and source due time so grouped alerts cannot be
  replanned independently and any member can close the shared provider page.
  `alert_id` intentionally has no foreign key because alert retention is shorter
  than notification delivery retention.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:notification_delivery_members, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :delivery_id,
        references(:notification_deliveries,
          type: :uuid,
          on_delete: :delete_all,
          prefix: @prefix
        ),
        null: false
      )

      # Deliberately not a reference to alerts: delivery history outlives the
      # source alert and must retain its member identity after retention.
      add(:alert_id, :uuid, null: false)
      add(:source_due_at, :utc_datetime_usec, null: false)
      add(:alert_snapshot, :map, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      unique_index(
        :notification_delivery_members,
        [:delivery_id, :alert_id, :source_due_at],
        name: :notification_delivery_members_identity_uidx,
        prefix: @prefix
      )
    )

    create(
      index(:notification_delivery_members, [:alert_id, :source_due_at],
        name: :notification_delivery_members_alert_due_idx,
        prefix: @prefix
      )
    )

    # This change has not shipped yet, but backfill any rows created during a
    # rolling upgrade so singleton deliveries retain their historical identity.
    execute("""
    INSERT INTO #{@prefix}.notification_delivery_members
      (id, delivery_id, alert_id, source_due_at, alert_snapshot, inserted_at, updated_at)
    SELECT uuid_generate_v7(), id, alert_id, COALESCE(queued_at, inserted_at),
           alert_snapshot, now(), now()
      FROM #{@prefix}.notification_deliveries
     WHERE alert_id IS NOT NULL
       AND is_test = false
       AND alert_snapshot <> '{}'::jsonb
    ON CONFLICT (delivery_id, alert_id, source_due_at) DO NOTHING
    """)
  end

  def down do
    drop(table(:notification_delivery_members, prefix: @prefix))
  end
end
