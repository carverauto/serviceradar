defmodule ServiceRadar.Repo.Migrations.CreateSourceIdentityConflicts do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:source_identity_conflicts, primary_key: false, prefix: @prefix) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :source_type, :text, null: false
      add :source_id, :text
      add :source_identifier_type, :text
      add :source_identifier_value, :text
      add :device_uid, :text
      add :current_ip, :text
      add :current_mac, :text
      add :site, :map, null: false, default: %{}
      add :conflict_category, :text, null: false
      add :conflicting_identifiers, :map, null: false, default: %{}
      add :proposed_action, :text
      add :confidence, :text
      add :status, :text, null: false, default: "open"
      add :first_detected_at, :utc_datetime_usec, null: false, default: utc_now()
      add :last_detected_at, :utc_datetime_usec, null: false, default: utc_now()
      add :resolved_at, :utc_datetime_usec
      add :dismissed_at, :utc_datetime_usec
      add :repair_audit, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false, default: utc_now()
      add :updated_at, :utc_datetime_usec, null: false, default: utc_now()
    end

    create index(:source_identity_conflicts, [:status, :conflict_category], prefix: @prefix)
    create index(:source_identity_conflicts, [:source_type, :source_id], prefix: @prefix)
    create index(:source_identity_conflicts, [:device_uid], prefix: @prefix)

    create index(:source_identity_conflicts, [:source_identifier_type, :source_identifier_value],
             prefix: @prefix,
             name: "source_identity_conflicts_identifier_idx"
           )

    execute("""
    CREATE UNIQUE INDEX source_identity_conflicts_open_uidx
    ON #{@prefix}.source_identity_conflicts (
      source_type,
      COALESCE(source_id, ''),
      conflict_category,
      COALESCE(device_uid, ''),
      COALESCE(source_identifier_type, ''),
      COALESCE(source_identifier_value, '')
    )
    WHERE status = 'open'
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS #{@prefix}.source_identity_conflicts_open_uidx")
    drop table(:source_identity_conflicts, prefix: @prefix)
  end

  defp utc_now do
    fragment("timezone('utc', now())")
  end
end
