defmodule ServiceRadarWebNG.Repo.Migrations.AddJobSchedules do
  use Ecto.Migration

  def change do
    create table(:ng_job_schedules) do
      add :job_key, :string, null: false
      add :cron, :string, null: false
      add :timezone, :string, null: false, default: "Etc/UTC"
      add :args, :map, null: false, default: %{}
      add :enabled, :boolean, null: false, default: true
      add :unique_period_seconds, :integer
      add :last_enqueued_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:ng_job_schedules, [:job_key])
    create index(:ng_job_schedules, [:enabled])

    execute(
      """
      INSERT INTO ng_job_schedules (job_key, cron, timezone, args, enabled, unique_period_seconds, inserted_at, updated_at)
      VALUES ('refresh_trace_summaries', '*/2 * * * *', 'Etc/UTC', '{}'::jsonb, true, 180, now(), now())
      ON CONFLICT (job_key) DO NOTHING
      """,
      """
      DELETE FROM ng_job_schedules WHERE job_key = 'refresh_trace_summaries'
      """
    )
  end
end
