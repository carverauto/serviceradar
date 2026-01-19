defmodule ServiceRadar.Repo.Migrations.RefactorSweepTargetingSrql do
  use Ecto.Migration

  def up do
    alter table(:sweep_groups) do
      add :target_query, :text
      remove :target_criteria
    end
  end

  def down do
    alter table(:sweep_groups) do
      add :target_criteria, :map, null: false, default: %{}
      remove :target_query
    end
  end
end
