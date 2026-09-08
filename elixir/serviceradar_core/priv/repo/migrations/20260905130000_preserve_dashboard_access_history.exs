defmodule ServiceRadar.Repo.Migrations.PreserveDashboardAccessHistory do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    drop_version_source_reference(
      :dashboard_instance_versions,
      :dashboard_instance_versions_source_fkey
    )

    drop_version_source_reference(
      :dashboard_instance_access_grant_versions,
      :dashboard_instance_access_grant_versions_source_fkey
    )
  end

  def down do
    create_version_source_reference(
      :dashboard_instance_versions,
      :dashboard_instances,
      :dashboard_instance_versions_source_fkey
    )

    create_version_source_reference(
      :dashboard_instance_access_grant_versions,
      :dashboard_instance_access_grants,
      :dashboard_instance_access_grant_versions_source_fkey
    )
  end

  defp drop_version_source_reference(table, name) do
    drop(constraint(table, name, prefix: @prefix))
  end

  defp create_version_source_reference(table, source_table, name) do
    alter table(table, prefix: @prefix) do
      modify(
        :version_source_id,
        references(source_table,
          type: :uuid,
          name: name,
          prefix: @prefix,
          on_delete: :delete_all
        ),
        from: :uuid
      )
    end
  end
end
