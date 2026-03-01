defmodule ServiceRadar.Repo.Migrations.AddPacketsInOutColumns do
  use Ecto.Migration

  def change do
    alter table("ocsf_network_activity", prefix: "platform") do
      add :packets_in, :bigint, null: false, default: 0
      add :packets_out, :bigint, null: false, default: 0
    end
  end
end
