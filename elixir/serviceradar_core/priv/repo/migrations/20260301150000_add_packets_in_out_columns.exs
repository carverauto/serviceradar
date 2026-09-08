defmodule ServiceRadar.Repo.Migrations.AddPacketsInOutColumns do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock false

  def up do
    # PG11+ handles ADD COLUMN ... DEFAULT constant NOT NULL as a fast
    # metadata-only operation — no table rewrite or backfill needed.
    alter table("ocsf_network_activity", prefix: "platform") do
      add :packets_in, :bigint, null: false, default: 0
      add :packets_out, :bigint, null: false, default: 0
    end
  end

  def down do
    alter table("ocsf_network_activity", prefix: "platform") do
      remove :packets_in
      remove :packets_out
    end
  end
end
