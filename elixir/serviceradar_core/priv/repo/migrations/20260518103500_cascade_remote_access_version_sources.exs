defmodule ServiceRadar.Repo.Migrations.CascadeRemoteAccessVersionSources do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  @foreign_keys [
    {"remote_access_session_versions", "remote_access_sessions",
     "remote_access_session_versions_version_source_id_fkey"},
    {"remote_access_request_versions", "remote_access_requests",
     "remote_access_request_versions_version_source_id_fkey"},
    {"remote_access_desktop_target_versions", "remote_access_desktop_targets",
     "remote_access_desktop_target_versions_version_source_id_fkey"},
    {"remote_access_host_key_versions", "remote_access_host_keys",
     "remote_access_host_key_versions_version_source_id_fkey"}
  ]

  def up do
    Enum.each(@foreign_keys, fn {version_table, source_table, constraint_name} ->
      replace_foreign_key(version_table, source_table, constraint_name, "CASCADE")
    end)
  end

  def down do
    Enum.each(@foreign_keys, fn {version_table, source_table, constraint_name} ->
      replace_foreign_key(version_table, source_table, constraint_name, "NO ACTION")
    end)
  end

  defp replace_foreign_key(version_table, source_table, constraint_name, on_delete) do
    execute("""
    ALTER TABLE #{@prefix}.#{version_table}
    DROP CONSTRAINT IF EXISTS #{constraint_name}
    """)

    execute("""
    ALTER TABLE #{@prefix}.#{version_table}
    ADD CONSTRAINT #{constraint_name}
    FOREIGN KEY (version_source_id)
    REFERENCES #{@prefix}.#{source_table}(id)
    ON DELETE #{on_delete}
    """)
  end
end
