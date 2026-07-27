defmodule ServiceRadar.Repo.Migrations.ScopeArmisIdentifierPartitions do
  @moduledoc false
  use Ecto.Migration

  def up do
    execute """
    UPDATE platform.device_identifiers
    SET partition = 'default:armis:' || (metadata->>'sync_service_id')
    WHERE identifier_type = 'armis_device_id'
      AND partition = 'default'
      AND COALESCE(metadata->>'integration_type', '') = 'armis'
      AND NULLIF(metadata->>'sync_service_id', '') IS NOT NULL
    """
  end

  def down do
    execute """
    UPDATE platform.device_identifiers
    SET partition = 'default'
    WHERE identifier_type = 'armis_device_id'
      AND partition LIKE 'default:armis:%'
    """
  end
end
