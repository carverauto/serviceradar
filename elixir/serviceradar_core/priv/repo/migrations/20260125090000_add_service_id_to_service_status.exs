defmodule ServiceRadar.Repo.Migrations.AddServiceIdToServiceStatus do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE #{prefix() || "platform"}.service_status
    ADD COLUMN IF NOT EXISTS service_id UUID
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_service_status_service_id
    ON #{prefix() || "platform"}.service_status (service_id)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS #{prefix() || "platform"}.idx_service_status_service_id")
    execute("ALTER TABLE #{prefix() || "platform"}.service_status DROP COLUMN IF EXISTS service_id")
  end
end
