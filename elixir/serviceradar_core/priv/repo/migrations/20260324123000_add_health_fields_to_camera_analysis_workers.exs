defmodule ServiceRadar.Repo.Migrations.AddHealthFieldsToCameraAnalysisWorkers do
  @moduledoc """
  Adds platform-owned health state to registered camera analysis workers.
  """

  use Ecto.Migration

  def up do
    alter table(:camera_analysis_workers, prefix: "platform") do
      add :health_status, :text, null: false, default: "healthy"
      add :health_reason, :text
      add :last_health_transition_at, :utc_datetime_usec
      add :last_healthy_at, :utc_datetime_usec
      add :last_failure_at, :utc_datetime_usec
      add :consecutive_failures, :integer, null: false, default: 0
    end

    execute(
      """
      UPDATE platform.camera_analysis_workers
      SET health_status = 'healthy',
          last_healthy_at = COALESCE(inserted_at, (now() AT TIME ZONE 'utc'))
      WHERE health_status IS NULL
      """,
      "SELECT 1"
    )

    create index(:camera_analysis_workers, [:health_status],
             prefix: "platform",
             name: "camera_analysis_workers_health_status_idx"
           )
  end

  def down do
    drop_if_exists index(:camera_analysis_workers, [:health_status],
                     prefix: "platform",
                     name: "camera_analysis_workers_health_status_idx"
                   )

    alter table(:camera_analysis_workers, prefix: "platform") do
      remove :consecutive_failures
      remove :last_failure_at
      remove :last_healthy_at
      remove :last_health_transition_at
      remove :health_reason
      remove :health_status
    end
  end
end
