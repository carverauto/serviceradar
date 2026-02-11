defmodule ServiceRadar.Repo.Migrations.AddPartitionToDiscoveredInterfaces do
  use Ecto.Migration

  def up do
    alter table(:discovered_interfaces) do
      add :partition, :text, default: "default"
    end
  end

  def down do
    alter table(:discovered_interfaces) do
      remove :partition
    end
  end
end
