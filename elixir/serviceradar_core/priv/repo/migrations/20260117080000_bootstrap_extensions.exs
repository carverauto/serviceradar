defmodule ServiceRadar.Repo.Migrations.BootstrapExtensions do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS \"pgcrypto\"")
    execute("CREATE EXTENSION IF NOT EXISTS \"pg_trgm\"")
    execute("CREATE EXTENSION IF NOT EXISTS \"citext\"")
    execute("CREATE EXTENSION IF NOT EXISTS \"timescaledb\"")
    execute("CREATE EXTENSION IF NOT EXISTS \"age\"")
  end

  def down do
    execute("DROP EXTENSION IF EXISTS \"age\"")
    execute("DROP EXTENSION IF EXISTS \"timescaledb\"")
    execute("DROP EXTENSION IF EXISTS \"citext\"")
    execute("DROP EXTENSION IF EXISTS \"pg_trgm\"")
    execute("DROP EXTENSION IF EXISTS \"pgcrypto\"")
  end
end
