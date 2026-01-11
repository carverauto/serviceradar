defmodule ServiceRadar.Repo.TenantMigrations.AddObanJobs do
  use Ecto.Migration

  def up do
    oban_prefix = prefix() || "public"
    Oban.Migrations.up(prefix: oban_prefix)
  end

  def down do
    oban_prefix = prefix() || "public"
    Oban.Migrations.down(prefix: oban_prefix)
  end
end
