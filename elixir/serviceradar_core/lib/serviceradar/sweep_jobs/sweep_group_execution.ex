defmodule ServiceRadar.SweepJobs.SweepGroupExecution do
  @moduledoc """
  Execution tracking for sweep groups.

  Each time a sweep group runs, an execution record is created to track:
  - Execution status (pending, running, completed, failed)
  - Timing (started_at, completed_at, duration)
  - Results summary (hosts_total, hosts_available)
  - Which agent executed the sweep

  ## Lifecycle

  1. `pending` - Execution scheduled/queued
  2. `running` - Sweep in progress
  3. `completed` - Sweep finished successfully
  4. `failed` - Sweep encountered an error

  ## Usage

      # Start an execution
      execution =
        SweepGroupExecution
        |> Ash.Changeset.for_create(:start, %{sweep_group_id: group.id, agent_id: "agent-1"})
        |> Ash.create!()

      # Mark as completed
      execution
      |> Ash.Changeset.for_update(:complete, %{hosts_total: 100, hosts_available: 95})
      |> Ash.update!()
  """

  use Ash.Resource,
    domain: ServiceRadar.SweepJobs,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "sweep_group_executions"
    repo ServiceRadar.Repo

    custom_indexes do
      index [:sweep_group_id, :started_at],
        name: "sweep_group_executions_group_started_idx"

      index [:status],
        name: "sweep_group_executions_status_idx"
    end
  end

  multitenancy do
    strategy :context
  end

  actions do
    defaults [:read, :destroy]

    create :start do
      description "Start a new execution"

      accept [:sweep_group_id, :agent_id, :config_version]

      change set_attribute(:status, :running)
      change set_attribute(:started_at, &DateTime.utc_now/0)
    end

    update :complete do
      description "Mark execution as completed"
      require_atomic? false

      accept [:hosts_total, :hosts_available, :hosts_failed]

      change set_attribute(:status, :completed)
      change set_attribute(:completed_at, &DateTime.utc_now/0)

      change fn changeset, _context ->
        started_at = changeset.data.started_at
        completed_at = DateTime.utc_now()

        if started_at do
          duration_ms = DateTime.diff(completed_at, started_at, :millisecond)
          Ash.Changeset.change_attribute(changeset, :duration_ms, duration_ms)
        else
          changeset
        end
      end
    end

    update :fail do
      description "Mark execution as failed"
      require_atomic? false

      argument :error_message, :string, allow_nil?: false

      change set_attribute(:status, :failed)
      change set_attribute(:completed_at, &DateTime.utc_now/0)

      change fn changeset, _context ->
        error_msg = Ash.Changeset.get_argument(changeset, :error_message)

        changeset
        |> Ash.Changeset.change_attribute(:error_message, error_msg)
        |> then(fn cs ->
          started_at = cs.data.started_at
          completed_at = DateTime.utc_now()

          if started_at do
            duration_ms = DateTime.diff(completed_at, started_at, :millisecond)
            Ash.Changeset.change_attribute(cs, :duration_ms, duration_ms)
          else
            cs
          end
        end)
      end
    end

    update :update_progress do
      description "Update execution progress"

      accept [:hosts_total, :hosts_available, :hosts_failed]
    end

    read :by_group do
      argument :sweep_group_id, :uuid, allow_nil?: false

      filter expr(sweep_group_id == ^arg(:sweep_group_id))

      prepare build(sort: [started_at: :desc])
    end

    read :recent do
      argument :limit, :integer, default: 10

      prepare build(sort: [started_at: :desc])
      prepare build(limit: arg(:limit))
    end

    read :running do
      filter expr(status == :running)
    end
  end

  policies do
    # Super admins can do anything
    bypass always() do
    end

    # System actors can perform all operations (tenant isolation via schema)
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    # System can create and update executions
    policy action_type(:create) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action_type(:update) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action_type(:destroy) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # All authenticated users can read executions
    policy action_type(:read) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: [:pending, :running, :completed, :failed]
      description "Current execution status"
    end

    attribute :started_at, :utc_datetime do
      allow_nil? true
      public? true
      description "When execution started"
    end

    attribute :completed_at, :utc_datetime do
      allow_nil? true
      public? true
      description "When execution completed"
    end

    attribute :duration_ms, :integer do
      allow_nil? true
      public? true
      description "Execution duration in milliseconds"
    end

    attribute :hosts_total, :integer do
      allow_nil? true
      public? true
      default 0
      description "Total hosts targeted"
    end

    attribute :hosts_available, :integer do
      allow_nil? true
      public? true
      default 0
      description "Hosts that responded"
    end

    attribute :hosts_failed, :integer do
      allow_nil? true
      public? true
      default 0
      description "Hosts that failed to respond"
    end

    attribute :error_message, :string do
      allow_nil? true
      public? true
      description "Error message if failed"
    end

    attribute :agent_id, :string do
      allow_nil? true
      public? true
      description "Which agent executed this sweep"
    end

    attribute :config_version, :string do
      allow_nil? true
      public? true
      description "Config version hash used for this execution"
    end

    attribute :sweep_group_id, :uuid do
      allow_nil? false
      public? true
      description "The sweep group that was executed"
    end

    attribute :scanner_metrics, :map do
      allow_nil? true
      public? true
      default %{}
      description """
      Scanner performance metrics from the agent.
      Contains: packets_sent, packets_recv, packets_dropped, ring_blocks_processed,
      ring_blocks_dropped, retries_attempted, retries_successful, ports_allocated,
      ports_released, port_exhaustion_count, rate_limit_deferrals, rx_drop_rate_percent
      """
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :sweep_group, ServiceRadar.SweepJobs.SweepGroup do
      allow_nil? false
      define_attribute? false
      destination_attribute :id
      source_attribute :sweep_group_id
    end

    has_many :host_results, ServiceRadar.SweepJobs.SweepHostResult do
      destination_attribute :execution_id
    end
  end

  calculations do
    calculate :success_rate, :float, expr(
      if hosts_total > 0 do
        hosts_available * 100.0 / hosts_total
      else
        0.0
      end
    )
  end
end
