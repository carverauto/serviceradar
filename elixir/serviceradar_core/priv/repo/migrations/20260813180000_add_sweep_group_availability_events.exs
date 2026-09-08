defmodule ServiceRadar.Repo.Migrations.AddSweepGroupAvailabilityEvents do
  @moduledoc false
  use Ecto.Migration

  def up do
    alter table(:sweep_groups, prefix: "platform") do
      add :emit_availability_events, :boolean, null: false, default: false
    end
  end

  def down do
    alter table(:sweep_groups, prefix: "platform") do
      remove :emit_availability_events
    end
  end
end
