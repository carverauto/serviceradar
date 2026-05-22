defmodule ServiceRadar.Repo.Migrations.AddPluginPackageCheckDescriptors do
  @moduledoc false
  use Ecto.Migration

  def up do
    alter table(:plugin_packages, prefix: "platform") do
      add :check_descriptors, :map,
        null: false,
        default: %{"schema_version" => 1, "items" => []}
    end
  end

  def down do
    alter table(:plugin_packages, prefix: "platform") do
      remove :check_descriptors
    end
  end
end
