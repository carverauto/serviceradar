defmodule ServiceRadar.Repo.Migrations.BackfillServiceMonitoringFoundation do
  @moduledoc false
  use Ecto.Migration

  def up do
    ServiceRadar.Monitoring.ServiceMonitoringBackfill.run!(repo())
  end

  def down do
    execute("""
    DELETE FROM platform.latest_check_states AS latest
    USING platform.check_instances AS check_instance
    WHERE latest.check_instance_id = check_instance.id
      AND check_instance.metadata ->> 'backfill_source' IN ('service_checks', 'service_state', 'service_status')
    """)

    execute("""
    DELETE FROM platform.check_instances
    WHERE metadata ->> 'backfill_source' IN ('service_checks', 'service_state', 'service_status')
    """)

    execute("""
    DELETE FROM platform.monitored_services
    WHERE source = 'backfill'
      AND metadata ->> 'backfill_source' IN ('service_checks', 'service_state', 'service_status')
    """)
  end
end
