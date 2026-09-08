defmodule ServiceRadar.Repo.Migrations.PreserveDeletedConfigurationHistory do
  use Ecto.Migration

  @tables [
    {"network_credential_rule_versions", "network_credential_rules"},
    {"ansible_controller_versions", "ansible_controllers"},
    {"ansible_playbook_repository_versions", "ansible_playbook_repositories"}
  ]

  def up do
    # Versions are audit history. Retain source UUIDs and every historical row
    # when unused configuration is deleted; true consumer FKs stay restrictive.
    for {versions, _source} <- @tables do
      execute("""
      ALTER TABLE platform.#{versions}
      DROP CONSTRAINT IF EXISTS #{versions}_version_source_id_fkey
      """)
    end
  end

  def down do
    # Existing audit entries may intentionally outlive their source. Do not erase
    # them to restore constraints; enforce those only for future writes.
    for {versions, source} <- @tables do
      execute("""
      ALTER TABLE platform.#{versions}
      ADD CONSTRAINT #{versions}_version_source_id_fkey
      FOREIGN KEY (version_source_id) REFERENCES platform.#{source}(id) NOT VALID
      """)
    end
  end
end
