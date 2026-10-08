defmodule ServiceRadar.Repo.Migrations.PreserveDeletedDashboardReportHistory do
  @moduledoc false
  use Ecto.Migration

  # AuthoredDashboard and DashboardReportSchedule record a version on destroy
  # (create_version_on_destroy? true). The version row is written after the
  # source row is deleted, so a foreign key from version_source_id to the source
  # table rejected every destroy and rolled it back. Versions are audit history:
  # retain the source UUID without a constraint, as
  # PreserveDashboardAccessHistory and PreserveDeletedConfigurationHistory do.
  @tables [
    {"authored_dashboard_versions", "authored_dashboards"},
    {"dashboard_report_schedule_versions", "dashboard_report_schedules"}
  ]

  def up do
    for {versions, _source} <- @tables do
      execute("""
      ALTER TABLE platform.#{versions}
      DROP CONSTRAINT IF EXISTS #{versions}_source_fkey
      """)
    end
  end

  def down do
    # Existing audit entries may intentionally outlive their source. Do not erase
    # them to restore constraints; enforce those only for future writes.
    for {versions, source} <- @tables do
      execute("""
      ALTER TABLE platform.#{versions}
      ADD CONSTRAINT #{versions}_source_fkey
      FOREIGN KEY (version_source_id) REFERENCES platform.#{source}(id)
      ON DELETE CASCADE NOT VALID
      """)
    end
  end
end
