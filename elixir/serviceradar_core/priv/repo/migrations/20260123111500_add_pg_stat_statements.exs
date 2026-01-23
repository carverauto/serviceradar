defmodule ServiceRadar.Repo.Migrations.AddPgStatStatements do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pg_stat_statements")
  end

  def down do
    execute("DROP EXTENSION IF EXISTS pg_stat_statements")
  end
end
