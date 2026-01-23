defmodule ServiceRadar.Repo.Migrations.RemoveSysmonProfileDefault do
  use Ecto.Migration

  def up do
    alter table(:sysmon_profiles) do
      remove :is_default
    end
  end

  def down do
    alter table(:sysmon_profiles) do
      add :is_default, :boolean, null: false, default: false
    end
  end
end
