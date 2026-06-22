defmodule ServiceRadar.Repo.Migrations.AllowNullDirectionalFlowCounts do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock false

  def up do
    execute("ALTER TABLE platform.ocsf_network_activity ALTER COLUMN packets_in DROP DEFAULT")
    execute("ALTER TABLE platform.ocsf_network_activity ALTER COLUMN packets_out DROP DEFAULT")
    execute("ALTER TABLE platform.ocsf_network_activity ALTER COLUMN packets_in DROP NOT NULL")
    execute("ALTER TABLE platform.ocsf_network_activity ALTER COLUMN packets_out DROP NOT NULL")
  end

  def down do
    execute("UPDATE platform.ocsf_network_activity SET packets_in = 0 WHERE packets_in IS NULL")
    execute("UPDATE platform.ocsf_network_activity SET packets_out = 0 WHERE packets_out IS NULL")
    execute("ALTER TABLE platform.ocsf_network_activity ALTER COLUMN packets_in SET DEFAULT 0")
    execute("ALTER TABLE platform.ocsf_network_activity ALTER COLUMN packets_out SET DEFAULT 0")
    execute("ALTER TABLE platform.ocsf_network_activity ALTER COLUMN packets_in SET NOT NULL")
    execute("ALTER TABLE platform.ocsf_network_activity ALTER COLUMN packets_out SET NOT NULL")
  end
end
