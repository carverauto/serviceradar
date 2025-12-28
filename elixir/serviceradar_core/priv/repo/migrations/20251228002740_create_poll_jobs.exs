defmodule ServiceRadar.Repo.Migrations.CreatePollJobs do
  @moduledoc """
  Creates the poll_jobs table for tracking individual poll job executions.

  PollJobs use AshStateMachine for lifecycle management:
  pending -> dispatching -> running -> completed/failed/timeout
  """

  use Ecto.Migration

  def change do
    create table(:poll_jobs, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false

      # Job identity
      add :schedule_id, references(:polling_schedules, type: :uuid, on_delete: :delete_all),
        null: false

      add :schedule_name, :string

      # Job configuration
      add :check_count, :integer, default: 0
      add :check_ids, {:array, :uuid}, default: []
      add :poller_id, :string
      add :agent_id, :string
      add :priority, :integer, default: 0
      add :timeout_seconds, :integer, default: 60

      # State machine managed
      add :status, :string, null: false, default: "pending"

      # Timing
      add :dispatched_at, :utc_datetime
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :duration_ms, :integer

      # Results
      add :success_count, :integer, default: 0
      add :failure_count, :integer, default: 0
      add :results, :map, default: []

      # Error handling
      add :error_message, :text
      add :error_code, :string
      add :retry_count, :integer, default: 0
      add :max_retries, :integer, default: 3

      # Metadata
      add :metadata, :map, default: %{}

      # Multi-tenancy
      add :tenant_id, :uuid, null: false

      timestamps(inserted_at: :inserted_at, updated_at: :updated_at)
    end

    # Indexes for common queries
    create index(:poll_jobs, [:schedule_id])
    create index(:poll_jobs, [:tenant_id])
    create index(:poll_jobs, [:status])
    create index(:poll_jobs, [:tenant_id, :status])
    create index(:poll_jobs, [:tenant_id, :schedule_id])
    create index(:poll_jobs, [:inserted_at])

    # Index for finding stale running jobs
    create index(:poll_jobs, [:status, :started_at],
             where: "status = 'running'"
           )
  end
end
