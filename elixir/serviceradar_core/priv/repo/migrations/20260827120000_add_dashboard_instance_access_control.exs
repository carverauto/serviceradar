defmodule ServiceRadar.Repo.Migrations.AddDashboardInstanceAccessControl do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    alter table(:dashboard_instances, prefix: @prefix) do
      add(:visibility, :text, null: false, default: "public")
      add(:owner_id, references(:ng_users, type: :uuid, prefix: @prefix, on_delete: :nilify_all))
    end

    execute("""
    UPDATE #{@prefix}.dashboard_instances
    SET visibility = 'public'
    WHERE visibility IS DISTINCT FROM 'public'
    """)

    execute("""
    DO $$
    DECLARE
      leftover integer;
    BEGIN
      SELECT count(*) INTO leftover
      FROM #{@prefix}.dashboard_instances
      WHERE visibility IS DISTINCT FROM 'public';

      IF leftover <> 0 THEN
        RAISE EXCEPTION
          'dashboard_instances backfill left % non-public row(s)', leftover;
      END IF;
    END
    $$;
    """)

    create table(:dashboard_instance_access_grants, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :dashboard_instance_id,
        references(:dashboard_instances,
          column: :id,
          type: :uuid,
          prefix: @prefix,
          on_delete: :delete_all
        ),
        null: false
      )

      add(:subject_type, :text, null: false)

      add(
        :subject_user_id,
        references(:ng_users, type: :uuid, prefix: @prefix, on_delete: :delete_all)
      )

      add(
        :subject_group_id,
        references(:user_groups,
          column: :id,
          type: :uuid,
          prefix: @prefix,
          on_delete: :delete_all
        )
      )

      add(:access, :text, null: false, default: "view")

      add(
        :granted_by_id,
        references(:ng_users, type: :uuid, prefix: @prefix, on_delete: :nilify_all)
      )

      add(:metadata, :map, null: false, default: %{})

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      unique_index(:dashboard_instance_access_grants, [:dashboard_instance_id, :subject_user_id],
        name: :dashboard_instance_access_grants_unique_user_idx,
        prefix: @prefix,
        where: "subject_type = 'user' AND subject_user_id IS NOT NULL"
      )
    )

    create(
      unique_index(
        :dashboard_instance_access_grants,
        [:dashboard_instance_id, :subject_group_id],
        name: :dashboard_instance_access_grants_unique_group_idx,
        prefix: @prefix,
        where: "subject_type = 'group' AND subject_group_id IS NOT NULL"
      )
    )

    create(
      index(:dashboard_instance_access_grants, [:dashboard_instance_id],
        name: :dashboard_instance_access_grants_instance_idx,
        prefix: @prefix
      )
    )

    create_version_table(
      :dashboard_instance_versions,
      :dashboard_instances,
      "dashboard_instance_versions_source_fkey"
    )

    create_version_table(
      :dashboard_instance_access_grant_versions,
      :dashboard_instance_access_grants,
      "dashboard_instance_access_grant_versions_source_fkey"
    )
  end

  def down do
    drop_if_exists(
      index(:dashboard_instance_access_grant_versions, [:version_source_id], prefix: @prefix)
    )

    drop_if_exists(table(:dashboard_instance_access_grant_versions, prefix: @prefix))
    drop_if_exists(index(:dashboard_instance_versions, [:version_source_id], prefix: @prefix))
    drop_if_exists(table(:dashboard_instance_versions, prefix: @prefix))
    drop(table(:dashboard_instance_access_grants, prefix: @prefix))

    alter table(:dashboard_instances, prefix: @prefix) do
      remove(:owner_id)
      remove(:visibility)
    end
  end

  defp create_version_table(table, source_table, fkey_name) do
    create table(table, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:version_action_inputs, :map, null: false, default: %{})

      add(
        :version_source_id,
        references(source_table,
          type: :uuid,
          name: fkey_name,
          prefix: @prefix,
          on_delete: :delete_all
        ),
        null: false
      )

      add(:changes, :map)

      add(:version_inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:version_updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      index(table, [:version_source_id],
        name: String.to_atom("#{table}_source_idx"),
        prefix: @prefix
      )
    )
  end
end
