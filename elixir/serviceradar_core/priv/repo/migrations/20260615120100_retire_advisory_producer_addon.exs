defmodule ServiceRadar.Repo.Migrations.RetireAdvisoryProducerAddon do
  @moduledoc """
  Retires the Go `serviceradar-advisory-producer` add-on. Advisory feeds now run
  in core (AshOban-scheduled, disk-staged); the agent-dispatched producer-schedule
  path for advisories is removed.

  This purges, scoped to `addon_id = 'advisory-producer'`:
    * `producer_schedules` rows owned by the advisory add-on package
    * `addon_assignments` for the advisory add-on
    * the advisory `addon_packages` row itself

  The shared dispatcher / assignment / schedule resources are untouched; only the
  advisory-specific rows are removed. Idempotent (safe to re-run); irreversible
  (`down` is a no-op — the core scheduler supersedes the producer schedules).
  """
  use Ecto.Migration

  @addon_id "advisory-producer"

  def up do
    execute("""
    DELETE FROM platform.producer_schedules ps
    USING platform.addon_packages ap
    WHERE ps.addon_package_id = ap.id
      AND ap.addon_id = '#{@addon_id}'
    """)

    execute("""
    DELETE FROM platform.addon_assignments
    WHERE addon_id = '#{@addon_id}'
    """)

    execute("""
    DELETE FROM platform.addon_packages
    WHERE addon_id = '#{@addon_id}'
    """)
  end

  def down do
    # Irreversible: the advisory add-on is retired in favor of core feed workers.
    :ok
  end
end
