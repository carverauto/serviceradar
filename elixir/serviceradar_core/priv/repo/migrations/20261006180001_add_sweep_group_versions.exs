defmodule ServiceRadar.Repo.Migrations.AddSweepGroupVersions do
  @moduledoc """
  Append-only paper trail for sweep group assignment changes.

  `sweep_groups` had no version table, so an operator edit or a supersession
  transfer left no record of the previous `agent_ids` or who wrote them.
  Versions hold no foreign key: deleting a group does not delete its history,
  and a group that has run can still be deleted.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:sweep_group_versions, primary_key: false, prefix: @prefix) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :version_action_type, :text, null: false
      add :version_action_name, :text, null: false
      add :version_action_inputs, :map, null: false, default: %{}
      add :version_source_id, :uuid, null: false
      add :changes, :map
      add :actor, :map
      add :actor_id, :text
      add :request_id, :text

      add :version_inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :version_updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:sweep_group_versions, [:version_source_id],
             name: :sweep_group_versions_source_idx,
             prefix: @prefix
           )
  end

  def down do
    drop_if_exists index(:sweep_group_versions, [:version_source_id],
                     name: :sweep_group_versions_source_idx,
                     prefix: @prefix
                   )

    drop_if_exists table(:sweep_group_versions, prefix: @prefix)
  end
end
