defmodule ServiceRadar.Repo.Migrations.AddEndpointInventoryRetentionIndex do
  @moduledoc false
  use Ecto.Migration

  def change do
    create(
      index(:endpoint_inventory_scans, [:ingested_at],
        name: "endpoint_inventory_scans_retention_idx",
        prefix: "platform",
        where: "current = FALSE"
      )
    )
  end
end
