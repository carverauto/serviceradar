defmodule ServiceRadar.Infrastructure.Checker do
  @moduledoc """
  Checker resource for service check types.

  Checkers define the type of service checks that can be executed by agents.
  Each checker has a specific type (SNMP, gRPC, HTTP, ping, etc.) and
  configuration for how to perform the check.

  ## Checker Types

  - `snmp` - SNMP polling checks
  - `grpc` - gRPC health checks
  - `http` - HTTP/HTTPS endpoint checks
  - `ping` - ICMP ping checks
  - `tcp` - TCP port connectivity checks
  - `sweep` - Network sweep/scan checks
  - `port_scan` - Port scanning checks
  - `dns` - DNS resolution checks
  - `custom` - Custom checker implementations
  """

  use Ash.Resource,
    domain: ServiceRadar.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine]

  postgres do
    table "checkers"
    repo ServiceRadar.Repo
  end

  multitenancy do
    strategy :context
  end

  state_machine do
    initial_states [:active, :paused, :disabled]
    default_initial_state :active
    state_attribute :status
    deprecated_states []

    transitions do
      # Normal operation
      transition :pause, from: :active, to: :paused
      transition :resume, from: :paused, to: :active

      # Failure tracking
      transition :mark_failing, from: [:active, :paused], to: :failing
      transition :clear_failure, from: :failing, to: :active

      # Disabling
      transition :disable, from: [:active, :paused, :failing], to: :disabled
      transition :enable, from: :disabled, to: :active
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_by_type, action: :by_type, args: [:type]
    define :list_enabled, action: :enabled
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_type do
      argument :type, :string, allow_nil?: false
      filter expr(type == ^arg(:type))
    end

    read :by_agent do
      argument :agent_uid, :string, allow_nil?: false
      filter expr(agent_uid == ^arg(:agent_uid))
    end

    read :enabled do
      description "All enabled/active checkers"
      filter expr(status == :active or (enabled == true and status not in [:disabled, :paused]))
    end

    read :by_status do
      argument :status, :atom,
        allow_nil?: false,
        constraints: [one_of: [:active, :paused, :failing, :disabled]]

      filter expr(status == ^arg(:status))
    end

    create :create do
      accept [
        :name,
        :type,
        :description,
        :enabled,
        :config,
        :interval_seconds,
        :timeout_seconds,
        :retries,
        :target_type,
        :target_filter,
        :agent_uid
      ]

      change fn changeset, _context ->
        now = DateTime.utc_now()

        changeset
        |> Ash.Changeset.change_attribute(:created_at, now)
        |> Ash.Changeset.change_attribute(:updated_at, now)
      end
    end

    update :update do
      accept [
        :name,
        :description,
        :enabled,
        :config,
        :interval_seconds,
        :timeout_seconds,
        :retries,
        :target_type,
        :target_filter,
        :agent_uid
      ]

      change set_attribute(:updated_at, &DateTime.utc_now/0)
    end

    # State machine transition actions
    # Each action includes PublishStateChange to record health events

    update :pause do
      description "Pause the checker (temporarily stop execution)"

      change transition_state(:paused)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :checker, new_state: :paused}
    end

    update :resume do
      description "Resume a paused checker"

      change transition_state(:active)
      change set_attribute(:enabled, true)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :checker, new_state: :active}
    end

    update :mark_failing do
      description "Mark checker as failing due to consecutive failures"
      argument :reason, :string

      change transition_state(:failing)
      change set_attribute(:failure_reason, arg(:reason))
      change set_attribute(:last_failure, &DateTime.utc_now/0)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :checker, new_state: :failing}
    end

    update :clear_failure do
      description "Clear failure state after successful check"

      change transition_state(:active)
      change set_attribute(:consecutive_failures, 0)
      change set_attribute(:failure_reason, nil)
      change set_attribute(:last_success, &DateTime.utc_now/0)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :checker, new_state: :active}
    end

    update :record_success do
      description "Record a successful check result"

      change set_attribute(:consecutive_failures, 0)
      change set_attribute(:last_success, &DateTime.utc_now/0)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
    end

    update :record_failure do
      description "Record a failed check result"
      # Non-atomic: increments consecutive_failures based on current value
      require_atomic? false
      argument :reason, :string

      change fn changeset, _context ->
        current = Ash.Changeset.get_attribute(changeset, :consecutive_failures) || 0

        changeset
        |> Ash.Changeset.change_attribute(:consecutive_failures, current + 1)
        |> Ash.Changeset.change_attribute(:failure_reason, Ash.Changeset.get_argument(changeset, :reason))
        |> Ash.Changeset.change_attribute(:last_failure, DateTime.utc_now())
        |> Ash.Changeset.change_attribute(:updated_at, DateTime.utc_now())
      end
    end

    update :enable do
      description "Enable a disabled checker"

      change transition_state(:active)
      change set_attribute(:enabled, true)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :checker, new_state: :active}
    end

    update :disable do
      description "Disable the checker"

      change transition_state(:disabled)
      change set_attribute(:enabled, false)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
      change {ServiceRadar.Infrastructure.Changes.PublishStateChange, entity_type: :checker, new_state: :disabled}
    end
  end

  policies do
    # Import common policy checks

    # Super admins bypass all policies (platform-wide access)
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # TENANT ISOLATION: All operations require tenant match
    # Checkers belong to a tenant and must not be accessible cross-tenant

    # Read access: Must be authenticated AND in same tenant
    policy action_type(:read) do
      authorize_if expr(
                     ^actor(:role) in [:viewer, :operator, :admin] and
                       tenant_id == ^actor(:tenant_id)
                   )
    end

    # Create checkers: Operators/admins, enforces tenant from context
    policy action(:create) do
      authorize_if expr(
                     ^actor(:role) in [:operator, :admin] and
                       tenant_id == ^actor(:tenant_id)
                   )
    end

    # Update/enable/disable: Operators/admins in same tenant
    policy action([:update, :enable, :disable]) do
      authorize_if expr(
                     ^actor(:role) in [:operator, :admin] and
                       tenant_id == ^actor(:tenant_id)
                   )
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
      description "Checker display name"
    end

    attribute :type, :string do
      allow_nil? false
      public? true
      description "Checker type (snmp, grpc, http, ping, tcp, sweep, etc.)"
    end

    attribute :description, :string do
      public? true
      description "Checker description"
    end

    attribute :enabled, :boolean do
      default true
      public? true
      description "Whether this checker is enabled (legacy - use status)"
    end

    attribute :status, :atom do
      allow_nil? false
      default :active
      public? true
      constraints one_of: [:active, :paused, :failing, :disabled]
      description "Current operational status (state machine managed)"
    end

    attribute :consecutive_failures, :integer do
      default 0
      public? true
      description "Number of consecutive check failures"
    end

    attribute :last_success, :utc_datetime do
      public? true
      description "When the last successful check occurred"
    end

    attribute :last_failure, :utc_datetime do
      public? true
      description "When the last failed check occurred"
    end

    attribute :failure_reason, :string do
      public? true
      description "Reason for current failure state"
    end

    # Check configuration
    attribute :config, :map do
      default %{}
      public? true
      description "Checker-specific configuration (timeout, retries, etc.)"
    end

    attribute :interval_seconds, :integer do
      default 60
      public? true
      description "Check interval in seconds"
    end

    attribute :timeout_seconds, :integer do
      default 30
      public? true
      description "Check timeout in seconds"
    end

    attribute :retries, :integer do
      default 3
      public? true
      description "Number of retries before marking as failed"
    end

    # Target specification
    attribute :target_type, :string do
      default "agent"
      public? true
      description "What this checker targets (agent, device, endpoint)"
    end

    attribute :target_filter, :map do
      default %{}
      public? true
      description "Filter criteria for target selection"
    end

    # Agent assignment
    attribute :agent_uid, :string do
      public? true
      description "Specific agent this checker runs on (if not distributed)"
    end

    # Timestamps
    attribute :created_at, :utc_datetime do
      public? true
      description "When checker was created"
    end

    attribute :updated_at, :utc_datetime do
      public? true
      description "When checker was last updated"
    end

    # Multi-tenancy
    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
      description "Tenant this checker belongs to"
    end
  end

  relationships do
    belongs_to :agent, ServiceRadar.Infrastructure.Agent do
      source_attribute :agent_uid
      destination_attribute :uid
      allow_nil? true
      public? true
    end
  end

  calculations do
    calculate :display_name,
              :string,
              expr(
                if not is_nil(name) do
                  name
                else
                  type
                end
              )

    calculate :is_scheduled, :boolean, expr(status == :active and interval_seconds > 0)

    calculate :status_color,
              :string,
              expr(
                cond do
                  status == :active -> "green"
                  status == :paused -> "yellow"
                  status == :failing -> "red"
                  status == :disabled -> "gray"
                  true -> "gray"
                end
              )

    calculate :status_label,
              :string,
              expr(
                cond do
                  status == :active -> "Active"
                  status == :paused -> "Paused"
                  status == :failing -> "Failing"
                  status == :disabled -> "Disabled"
                  true -> "Unknown"
                end
              )

    calculate :is_healthy,
              :boolean,
              expr(status == :active and consecutive_failures < 3)

    calculate :type_label,
              :string,
              expr(
                cond do
                  type == "snmp" -> "SNMP"
                  type == "grpc" -> "gRPC"
                  type == "http" -> "HTTP"
                  type == "ping" -> "Ping"
                  type == "tcp" -> "TCP"
                  type == "sweep" -> "Network Sweep"
                  type == "port_scan" -> "Port Scan"
                  type == "dns" -> "DNS"
                  type == "custom" -> "Custom"
                  true -> type
                end
              )
  end
end
