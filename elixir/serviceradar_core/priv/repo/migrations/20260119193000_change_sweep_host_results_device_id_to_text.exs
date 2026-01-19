defmodule ServiceRadar.Repo.Migrations.ChangeSweepHostResultsDeviceIdToText do
  use Ecto.Migration

  def up do
    alter table(:sweep_host_results) do
      modify :device_id, :text, from: :uuid
    end
  end

  def down do
    alter table(:sweep_host_results) do
      modify :device_id, :uuid, from: :text
    end
  end
end
