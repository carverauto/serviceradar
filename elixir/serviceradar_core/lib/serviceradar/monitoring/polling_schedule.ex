defmodule ServiceRadar.Monitoring.PollingSchedule do
  @moduledoc """
  Polling schedule resource for coordinating distributed poll execution.

  PollingSchedules define when and how service checks should be executed.
  They can group multiple checks into batches and assign them to specific
  pollers or partitions for distributed execution.

  ## Schedule Types

  - `:interval` - Execute at fixed intervals (e.g., every 60 seconds)
  - `:cron` - Execute on a cron schedule (e.g., "*/5 * * * *")
  - `:manual` - Only execute when manually triggered

  ## Assignment Modes

  - `:any` - Any available poller can execute
  - `:partition` - Only pollers in the assigned partition
  - `:specific` - Only the specifically assigned poller

  ## Execution Flow

  1. AshOban scheduler triggers `execute` action based on cron
  2. `execute` finds all enabled checks in this schedule
  3. Jobs are enqueued to pollers based on assignment mode
  4. Results are recorded via `record_result` action
  """

  use Ash.Resource,
    domain: ServiceRadar.Monitoring,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  postgres do
    table "polling_schedules"
    repo ServiceRadar.Repo
  end

  oban do
    triggers do
      # Scheduled trigger to execute due polling schedules
      trigger :execute_schedules do
        queue :service_checks
        read_action :due_for_execution
        scheduler_cron "* * * * *"
        action :execute

        scheduler_module_name ServiceRadar.Monitoring.PollingSchedule.ExecuteSchedulesScheduler
        worker_module_name ServiceRadar.Monitoring.PollingSchedule.ExecuteSchedulesWorker
      end
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? true
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_enabled, action: :enabled
    define :list_due_for_execution, action: :due_for_execution
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :enabled do
      description "All enabled schedules"
      filter expr(enabled == true)
    end

    read :due_for_execution do
      description "Schedules due for execution"

      filter expr(
               enabled == true and
                 schedule_type != :manual and
                 (is_nil(last_executed_at) or
                    (schedule_type == :interval and
                       fragment("? + interval '1 second' * ?", last_executed_at, interval_seconds) <
                         now()) or
                    schedule_type == :cron)
             )

      pagination keyset?: true, default_limit: 50
    end

    read :by_partition do
      argument :partition_id, :uuid, allow_nil?: false
      filter expr(assigned_partition_id == ^arg(:partition_id))
    end

    read :by_poller do
      argument :poller_id, :string, allow_nil?: false
      filter expr(assigned_poller_id == ^arg(:poller_id))
    end

    create :create do
      accept [
        :name,
        :description,
        :schedule_type,
        :interval_seconds,
        :cron_expression,
        :assignment_mode,
        :assigned_poller_id,
        :assigned_partition_id,
        :priority,
        :max_concurrent,
        :timeout_seconds,
        :metadata
      ]

      # Validate schedule configuration
      validate fn changeset, _context ->
        schedule_type = Ash.Changeset.get_attribute(changeset, :schedule_type)
        interval = Ash.Changeset.get_attribute(changeset, :interval_seconds)
        cron = Ash.Changeset.get_attribute(changeset, :cron_expression)

        cond do
          schedule_type == :interval and (is_nil(interval) or interval <= 0) ->
            {:error,
             field: :interval_seconds,
             message: "must be a positive integer for interval schedules"}

          schedule_type == :cron and (is_nil(cron) or cron == "") ->
            {:error, field: :cron_expression, message: "is required for cron schedules"}

          true ->
            :ok
        end
      end
    end

    update :update do
      accept [
        :name,
        :description,
        :interval_seconds,
        :cron_expression,
        :assignment_mode,
        :assigned_poller_id,
        :assigned_partition_id,
        :priority,
        :max_concurrent,
        :timeout_seconds,
        :metadata
      ]
    end

    update :enable do
      change set_attribute(:enabled, true)
    end

    update :disable do
      change set_attribute(:enabled, false)
    end

    update :execute do
      description "Execute this polling schedule (called by AshOban scheduler)"
      require_atomic? false

      change fn changeset, _context ->
        schedule = changeset.data
        execution_count = schedule.execution_count || 0

        require Logger
        Logger.info("Executing polling schedule: #{schedule.name} (#{schedule.id})")

        # Dispatch to poller and collect results
        result = ServiceRadar.Monitoring.PollOrchestrator.execute_schedule(schedule)

        # Update tracking based on result
        changeset =
          changeset
          |> Ash.Changeset.change_attribute(:last_executed_at, DateTime.utc_now())
          |> Ash.Changeset.change_attribute(:execution_count, execution_count + 1)

        case result do
          {:ok, stats} ->
            changeset
            |> Ash.Changeset.change_attribute(:last_result, :success)
            |> Ash.Changeset.change_attribute(:last_check_count, stats[:total] || 0)
            |> Ash.Changeset.change_attribute(:last_success_count, stats[:success] || 0)
            |> Ash.Changeset.change_attribute(:last_failure_count, stats[:failed] || 0)
            |> Ash.Changeset.change_attribute(:consecutive_failures, 0)

          {:error, reason} ->
            Logger.warning("Schedule #{schedule.name} failed: #{inspect(reason)}")
            consecutive = (schedule.consecutive_failures || 0) + 1

            changeset
            |> Ash.Changeset.change_attribute(:last_result, :failed)
            |> Ash.Changeset.change_attribute(:consecutive_failures, consecutive)
        end
      end
    end

    update :record_result do
      description "Record the result of a schedule execution"
      require_atomic? false

      argument :result, :atom do
        allow_nil? false
        constraints one_of: [:success, :partial, :failed, :timeout]
      end

      argument :check_count, :integer, default: 0
      argument :success_count, :integer, default: 0
      argument :failure_count, :integer, default: 0

      change fn changeset, _context ->
        result = Ash.Changeset.get_argument(changeset, :result)
        current_failures = changeset.data.consecutive_failures || 0

        new_failures =
          if result in [:success, :partial] do
            0
          else
            current_failures + 1
          end

        changeset
        |> Ash.Changeset.change_attribute(:last_result, result)
        |> Ash.Changeset.change_attribute(
          :last_check_count,
          Ash.Changeset.get_argument(changeset, :check_count)
        )
        |> Ash.Changeset.change_attribute(
          :last_success_count,
          Ash.Changeset.get_argument(changeset, :success_count)
        )
        |> Ash.Changeset.change_attribute(
          :last_failure_count,
          Ash.Changeset.get_argument(changeset, :failure_count)
        )
        |> Ash.Changeset.change_attribute(:consecutive_failures, new_failures)
      end
    end

    update :acquire_lock do
      description "Acquire distributed lock for execution"
      require_atomic? false

      argument :node_id, :string, allow_nil?: false

      change fn changeset, _context ->
        node_id = Ash.Changeset.get_argument(changeset, :node_id)
        lock_token = Ash.UUID.generate()

        changeset
        |> Ash.Changeset.change_attribute(:lock_token, lock_token)
        |> Ash.Changeset.change_attribute(:locked_at, DateTime.utc_now())
        |> Ash.Changeset.change_attribute(:locked_by, node_id)
      end
    end

    update :release_lock do
      description "Release distributed lock"

      change set_attribute(:lock_token, nil)
      change set_attribute(:locked_at, nil)
      change set_attribute(:locked_by, nil)
    end

    update :trigger_manual do
      description "Manually trigger schedule execution"
      require_atomic? false

      change fn changeset, _context ->
        schedule = changeset.data

        require Logger
        Logger.info("Manually triggering polling schedule: #{schedule.name} (#{schedule.id})")

        changeset
        |> Ash.Changeset.change_attribute(:last_executed_at, DateTime.utc_now())
      end
    end
  end

  policies do
    # Super admins bypass all policies
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # All authenticated users can read schedules
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :viewer)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Operators and admins can create and update schedules
    policy action([:create, :update, :enable, :disable]) do
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Execute, lock management - operators, admins, or system (AshOban)
    policy action([:execute, :record_result, :acquire_lock, :release_lock, :trigger_manual]) do
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :admin)
      # Allow AshOban scheduler (no actor) to execute
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Human-readable schedule name"
    end

    attribute :description, :string do
      public? true
      description "Schedule description"
    end

    attribute :schedule_type, :atom do
      allow_nil? false
      default :interval
      public? true
      constraints one_of: [:interval, :cron, :manual]
      description "Type of schedule"
    end

    attribute :interval_seconds, :integer do
      public? true
      description "Interval in seconds (for interval type)"
    end

    attribute :cron_expression, :string do
      public? true
      description "Cron expression (for cron type)"
    end

    attribute :assignment_mode, :atom do
      allow_nil? false
      default :any
      public? true
      constraints one_of: [:any, :partition, :specific]
      description "How to assign checks to pollers"
    end

    attribute :assigned_poller_id, :string do
      public? true
      description "Specific poller ID (for specific mode)"
    end

    attribute :assigned_partition_id, :uuid do
      public? true
      description "Partition ID (for partition mode)"
    end

    attribute :enabled, :boolean do
      default true
      public? true
      description "Whether this schedule is active"
    end

    attribute :priority, :integer do
      default 0
      public? true
      description "Execution priority (higher = more important)"
    end

    # Concurrency control
    attribute :max_concurrent, :integer do
      default 10
      public? true
      description "Maximum concurrent check executions"
    end

    attribute :timeout_seconds, :integer do
      default 60
      public? true
      description "Timeout for schedule execution"
    end

    # Execution tracking
    attribute :last_executed_at, :utc_datetime do
      public? true
      description "When this schedule was last executed"
    end

    attribute :last_result, :atom do
      public? true
      constraints one_of: [:success, :partial, :failed, :timeout]
      description "Result of last execution"
    end

    attribute :last_check_count, :integer do
      default 0
      public? true
      description "Number of checks executed in last run"
    end

    attribute :last_success_count, :integer do
      default 0
      public? true
      description "Number of successful checks in last run"
    end

    attribute :last_failure_count, :integer do
      default 0
      public? true
      description "Number of failed checks in last run"
    end

    attribute :execution_count, :integer do
      default 0
      public? true
      description "Total execution count"
    end

    attribute :consecutive_failures, :integer do
      default 0
      public? true
      description "Number of consecutive failed executions"
    end

    # Lock for distributed coordination
    attribute :lock_token, :uuid do
      public? false
      description "Distributed lock token"
    end

    attribute :locked_at, :utc_datetime do
      public? false
      description "When lock was acquired"
    end

    attribute :locked_by, :string do
      public? false
      description "Node that holds the lock"
    end

    attribute :metadata, :map do
      default %{}
      public? true
      description "Additional metadata"
    end

    # Multi-tenancy
    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
      description "Tenant this schedule belongs to"
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :partition, ServiceRadar.Infrastructure.Partition do
      source_attribute :assigned_partition_id
      destination_attribute :id
      allow_nil? true
      public? true
    end

    has_many :service_checks, ServiceRadar.Monitoring.ServiceCheck do
      destination_attribute :schedule_id
      public? true
    end
  end

  calculations do
    calculate :status_label,
              :string,
              expr(
                cond do
                  enabled == false -> "Disabled"
                  last_result == :success -> "Healthy"
                  last_result == :partial -> "Partial"
                  last_result in [:failed, :timeout] -> "Failed"
                  is_nil(last_result) -> "Never Run"
                  true -> "Unknown"
                end
              )

    calculate :status_color,
              :string,
              expr(
                cond do
                  enabled == false -> "gray"
                  last_result == :success -> "green"
                  last_result == :partial -> "yellow"
                  last_result in [:failed, :timeout] -> "red"
                  true -> "gray"
                end
              )

    calculate :is_locked,
              :boolean,
              expr(
                not is_nil(lock_token) and
                  locked_at > ago(5, :minute)
              )

    calculate :next_execution_at,
              :utc_datetime,
              expr(
                if schedule_type == :interval and not is_nil(interval_seconds) do
                  if is_nil(last_executed_at) do
                    now()
                  else
                    fragment("? + interval '1 second' * ?", last_executed_at, interval_seconds)
                  end
                else
                  nil
                end
              )

    calculate :success_rate,
              :float,
              expr(
                if last_check_count > 0 do
                  last_success_count * 100.0 / last_check_count
                else
                  nil
                end
              )
  end
end
