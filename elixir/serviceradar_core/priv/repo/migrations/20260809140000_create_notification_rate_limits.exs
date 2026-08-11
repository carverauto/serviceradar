defmodule ServiceRadar.Repo.Migrations.CreateNotificationRateLimits do
  @moduledoc """
  Creates the durable per-channel send budget backing
  `ServiceRadar.Notifications.RateLimiter`.

  The design's Risks table requires that `rate_limit_per_minute` be enforced
  "against a durable counter, not in-memory GenServer state as `WebhookNotifier`
  does". This table is that counter: one row per channel holding the current
  fixed window and how much of it has been consumed. A restart, a rolling
  deploy, a second core replica, and an Oban retry all read the same row, which
  is exactly what in-memory state could not do.

  One row per channel rather than one row per send: a per-send ledger grows
  without bound and needs its own retention, while the budget question - "how
  many sends have gone out in the current minute?" - is answered by a counter.
  The window rolls forward in the same statement that consumes from it, so no
  sweeper is required and an idle channel costs one stale row.

  `channel_id` carries `on_delete: :delete_all`: the budget is meaningless once
  the destination it protects is gone.

  Note: this migration is hand-written, matching
  `20260809120000_create_notification_platform_tables.exs`.
  `priv/resource_snapshots/` was removed in 607b40f584 and every migration in
  this tree is authored by hand, so `mix ash.codegen` would emit a
  whole-application migration rather than a scoped one.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:notification_channel_rate_limits, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :channel_id,
        references(:notification_channels,
          type: :uuid,
          on_delete: :delete_all,
          prefix: @prefix
        ),
        null: false
      )

      add(:window_started_at, :utc_datetime_usec, null: false)
      add(:consumed, :integer, null: false, default: 0)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    # The conflict target for the consume statement's atomic upsert. Without a
    # unique index the ON CONFLICT clause has nothing to arbitrate on and two
    # concurrent dispatchers insert two budgets for one channel.
    create(
      unique_index(:notification_channel_rate_limits, [:channel_id],
        name: :notification_channel_rate_limits_channel_uidx,
        prefix: @prefix
      )
    )

    create(
      constraint(:notification_channel_rate_limits, :notification_channel_rate_limits_consumed,
        check: "consumed >= 0",
        prefix: @prefix
      )
    )
  end

  def down do
    drop_if_exists(table(:notification_channel_rate_limits, prefix: @prefix))
  end
end
