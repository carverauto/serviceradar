defmodule ServiceRadar.Repo.Migrations.CreateIdentityDecisions do
  @moduledoc """
  Persisted identity decisions (`ServiceRadar.Inventory.IdentityDecision`).

  One row per distinct decision (kind, reason, subject, device set), keyed by a digest of
  those columns; a repeat updates the row's count and last time. The GIN index serves the
  per-device lookup (`device_uid = ANY(device_uids)`).
  """
  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:identity_decisions, primary_key: false, prefix: @prefix) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :decision_kind, :text, null: false
      add :reason, :text, null: false
      add :device_uids, {:array, :text}, null: false
      add :subject, :text
      add :decision_key, :text, null: false
      add :source, :text
      add :evidence, :map, null: false, default: %{}
      add :occurrence_count, :bigint, null: false, default: 1
      add :first_decided_at, :utc_datetime_usec, null: false
      add :last_decided_at, :utc_datetime_usec, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('utc', now())")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('utc', now())")
    end

    create unique_index(:identity_decisions, [:decision_key],
             prefix: @prefix,
             name: "identity_decisions_unique_decision_key_index"
           )

    create index(:identity_decisions, [:decision_kind, :last_decided_at], prefix: @prefix)

    execute("""
    CREATE INDEX identity_decisions_device_uids_gin_idx
    ON #{@prefix}.identity_decisions USING GIN (device_uids)
    """)
  end

  def down do
    drop table(:identity_decisions, prefix: @prefix)
  end
end
