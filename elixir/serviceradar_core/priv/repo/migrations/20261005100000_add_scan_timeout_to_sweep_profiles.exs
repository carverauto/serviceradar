defmodule ServiceRadar.Repo.Migrations.AddScanTimeoutToSweepProfiles do
  use Ecto.Migration

  def change do
    alter table("sweep_profiles", prefix: "platform") do
      add_if_not_exists :scan_timeout, :string, null: true
    end
  end
end
