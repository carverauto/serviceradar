defmodule ServiceRadar.Repo.Migrations.AddEndpointInventoryHashFreshnessFields do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:endpoint_inventory_scans, prefix: "platform") do
      add(:package_set_hash, :text)
      add(:artifact_hash, :text)
      add(:hash_algorithm, :text)
      add(:upload_reason, :text)
      add(:server_package_set_hash, :text)
      add(:package_set_hash_mismatch, :boolean, null: false, default: false)
      add(:unchanged_scan_count, :integer, null: false, default: 0)
      add(:last_changed_scan_at, :utc_datetime_usec)
      add(:reconcile_floor_due, :boolean, null: false, default: false)
    end

    create(
      index(:endpoint_inventory_scans, [:agent_id, :package_set_hash],
        name: "endpoint_inventory_scans_agent_package_hash_idx",
        prefix: "platform",
        where: "package_set_hash IS NOT NULL"
      )
    )
  end
end
