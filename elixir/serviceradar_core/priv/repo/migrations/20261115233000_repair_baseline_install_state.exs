defmodule ServiceRadar.Repo.Migrations.RepairBaselineInstallState do
  @moduledoc """
  Schedules the repair of a database created from a schema baseline that lacked seed rows and
  TimescaleDB compression and retention state.

  Such a database recorded the migrations its baseline covered as applied without running
  them, so it never got their default rows or their compression settings and policies.
  `ServiceRadar.Repo.BaselineInstallRepairWorker` adds what is missing, from the sections the
  current baseline carries. The work takes locks on hypertables that ingestion writes to, so it
  runs as a job after startup rather than here.

  Only a database the baseline created (`platform.serviceradar_schema_baselines` exists) gets
  the job; a replayed database already has this state.
  """
  use Ecto.Migration

  @worker "ServiceRadar.Repo.BaselineInstallRepairWorker"

  def up do
    execute("""
    DO $$
    BEGIN
      IF to_regclass('platform.serviceradar_schema_baselines') IS NOT NULL THEN
        INSERT INTO platform.oban_jobs (state, queue, worker, args, max_attempts)
        VALUES ('available', 'maintenance', '#{@worker}', '{"trigger": "migration"}'::jsonb, 20);
      END IF;
    END
    $$;
    """)
  end

  # The job only adds state that is missing, so a pending one is harmless after a rollback, and
  # what it already added belongs to the schema the migrations describe.
  def down, do: :ok
end
