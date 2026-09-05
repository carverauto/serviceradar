defmodule ServiceRadar.Repo.Migrations.AlignDashboardInstanceAccessGrantIndexes do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    replace_grant_indexes(
      [:dashboard_instance_id, :subject_type, :subject_user_id],
      [:dashboard_instance_id, :subject_type, :subject_group_id]
    )
  end

  def down do
    replace_grant_indexes(
      [:dashboard_instance_id, :subject_user_id],
      [:dashboard_instance_id, :subject_group_id]
    )
  end

  defp replace_grant_indexes(user_columns, group_columns) do
    drop_if_exists(
      index(:dashboard_instance_access_grants, [],
        name: :dashboard_instance_access_grants_unique_user_idx,
        prefix: @prefix
      )
    )

    drop_if_exists(
      index(:dashboard_instance_access_grants, [],
        name: :dashboard_instance_access_grants_unique_group_idx,
        prefix: @prefix
      )
    )

    create(
      unique_index(:dashboard_instance_access_grants, user_columns,
        name: :dashboard_instance_access_grants_unique_user_idx,
        prefix: @prefix,
        where: "subject_type = 'user' AND subject_user_id IS NOT NULL"
      )
    )

    create(
      unique_index(:dashboard_instance_access_grants, group_columns,
        name: :dashboard_instance_access_grants_unique_group_idx,
        prefix: @prefix,
        where: "subject_type = 'group' AND subject_group_id IS NOT NULL"
      )
    )
  end
end
