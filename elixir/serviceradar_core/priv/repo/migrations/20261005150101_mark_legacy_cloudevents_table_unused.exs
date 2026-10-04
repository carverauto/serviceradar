defmodule ServiceRadar.Repo.Migrations.MarkLegacyCloudEventsTableUnused do
  use Ecto.Migration

  def up do
    execute """
    COMMENT ON TABLE platform.events IS
      'Deprecated unused CloudEvents-style table retained for schema compatibility. No shipped writer or SRQL reader. JetStream events.> requires OCSF class_uid and writes the active OCSF event backend; discrete OTel events use OTLP logs with event_name.'
    """
  end

  def down do
    execute "COMMENT ON TABLE platform.events IS NULL"
  end
end
