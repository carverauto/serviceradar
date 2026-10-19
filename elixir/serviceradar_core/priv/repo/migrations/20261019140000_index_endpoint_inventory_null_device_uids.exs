defmodule ServiceRadar.Repo.Migrations.IndexEndpointInventoryNullDeviceUids do
  @moduledoc false
  use Ecto.Migration

  def up do
    create_if_not_exists(
      index(:endpoint_inventory_scans, [:agent_id],
        name: "endpoint_inventory_scans_agent_null_device_uid_idx",
        prefix: "platform",
        where: "device_uid IS NULL"
      )
    )

    create_if_not_exists(
      index(:endpoint_inventory_artifacts, [:agent_id],
        name: "endpoint_inventory_artifacts_agent_null_device_uid_idx",
        prefix: "platform",
        where: "device_uid IS NULL"
      )
    )

    create_if_not_exists(
      index(:endpoint_inventory_packages, [:agent_id],
        name: "endpoint_inventory_packages_agent_null_device_uid_idx",
        prefix: "platform",
        where: "device_uid IS NULL"
      )
    )
  end

  def down do
    drop_if_exists(
      index(:endpoint_inventory_packages, [:agent_id],
        name: "endpoint_inventory_packages_agent_null_device_uid_idx",
        prefix: "platform"
      )
    )

    drop_if_exists(
      index(:endpoint_inventory_artifacts, [:agent_id],
        name: "endpoint_inventory_artifacts_agent_null_device_uid_idx",
        prefix: "platform"
      )
    )

    drop_if_exists(
      index(:endpoint_inventory_scans, [:agent_id],
        name: "endpoint_inventory_scans_agent_null_device_uid_idx",
        prefix: "platform"
      )
    )
  end
end
