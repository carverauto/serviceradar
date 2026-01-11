defmodule ServiceRadar.Monitoring.PollJob do
  @moduledoc """
  Poll job resource representing a single execution of a polling schedule.

  Uses AshStateMachine to manage job lifecycle:

  ```
  pending → dispatching → running → completed
                  ↓          ↓
               failed      failed
                            ↓
                         timeout
  ```

  ## States

  - `:pending` - Job created, waiting to be picked up by orchestrator
  - `:dispatching` - Finding an available gateway for execution
  - `:running` - Job is executing on a gateway/agent
  - `:completed` - Job finished successfully
  - `:failed` - Job failed (agent unreachable, check error, etc.)
  - `:timeout` - Job timed out before completion
  - `:cancelled` - Job was cancelled before completion

  ## Execution Flow

  1. AshOban triggers PollingSchedule.execute
  2. PollOrchestrator creates a PollJob in :pending state
  3. PollOrchestrator transitions to :dispatching while finding a gateway
  4. When gateway accepts job, transitions to :running
  5. On completion, transitions to :completed/:failed/:timeout
  6. Results are recorded and schedule is updated

  ## Retries

  Failed or timed-out jobs can be retried via the `:retry` action,
  which resets the job to :pending state with incremented retry_count.
  """

  use Ash.Resource,
    domain: ServiceRadar.Monitoring,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, AshJsonApi.Resource]

  postgres do
    table "poll_jobs"
    repo ServiceRadar.Repo
  end

  json_api do
    type "poll-job"

    routes do
      base "/poll-jobs"

      get :by_id
      index :read
      index :by_schedule, route: "/by-schedule/:schedule_id"
      index :pending, route: "/pending"
      index :running, route: "/running"
    end
  end

  state_machine do
    initial_states [:pending]
    default_initial_state :pending
    state_attribute :status

    transitions do
      # Normal flow
      transition :dispatch, from: :pending, to: :dispatching
      transition :start, from: :dispatching, to: :running
      transition :complete, from: :running, to: :completed

      # Failure paths
      transition :fail, from: [:dispatching, :running], to: :failed
      transition :timeout, from: :running, to: :timeout

      # Cancellation
      transition :cancel, from: [:pending, :dispatching], to: :cancelled

      # Retry - resets to pending
      transition :retry, from: [:failed, :timeout], to: :pending
    end
  end

  multitenancy do
    strategy :context
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_by_schedule, action: :by_schedule, args: [:schedule_id]
    define :list_pending, action: :pending
    define :list_running, action: :running
    define :create_job, action: :create
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_schedule do
      argument :schedule_id, :uuid, allow_nil?: false
      filter expr(schedule_id == ^arg(:schedule_id))
      prepare build(sort: [inserted_at: :desc], limit: 100)
    end

    read :pending do
      description "All pending jobs"
      filter expr(status == :pending)
      prepare build(sort: [inserted_at: :asc])
    end

    read :running do
      description "All running jobs"
      filter expr(status == :running)
    end

    read :stale do
      description "Jobs that have been running too long"
      filter expr(
               status == :running and
                 started_at < ago(^arg(:timeout_minutes), :minute)
             )

      argument :timeout_minutes, :integer, default: 5
    end

    read :recent do
      description "Recent jobs (last 24 hours)"
      filter expr(inserted_at > ago(24, :hour))
      prepare build(sort: [inserted_at: :desc], limit: 100)
    end

    create :create do
      description "Create a new poll job for a schedule"

      accept [
        :schedule_id,
        :schedule_name,
        :check_count,
        :check_ids,
        :gateway_id,
        :agent_id,
        :priority,
        :timeout_seconds,
        :metadata
      ]
    end

    # State machine transition actions

    update :dispatch do
      description "Mark job as dispatching (finding a gateway)"
      accept [:gateway_id]

      change transition_state(:dispatching)
      change set_attribute(:dispatched_at, &DateTime.utc_now/0)
    end

    update :start do
      description "Mark job as running on a gateway/agent"
      accept [:agent_id]

      change transition_state(:running)
      change set_attribute(:started_at, &DateTime.utc_now/0)
    end

    update :complete do
      description "Mark job as completed"
      # Non-atomic: computes duration based on started_at
      require_atomic? false

      argument :success_count, :integer, default: 0
      argument :failure_count, :integer, default: 0
      argument :results, {:array, :map}, default: []

      change transition_state(:completed)
      change set_attribute(:completed_at, &DateTime.utc_now/0)

      change fn changeset, _context ->
        success_count = Ash.Changeset.get_argument(changeset, :success_count)
        failure_count = Ash.Changeset.get_argument(changeset, :failure_count)
        results = Ash.Changeset.get_argument(changeset, :results)
        started_at = changeset.data.started_at

        duration_ms =
          if started_at do
            DateTime.diff(DateTime.utc_now(), started_at, :millisecond)
          else
            0
          end

        changeset
        |> Ash.Changeset.change_attribute(:success_count, success_count)
        |> Ash.Changeset.change_attribute(:failure_count, failure_count)
        |> Ash.Changeset.change_attribute(:results, results)
        |> Ash.Changeset.change_attribute(:duration_ms, duration_ms)
      end
    end

    update :fail do
      description "Mark job as failed"
      # Non-atomic: computes duration based on started_at
      require_atomic? false

      argument :error_message, :string
      argument :error_code, :string

      change transition_state(:failed)
      change set_attribute(:completed_at, &DateTime.utc_now/0)

      change fn changeset, _context ->
        error_message = Ash.Changeset.get_argument(changeset, :error_message)
        error_code = Ash.Changeset.get_argument(changeset, :error_code)
        started_at = changeset.data.started_at

        duration_ms =
          if started_at do
            DateTime.diff(DateTime.utc_now(), started_at, :millisecond)
          else
            0
          end

        changeset
        |> Ash.Changeset.change_attribute(:error_message, error_message)
        |> Ash.Changeset.change_attribute(:error_code, error_code)
        |> Ash.Changeset.change_attribute(:duration_ms, duration_ms)
      end
    end

    update :timeout do
      description "Mark job as timed out"

      change transition_state(:timeout)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
      change set_attribute(:error_message, "Job execution timed out")
    end

    update :cancel do
      description "Cancel a pending or dispatching job"
      # Non-atomic: uses function to set error_message from argument
      require_atomic? false

      argument :reason, :string

      change transition_state(:cancelled)
      change set_attribute(:completed_at, &DateTime.utc_now/0)

      change fn changeset, _context ->
        reason = Ash.Changeset.get_argument(changeset, :reason)

        changeset
        |> Ash.Changeset.change_attribute(:error_message, reason || "Job cancelled")
      end
    end

    update :retry do
      description "Retry a failed or timed out job"
      # Non-atomic: increments retry_count and resets multiple fields
      require_atomic? false

      change transition_state(:pending)

      change fn changeset, _context ->
        current_retry = changeset.data.retry_count || 0

        changeset
        |> Ash.Changeset.change_attribute(:retry_count, current_retry + 1)
        |> Ash.Changeset.change_attribute(:dispatched_at, nil)
        |> Ash.Changeset.change_attribute(:started_at, nil)
        |> Ash.Changeset.change_attribute(:completed_at, nil)
        |> Ash.Changeset.change_attribute(:error_message, nil)
        |> Ash.Changeset.change_attribute(:error_code, nil)
        |> Ash.Changeset.change_attribute(:results, [])
      end
    end
  end

  policies do
    # Super admins bypass all policies
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # Tenant isolation for reads
    policy action_type(:read) do
      authorize_if expr(tenant_id == ^actor(:tenant_id))
    end

    # Create/update for operators and admins in same tenant
    policy action_type(:create) do
      authorize_if expr(
                     ^actor(:role) in [:operator, :admin] and
                       tenant_id == ^actor(:tenant_id)
                   )

      # Allow system (AshOban/orchestrator) to create jobs
      authorize_if always()
    end

    policy action_type(:update) do
      authorize_if expr(
                     ^actor(:role) in [:operator, :admin] and
                       tenant_id == ^actor(:tenant_id)
                   )

      # Allow system transitions
      authorize_if always()
    end
  end

  changes do
    change ServiceRadar.Changes.AssignTenantId
  end

  attributes do
    uuid_primary_key :id

    # Job identity
    attribute :schedule_id, :uuid do
      allow_nil? false
      public? true
      description "The polling schedule this job belongs to"
    end

    attribute :schedule_name, :string do
      public? true
      description "Cached schedule name for display"
    end

    # Job configuration
    attribute :check_count, :integer do
      default 0
      public? true
      description "Number of checks in this job"
    end

    attribute :check_ids, {:array, :uuid} do
      default []
      public? true
      description "IDs of service checks included in this job"
    end

    attribute :gateway_id, :string do
      public? true
      description "Gateway assigned to execute this job"
    end

    attribute :agent_id, :string do
      public? true
      description "Agent executing the checks (if applicable)"
    end

    attribute :priority, :integer do
      default 0
      public? true
      description "Job priority (higher = more important)"
    end

    attribute :timeout_seconds, :integer do
      default 60
      public? true
      description "Job timeout in seconds"
    end

    # State machine managed
    attribute :status, :atom do
      allow_nil? false
      default :pending
      public? true

      constraints one_of: [
                    :pending,
                    :dispatching,
                    :running,
                    :completed,
                    :failed,
                    :timeout,
                    :cancelled
                  ]

      description "Current job state (managed by state machine)"
    end

    # Timing
    attribute :dispatched_at, :utc_datetime do
      public? true
      description "When the job was dispatched to a gateway"
    end

    attribute :started_at, :utc_datetime do
      public? true
      description "When job execution started"
    end

    attribute :completed_at, :utc_datetime do
      public? true
      description "When the job completed (success or failure)"
    end

    attribute :duration_ms, :integer do
      public? true
      description "Total execution duration in milliseconds"
    end

    # Results
    attribute :success_count, :integer do
      default 0
      public? true
      description "Number of successful checks"
    end

    attribute :failure_count, :integer do
      default 0
      public? true
      description "Number of failed checks"
    end

    attribute :results, {:array, :map} do
      default []
      public? true
      description "Individual check results"
    end

    # Error handling
    attribute :error_message, :string do
      public? true
      description "Error message if job failed"
    end

    attribute :error_code, :string do
      public? true
      description "Error code for categorization"
    end

    attribute :retry_count, :integer do
      default 0
      public? true
      description "Number of retry attempts"
    end

    attribute :max_retries, :integer do
      default 3
      public? true
      description "Maximum retry attempts before giving up"
    end

    # Metadata
    attribute :metadata, :map do
      default %{}
      public? true
      description "Additional job metadata"
    end

    # Multi-tenancy
    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
      description "Tenant this job belongs to"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :schedule, ServiceRadar.Monitoring.PollingSchedule do
      source_attribute :schedule_id
      destination_attribute :id
      allow_nil? false
      public? true
    end
  end

  calculations do
    calculate :status_label,
              :string,
              expr(
                cond do
                  status == :pending -> "Pending"
                  status == :dispatching -> "Dispatching"
                  status == :running -> "Running"
                  status == :completed -> "Completed"
                  status == :failed -> "Failed"
                  status == :timeout -> "Timed Out"
                  status == :cancelled -> "Cancelled"
                  true -> "Unknown"
                end
              )

    calculate :status_color,
              :string,
              expr(
                cond do
                  status == :pending -> "gray"
                  status == :dispatching -> "blue"
                  status == :running -> "blue"
                  status == :completed -> "green"
                  status == :failed -> "red"
                  status == :timeout -> "yellow"
                  status == :cancelled -> "gray"
                  true -> "gray"
                end
              )

    calculate :is_terminal,
              :boolean,
              expr(status in [:completed, :failed, :timeout, :cancelled])

    calculate :can_retry,
              :boolean,
              expr(
                status in [:failed, :timeout] and
                  retry_count < max_retries
              )

    calculate :success_rate,
              :float,
              expr(
                if check_count > 0 do
                  success_count * 100.0 / check_count
                else
                  nil
                end
              )

    calculate :wait_time_ms,
              :integer,
              expr(
                if not is_nil(started_at) and not is_nil(inserted_at) do
                  fragment("EXTRACT(EPOCH FROM (? - ?)) * 1000", started_at, inserted_at)
                else
                  nil
                end
              )
  end

  identities do
    identity :unique_job, [:id]
  end
end
