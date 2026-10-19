defmodule ServiceRadar.Repo.Migrations.AddSweepGroupDiscoverNewDevices do
  @moduledoc """
  Whether a sweep group adds hosts that answer inside its static targets to
  inventory. Existing groups take the column default, which keeps their current
  behaviour; the migration rewrites no rows.
  """
  use Ecto.Migration

  def up do
    alter table(:sweep_groups, prefix: "platform") do
      add :discover_new_devices, :boolean, null: false, default: true
    end
  end

  def down do
    alter table(:sweep_groups, prefix: "platform") do
      remove :discover_new_devices
    end
  end
end
