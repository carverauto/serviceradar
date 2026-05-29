defmodule ServiceRadar.Repo.Migrations.AddBannerGrabSummaryToSweepExecutions do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    alter table(:sweep_group_executions, prefix: @prefix) do
      add :banner_grab_summary, :map, null: false, default: %{}
    end

    create table(:sweep_group_execution_versions, primary_key: false, prefix: @prefix) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :version_action_type, :text, null: false
      add :version_action_name, :text, null: false
      add :version_action_inputs, :map, null: false, default: %{}
      add :sweep_group_id, :uuid, null: false
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

    create index(:sweep_group_execution_versions, [:version_source_id],
             name: :sweep_group_execution_versions_source_idx,
             prefix: @prefix
           )

    create index(:sweep_group_execution_versions, [:sweep_group_id, :version_inserted_at],
             name: :sweep_group_execution_versions_group_inserted_idx,
             prefix: @prefix
           )
  end

  def down do
    drop_if_exists index(:sweep_group_execution_versions, [:sweep_group_id, :version_inserted_at],
                     name: :sweep_group_execution_versions_group_inserted_idx,
                     prefix: @prefix
                   )

    drop_if_exists index(:sweep_group_execution_versions, [:version_source_id],
                     name: :sweep_group_execution_versions_source_idx,
                     prefix: @prefix
                   )

    drop_if_exists table(:sweep_group_execution_versions, prefix: @prefix)

    alter table(:sweep_group_executions, prefix: @prefix) do
      remove :banner_grab_summary
    end
  end
end
