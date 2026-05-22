defmodule ServiceRadar.Repo.Migrations.CreateUserGroupsAndDashboardAccessGrants do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:user_groups, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:name, :text, null: false)
      add(:description, :text)
      add(:owner_id, references(:ng_users, type: :uuid, prefix: @prefix, on_delete: :nilify_all))
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
      unique_index(:user_groups, [:name],
        name: :user_groups_name_idx,
        prefix: @prefix
      )
    )

    create(
      index(:user_groups, [:owner_id],
        name: :user_groups_owner_idx,
        prefix: @prefix
      )
    )

    create table(:user_group_memberships, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :group_id,
        references(:user_groups,
          column: :id,
          type: :uuid,
          prefix: @prefix,
          on_delete: :delete_all
        ),
        null: false
      )

      add(:user_id, references(:ng_users, type: :uuid, prefix: @prefix, on_delete: :delete_all),
        null: false
      )

      add(:role, :text, null: false, default: "member")
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
      unique_index(:user_group_memberships, [:group_id, :user_id],
        name: :user_group_memberships_unique_user_idx,
        prefix: @prefix
      )
    )

    create(
      index(:user_group_memberships, [:user_id],
        name: :user_group_memberships_user_idx,
        prefix: @prefix
      )
    )

    create table(:dashboard_access_grants, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :dashboard_id,
        references(:authored_dashboards,
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
      unique_index(:dashboard_access_grants, [:dashboard_id, :subject_type, :subject_user_id],
        name: :dashboard_access_grants_unique_user_idx,
        prefix: @prefix,
        where: "subject_type = 'user' AND subject_user_id IS NOT NULL"
      )
    )

    create(
      unique_index(:dashboard_access_grants, [:dashboard_id, :subject_type, :subject_group_id],
        name: :dashboard_access_grants_unique_group_idx,
        prefix: @prefix,
        where: "subject_type = 'group' AND subject_group_id IS NOT NULL"
      )
    )

    create(
      index(:dashboard_access_grants, [:subject_user_id],
        name: :dashboard_access_grants_subject_user_idx,
        prefix: @prefix
      )
    )

    create(
      index(:dashboard_access_grants, [:subject_group_id],
        name: :dashboard_access_grants_subject_group_idx,
        prefix: @prefix
      )
    )
  end

  def down do
    drop_if_exists(
      index(:dashboard_access_grants, [:subject_group_id],
        name: :dashboard_access_grants_subject_group_idx,
        prefix: @prefix
      )
    )

    drop_if_exists(
      index(:dashboard_access_grants, [:subject_user_id],
        name: :dashboard_access_grants_subject_user_idx,
        prefix: @prefix
      )
    )

    drop_if_exists(
      unique_index(:dashboard_access_grants, [:dashboard_id, :subject_type, :subject_group_id],
        name: :dashboard_access_grants_unique_group_idx,
        prefix: @prefix
      )
    )

    drop_if_exists(
      unique_index(:dashboard_access_grants, [:dashboard_id, :subject_type, :subject_user_id],
        name: :dashboard_access_grants_unique_user_idx,
        prefix: @prefix
      )
    )

    drop(table(:dashboard_access_grants, prefix: @prefix))

    drop_if_exists(
      index(:user_group_memberships, [:user_id],
        name: :user_group_memberships_user_idx,
        prefix: @prefix
      )
    )

    drop_if_exists(
      unique_index(:user_group_memberships, [:group_id, :user_id],
        name: :user_group_memberships_unique_user_idx,
        prefix: @prefix
      )
    )

    drop(table(:user_group_memberships, prefix: @prefix))

    drop_if_exists(
      index(:user_groups, [:owner_id],
        name: :user_groups_owner_idx,
        prefix: @prefix
      )
    )

    drop_if_exists(
      unique_index(:user_groups, [:name],
        name: :user_groups_name_idx,
        prefix: @prefix
      )
    )

    drop(table(:user_groups, prefix: @prefix))
  end
end
