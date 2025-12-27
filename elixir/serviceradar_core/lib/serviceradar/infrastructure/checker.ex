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
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "checkers"
    repo ServiceRadar.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? true
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
      description "All enabled checkers"
      filter expr(enabled == true)
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

    update :enable do
      description "Enable the checker"
      change set_attribute(:enabled, true)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
    end

    update :disable do
      description "Disable the checker"
      change set_attribute(:enabled, false)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
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
      description "Whether this checker is enabled"
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

    calculate :is_scheduled, :boolean, expr(enabled == true and interval_seconds > 0)

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
