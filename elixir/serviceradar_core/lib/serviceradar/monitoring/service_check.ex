defmodule ServiceRadar.Monitoring.ServiceCheck do
  @moduledoc """
  Service check resource for scheduled monitoring checks.

  ServiceChecks define what to monitor and how often. They are associated
  with agents (which execute them) and can target devices directly.

  ## Check Types

  - `:ping` - ICMP ping check
  - `:http` - HTTP/HTTPS endpoint check
  - `:tcp` - TCP port connectivity check
  - `:snmp` - SNMP query check
  - `:grpc` - gRPC health check
  - `:dns` - DNS resolution check
  - `:custom` - Custom script/check

  ## Check Results

  Results are stored with timestamps and can trigger alerts when
  thresholds are exceeded or checks fail.
  """

  use Ash.Resource,
    domain: ServiceRadar.Monitoring,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban, AshJsonApi.Resource]

  postgres do
    table "service_checks"
    repo ServiceRadar.Repo
  end

  json_api do
    type "service-check"

    routes do
      base "/service-checks"

      get :by_id
      index :read
      index :enabled, route: "/enabled"
      index :failing, route: "/failing"
      post :create
      patch :update
    end
  end

  oban do
    list_tenants ServiceRadar.Oban.TenantList

    triggers do
      # Scheduled trigger to execute due checks
      trigger :execute_due_checks do
        queue :service_checks
        extra_args &ServiceRadar.Oban.AshObanQueueResolver.job_meta/1
        read_action :due_for_check
        scheduler_cron "* * * * *"
        action :execute

        scheduler_module_name ServiceRadar.Monitoring.ServiceCheck.ExecuteDueChecksScheduler
        worker_module_name ServiceRadar.Monitoring.ServiceCheck.ExecuteDueChecksWorker
      end
    end
  end

  multitenancy do
    strategy :context
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_by_agent, action: :by_agent, args: [:agent_uid]
    define :list_enabled, action: :enabled
    define :list_due_for_check, action: :due_for_check
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_agent do
      argument :agent_uid, :string, allow_nil?: false
      filter expr(agent_uid == ^arg(:agent_uid))
    end

    read :by_device do
      argument :device_uid, :string, allow_nil?: false
      filter expr(device_uid == ^arg(:device_uid))
    end

    read :enabled do
      description "All enabled checks"
      filter expr(enabled == true)
    end

    read :due_for_check do
      description "Checks that need to be executed"

      filter expr(
               enabled == true and
                 (is_nil(last_check_at) or
                    fragment("? + interval '1 second' * ?", last_check_at, interval_seconds) <
                      now())
             )

      pagination keyset?: true, default_limit: 100
    end

    read :failing do
      description "Checks with consecutive failures"
      filter expr(consecutive_failures > 0)
    end

    create :create do
      accept [
        :name,
        :description,
        :check_type,
        :target,
        :port,
        :interval_seconds,
        :timeout_seconds,
        :retries,
        :config,
        :warning_threshold_ms,
        :critical_threshold_ms,
        :agent_uid,
        :device_uid,
        :metadata
      ]
    end

    update :update do
      accept [
        :name,
        :description,
        :target,
        :port,
        :interval_seconds,
        :timeout_seconds,
        :retries,
        :config,
        :warning_threshold_ms,
        :critical_threshold_ms,
        :agent_uid,
        :metadata
      ]
    end

    update :enable do
      change set_attribute(:enabled, true)
    end

    update :disable do
      require_atomic? false
      change set_attribute(:enabled, false)
    end

    update :record_result do
      description "Record the result of a check execution"
      accept [:last_response_time_ms, :last_error]
      require_atomic? false

      argument :result, :atom do
        allow_nil? false
        constraints one_of: [:success, :warning, :critical, :unknown, :error]
      end

      change fn changeset, _context ->
        result = Ash.Changeset.get_argument(changeset, :result)
        current_failures = changeset.data.consecutive_failures || 0

        new_failures =
          if result in [:success, :warning] do
            0
          else
            current_failures + 1
          end

        changeset
        |> Ash.Changeset.change_attribute(:last_check_at, DateTime.utc_now())
        |> Ash.Changeset.change_attribute(:last_result, result)
        |> Ash.Changeset.change_attribute(:consecutive_failures, new_failures)
      end
    end

    update :reset_failures do
      description "Reset consecutive failure count"
      require_atomic? false
      change set_attribute(:consecutive_failures, 0)
    end

    update :execute do
      description "Execute this service check (called by AshOban scheduler)"
      require_atomic? false

      change fn changeset, _context ->
        # Mark check as starting execution
        # The actual check execution will be handled by the agent
        # This action just updates the last_check_at timestamp
        # and can trigger notifications to the assigned agent
        check = changeset.data

        # Log the check execution request
        require Logger
        Logger.info("Executing service check: #{check.name} (#{check.id})")

        changeset
        |> Ash.Changeset.change_attribute(:last_check_at, DateTime.utc_now())
      end
    end
  end

  policies do
    # Import common policy checks

    # Super admins bypass all policies (platform-wide access)
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # TENANT ISOLATION: Service checks define what to monitor for a tenant
    # Must be strictly isolated

    # Read access: Must be authenticated AND in same tenant
    policy action_type(:read) do
      authorize_if expr(
                     ^actor(:role) in [:viewer, :operator, :admin] and
                       tenant_id == ^actor(:tenant_id)
                   )
    end

    # Create/update checks: Operators/admins in same tenant
    policy action([:create, :update, :enable, :disable]) do
      authorize_if expr(
                     ^actor(:role) in [:operator, :admin] and
                       tenant_id == ^actor(:tenant_id)
                   )
    end

    # Record results: Operators/admins in same tenant
    policy action([:record_result, :reset_failures]) do
      authorize_if expr(
                     ^actor(:role) in [:operator, :admin] and
                       tenant_id == ^actor(:tenant_id)
                   )
    end

    # Execute action: Operators/admins in same tenant, or AshOban (no actor)
    policy action(:execute) do
      authorize_if expr(
                     ^actor(:role) in [:operator, :admin] and
                       tenant_id == ^actor(:tenant_id)
                   )

      # Allow AshOban scheduler (no actor) to execute checks
      authorize_if always()
    end
  end

  changes do
    change ServiceRadar.Changes.AssignTenantId
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Human-readable check name"
    end

    attribute :description, :string do
      public? true
      description "Check description"
    end

    attribute :check_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:ping, :http, :tcp, :snmp, :grpc, :dns, :custom]
      description "Type of check to perform"
    end

    attribute :target, :string do
      allow_nil? false
      public? true
      description "Target host/IP/URL to check"
    end

    attribute :port, :integer do
      public? true
      description "Target port (for TCP/HTTP checks)"
    end

    attribute :interval_seconds, :integer do
      default 60
      public? true
      description "Check interval in seconds"
    end

    attribute :timeout_seconds, :integer do
      default 10
      public? true
      description "Check timeout in seconds"
    end

    attribute :retries, :integer do
      default 3
      public? true
      description "Number of retries before marking failed"
    end

    attribute :enabled, :boolean do
      default true
      public? true
      description "Whether this check is active"
    end

    # Check-specific configuration
    attribute :config, :map do
      default %{}
      public? true
      description "Type-specific configuration (headers, SNMP OIDs, etc.)"
    end

    # Thresholds for alerting
    attribute :warning_threshold_ms, :integer do
      public? true
      description "Response time warning threshold (milliseconds)"
    end

    attribute :critical_threshold_ms, :integer do
      public? true
      description "Response time critical threshold (milliseconds)"
    end

    # Last result caching
    attribute :last_check_at, :utc_datetime do
      public? true
      description "When the last check was executed"
    end

    attribute :last_result, :atom do
      public? true
      constraints one_of: [:success, :warning, :critical, :unknown, :error]
      description "Result of last check"
    end

    attribute :last_response_time_ms, :integer do
      public? true
      description "Last response time in milliseconds"
    end

    attribute :last_error, :string do
      public? true
      description "Last error message (if failed)"
    end

    attribute :consecutive_failures, :integer do
      default 0
      public? true
      description "Count of consecutive check failures"
    end

    # Relationships
    attribute :agent_uid, :string do
      public? true
      description "Agent assigned to execute this check"
    end

    attribute :device_uid, :string do
      public? true
      description "Device being monitored"
    end

    attribute :metadata, :map do
      default %{}
      public? true
      description "Additional metadata"
    end

    # Schedule assignment
    attribute :schedule_id, :uuid do
      public? true
      description "Polling schedule this check belongs to"
    end

    # Multi-tenancy
    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
      description "Tenant this check belongs to"
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :agent, ServiceRadar.Infrastructure.Agent do
      source_attribute :agent_uid
      destination_attribute :uid
      allow_nil? true
      public? true
    end

    belongs_to :device, ServiceRadar.Inventory.Device do
      source_attribute :device_uid
      destination_attribute :uid
      allow_nil? true
      public? true
    end

    belongs_to :polling_schedule, ServiceRadar.Monitoring.PollingSchedule do
      source_attribute :schedule_id
      destination_attribute :id
      allow_nil? true
      public? true
    end
  end

  calculations do
    calculate :check_type_label,
              :string,
              expr(
                cond do
                  check_type == :ping -> "Ping"
                  check_type == :http -> "HTTP"
                  check_type == :tcp -> "TCP"
                  check_type == :snmp -> "SNMP"
                  check_type == :grpc -> "gRPC"
                  check_type == :dns -> "DNS"
                  check_type == :custom -> "Custom"
                  true -> "Unknown"
                end
              )

    calculate :status_color,
              :string,
              expr(
                cond do
                  enabled == false -> "gray"
                  last_result == :success -> "green"
                  last_result == :warning -> "yellow"
                  last_result in [:critical, :error] -> "red"
                  true -> "gray"
                end
              )

    calculate :is_overdue,
              :boolean,
              expr(
                enabled == true and
                  not is_nil(last_check_at) and
                  fragment("? + interval '1 second' * ? * 2", last_check_at, interval_seconds) <
                    now()
              )

    calculate :next_check_at,
              :utc_datetime,
              expr(
                if is_nil(last_check_at) do
                  now()
                else
                  fragment("? + interval '1 second' * ?", last_check_at, interval_seconds)
                end
              )
  end
end
