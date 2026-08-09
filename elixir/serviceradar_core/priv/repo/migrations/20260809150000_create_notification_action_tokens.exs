defmodule ServiceRadar.Repo.Migrations.CreateNotificationActionTokens do
  @moduledoc """
  Creates the store behind the signed action links of design D7 Phase 1.

  One row per issued capability: `{delivery, alert, action}`, sha256 digest only,
  TTL-bounded, consumable exactly once. This is what makes Acknowledge, Snooze,
  and Resolve work from inside an email, a Slack message, a Discord message, a
  generic webhook, and every declarative provider with zero per-provider code.

  ## Why a table rather than columns on an existing one

  `notification_acknowledgements` is an append-only audit of actions **taken**:
  `actor_kind` and `source` are `NOT NULL` and the
  `notification_acknowledgements_actor` check demands an actor on every row. A
  minted-but-never-clicked capability has none of those, so storing it there
  would mean relaxing the check that makes the audit trustworthy, or writing
  audit rows for events that never happened.

  `notification_deliveries` is worse: three actions per delivery means three hash
  columns, three expiry columns, and three consumed-at columns, plus a fourth set
  the day a Suppress link is added.

  ## Both foreign keys cascade, and that is the opposite of its neighbours

  `notification_deliveries.alert_id` and `notification_acknowledgements.alert_id`
  are `ON DELETE SET NULL` because they are records of what happened and must
  outlive the alert - `ServiceRadar.Jobs.AlertsRetentionWorker` hard-deletes
  resolved and suppressed alerts after a default of three days.

  A capability is not a record; it is permission to act on something. When the
  something is gone the permission is meaningless, so both keys here are
  `ON DELETE CASCADE`. That is also what makes an expiry sweeper unnecessary:
  every token is reaped by whichever of the alert-retention worker or the
  delivery-retention worker fires first, and an unbounded growth path would need
  a token to outlive both.

  ## Indexes

  `selector` is unique and is the entire lookup path: verification addresses a
  row by the public half of the token and then compares digests in constant time.
  A partial index on live (unconsumed) tokens per delivery answers "which links
  in this notification are still good?" without scanning spent ones.

  Note: this migration is hand-written, matching
  `20260809120000_create_notification_platform_tables.exs`.
  `priv/resource_snapshots/` was removed in 607b40f584, so `mix ash.codegen`
  would emit a whole-application migration rather than a scoped one.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:notification_action_tokens, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(:selector, :text, null: false)
      add(:token_hash, :text, null: false)

      add(
        :delivery_id,
        references(:notification_deliveries,
          type: :uuid,
          on_delete: :delete_all,
          prefix: @prefix
        ),
        null: false
      )

      add(
        :alert_id,
        references(:alerts, type: :uuid, on_delete: :delete_all, prefix: @prefix),
        null: false
      )

      add(:action, :text, null: false)
      add(:snooze_seconds, :integer)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:consumed_at, :utc_datetime_usec)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      unique_index(:notification_action_tokens, [:selector],
        name: :notification_action_tokens_selector_uidx,
        prefix: @prefix
      )
    )

    create(
      index(:notification_action_tokens, [:delivery_id],
        name: :notification_action_tokens_live_idx,
        prefix: @prefix,
        where: "consumed_at IS NULL"
      )
    )

    create(index(:notification_action_tokens, [:alert_id], prefix: @prefix))

    # The action vocabulary is closed. A row outside it would be a capability the
    # redeemer cannot dispatch on, which is a crash at redemption rather than a
    # rejection at mint.
    create(
      constraint(:notification_action_tokens, :notification_action_tokens_action,
        check: "action IN ('acknowledge', 'snooze', 'resolve')",
        prefix: @prefix
      )
    )

    # A snooze duration that arrived in the request rather than in the token
    # would let anyone holding a Snooze link choose how long the alert stays
    # quiet. Binding it here is what makes "Snooze 1h" mean one hour.
    create(
      constraint(:notification_action_tokens, :notification_action_tokens_snooze,
        check: """
        (action = 'snooze' AND snooze_seconds IS NOT NULL AND snooze_seconds > 0)
        OR (action <> 'snooze' AND snooze_seconds IS NULL)
        """,
        prefix: @prefix
      )
    )
  end

  def down do
    drop_if_exists(table(:notification_action_tokens, prefix: @prefix))
  end
end
