defmodule ServiceRadar.Repo.Migrations.AddInterfaceMetricsSelected do
  use Ecto.Migration

  def up do
    alter table(:interface_settings) do
      add :metrics_selected, {:array, :text}, default: [], null: false
    end
  end

  def down do
    alter table(:interface_settings) do
      remove :metrics_selected
    end
  end
end
