defmodule ServiceRadar.Repo.Migrations.ScopeArmisIdentifierPartitions do
  @moduledoc false
  use Ecto.Migration

  def up do
    # serviceradar:allow-startup-maintenance - re-scopes already-persisted Armis
    # identifier rows onto per-sync-service partitions. No-op on the first-boot
    # path: platform.device_identifiers is empty until sync runs, so the UPDATE
    # matches nothing. On an upgrade it is a one-shot rewrite bounded to rows
    # that are BOTH identifier_type = 'armis_device_id' AND still on the
    # unscoped 'default' partition -- a set that only shrinks, and is empty on
    # every deployment that has already run this.
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
