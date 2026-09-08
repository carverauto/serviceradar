defmodule ServiceRadar.Repo.Migrations.PruneLegacyArmisGenericIdentifiers do
  @moduledoc """
  Removes the pre-DIRE generic Armis identifier bridge.

  Armis payloads carry both armis_device_id and integration_id, but only the
  typed value is authoritative. Older sync versions registered the raw value
  as integration_id, which created large cross-device bridge groups when an IP
  collision recovered a batch onto one device. Current ingestion rejects that
  mapping; this migration removes the already-persisted rows.
  """

  use Ecto.Migration

  def up do
    # serviceradar:allow-startup-maintenance - remove invalid legacy identity rows
    execute("""
    DELETE FROM platform.device_identifiers
    WHERE identifier_type = 'integration_id'
      AND COALESCE(metadata->>'integration_type', '') = 'armis';
    """)
  end

  def down do
    :ok
  end
end
