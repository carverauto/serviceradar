defmodule ServiceRadar.Repo.Migrations.AddInterfaceClassificationFields do
  @moduledoc """
  Adds classification fields to discovered interfaces.
  """

  use Ecto.Migration

  def up do
    alter table(:discovered_interfaces) do
      add :classifications, {:array, :text}, null: false, default: []
      add :classification_meta, :map, null: false, default: %{}
      add :classification_source, :text, null: false, default: "rules"
    end
  end

  def down do
    alter table(:discovered_interfaces) do
      remove :classification_source
      remove :classification_meta
      remove :classifications
    end
  end
end
