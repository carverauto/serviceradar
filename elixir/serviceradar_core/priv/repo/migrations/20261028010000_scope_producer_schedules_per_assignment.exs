defmodule ServiceRadar.Repo.Migrations.ScopeProducerSchedulesPerAssignment do
  @moduledoc """
  Scopes bound plugin producer schedules per `(plugin_package_id, plugin_assignment_id, schedule_id)`
  while keeping unbound package template schedules unique per `(plugin_package_id, schedule_id)`.

  Previously `producer_schedules_plugin_package_uidx` enforced uniqueness on
  `(plugin_package_id, schedule_id) WHERE plugin_package_id IS NOT NULL`, so
  reconciling multiple credential rules for the same package overwrote a single
  schedule row's `plugin_assignment_id` and `credential_refs` on every pass.
  """

  use Ecto.Migration

  def up do
    execute("DROP INDEX IF EXISTS platform.producer_schedules_plugin_package_uidx")

    execute("""
    CREATE UNIQUE INDEX producer_schedules_plugin_package_uidx
      ON platform.producer_schedules (plugin_package_id, schedule_id)
      WHERE plugin_package_id IS NOT NULL AND plugin_assignment_id IS NULL
    """)

    execute("""
    CREATE UNIQUE INDEX producer_schedules_plugin_assignment_uidx
      ON platform.producer_schedules (plugin_package_id, plugin_assignment_id, schedule_id)
      WHERE plugin_package_id IS NOT NULL AND plugin_assignment_id IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.producer_schedules_plugin_assignment_uidx")
    execute("DROP INDEX IF EXISTS platform.producer_schedules_plugin_package_uidx")

    execute("""
    CREATE UNIQUE INDEX producer_schedules_plugin_package_uidx
      ON platform.producer_schedules (plugin_package_id, schedule_id)
      WHERE plugin_package_id IS NOT NULL
    """)
  end
end
