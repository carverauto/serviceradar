defmodule ServiceRadar.Repo.Migrations.MoveWebNgJobsToWebMaintenanceQueue do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    execute("""
    UPDATE #{@prefix}.oban_jobs
    SET queue = 'web_maintenance'
    WHERE queue = 'maintenance'
      AND worker LIKE 'ServiceRadarWebNG.%'
      AND state IN ('available', 'scheduled', 'executing', 'retryable')
    """)
  end

  def down do
    execute("""
    UPDATE #{@prefix}.oban_jobs
    SET queue = 'maintenance'
    WHERE queue = 'web_maintenance'
      AND worker LIKE 'ServiceRadarWebNG.%'
      AND state IN ('available', 'scheduled', 'executing', 'retryable')
    """)
  end
end
