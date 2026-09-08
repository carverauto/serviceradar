defmodule ServiceRadar.Repo.Migrations.AddSignalSchemasToPackages do
  @moduledoc """
  Stores package-owned log/event signal schema references for plugins and native add-ons.
  """

  use Ecto.Migration

  def change do
    alter table(:plugin_packages, prefix: "platform") do
      add(:signal_schemas, {:array, :map}, null: false, default: [])
    end

    alter table(:addon_packages, prefix: "platform") do
      add(:signal_schemas, {:array, :map}, null: false, default: [])
    end
  end
end
