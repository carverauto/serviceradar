defmodule ServiceRadarWebNG.Repo.Migrations.AddExpirePackagesSchedule do
  use Ecto.Migration

  def change do
    execute(
      """
      INSERT INTO ng_job_schedules (job_key, cron, timezone, args, enabled, unique_period_seconds, inserted_at, updated_at)
      VALUES ('expire_packages', '0 * * * *', 'Etc/UTC', '{}'::jsonb, true, 3600, now(), now())
      ON CONFLICT (job_key) DO NOTHING
      """,
      """
      DELETE FROM ng_job_schedules WHERE job_key = 'expire_packages'
      """
    )
  end
end
