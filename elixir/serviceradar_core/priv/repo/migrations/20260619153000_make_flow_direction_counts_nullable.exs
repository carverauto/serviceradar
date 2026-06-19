defmodule ServiceRadar.Repo.Migrations.MakeFlowDirectionCountsNullable do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    alter table("ocsf_network_activity", prefix: "platform") do
      modify :packets_in, :bigint, null: true, default: nil
      modify :packets_out, :bigint, null: true, default: nil
    end
  end

  def down do
    execute("UPDATE platform.ocsf_network_activity SET packets_in = 0 WHERE packets_in IS NULL")
    execute("UPDATE platform.ocsf_network_activity SET packets_out = 0 WHERE packets_out IS NULL")

    alter table("ocsf_network_activity", prefix: "platform") do
      modify :packets_in, :bigint, null: false, default: 0
      modify :packets_out, :bigint, null: false, default: 0
    end
  end
end
