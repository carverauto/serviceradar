defmodule ServiceRadar.Repo.Migrations.AddPacketsInOutColumns do
  use Ecto.Migration

  def up do
    alter table("ocsf_network_activity", prefix: "platform") do
      add :packets_in, :bigint
      add :packets_out, :bigint
    end

    execute("UPDATE platform.ocsf_network_activity SET packets_in = 0 WHERE packets_in IS NULL")
    execute("UPDATE platform.ocsf_network_activity SET packets_out = 0 WHERE packets_out IS NULL")

    alter table("ocsf_network_activity", prefix: "platform") do
      modify :packets_in, :bigint, null: false, default: 0
      modify :packets_out, :bigint, null: false, default: 0
    end
  end

  def down do
    alter table("ocsf_network_activity", prefix: "platform") do
      remove :packets_in
      remove :packets_out
    end
  end
end
