defmodule ServiceRadar.Infrastructure.Agent do
  @moduledoc """
  Agent resource for managing Go agents (OCSF v1.4.0 Agent object).

  Agents are Go processes that run on monitored hosts, proxying service checks
  to local checkers. They connect to pollers via gRPC and are tracked in the
  AgentRegistry (Horde.Registry).

  ## Role

  Agents perform the actual monitoring checks. They have capabilities that define
  what types of checks they can perform:
  - **ICMP** - Ping checks for host reachability
  - **TCP** - TCP port checks for service availability
  - **HTTP** - HTTP/HTTPS endpoint checks
  - **gRPC** - gRPC health checks via external checkers
  - **DNS** - DNS resolution checks
  - **Process** - Local process monitoring
  - **SNMP** - SNMP monitoring (via external checker)

  ## OCSF Type IDs

  - 0: Unknown
  - 1: EDR (Endpoint Detection and Response)
  - 2: DLP (Data Loss Prevention)
  - 3: Backup/Recovery
  - 4: Performance Monitoring
  - 5: Vulnerability Management
  - 6: Log Management
  - 7: MDM (Mobile Device Management)
  - 8: Configuration Management
  - 9: Remote Access
  - 99: Other
  """

  @capability_definitions %{
    icmp: %{icon: "hero-signal", color: "info", description: "ICMP ping checks for host reachability"},
    tcp: %{icon: "hero-server-stack", color: "success", description: "TCP port checks for service availability"},
    http: %{icon: "hero-globe-alt", color: "warning", description: "HTTP/HTTPS endpoint checks"},
    grpc: %{icon: "hero-cpu-chip", color: "secondary", description: "gRPC health checks via external checkers"},
    dns: %{icon: "hero-at-symbol", color: "info", description: "DNS resolution checks"},
    process: %{icon: "hero-cog-6-tooth", color: "accent", description: "Local process monitoring"},
    snmp: %{icon: "hero-chart-bar", color: "accent", description: "SNMP monitoring via external checker"},
    sweep: %{icon: "hero-magnifying-glass", color: "primary", description: "Network sweep/discovery"},
    agent: %{icon: "hero-cube", color: "ghost", description: "Agent management capabilities"}
  }

  @type_names %{
    0 => "Unknown",
    1 => "EDR",
    2 => "DLP",
    3 => "Backup/Recovery",
    4 => "Performance",
    5 => "Vulnerability",
    6 => "Log Management",
    7 => "MDM",
    8 => "Config Management",
    9 => "Remote Access",
    99 => "Other"
  }

  @doc "Returns capability definitions for all supported agent capabilities"
  def capability_definitions, do: @capability_definitions

  @doc "Returns capability info for a specific capability"
  def capability_info(capability) when is_atom(capability) do
    Map.get(@capability_definitions, capability, %{icon: "hero-cube", color: "ghost", description: to_string(capability)})
  end

  def capability_info(capability) when is_binary(capability) do
    try do
      capability_info(String.to_existing_atom(capability))
    rescue
      ArgumentError -> %{icon: "hero-cube", color: "ghost", description: capability}
    end
  end

  @doc "Returns OCSF type names map"
  def type_names, do: @type_names

  @doc "Returns type name for a given type_id"
  def type_name(type_id), do: Map.get(@type_names, type_id, "Unknown")

  use Ash.Resource,
    domain: ServiceRadar.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, AshJsonApi.Resource]

  postgres do
    table "ocsf_agents"
    repo ServiceRadar.Repo
  end

  json_api do
    type "agent"

    routes do
      base "/agents"

      # Read operations
      get :by_uid
      index :read
      index :by_poller, route: "/by-poller/:poller_id"

      # Admin/onboarding creates agent records (host:port known from onboarding package)
      post :register

      # Poller updates agent status after connecting via gRPC
      patch :establish_connection, route: "/:id/connect"
      patch :heartbeat, route: "/:id/heartbeat"
      patch :lose_connection, route: "/:id/disconnect"
      patch :degrade, route: "/:id/degrade"
    end
  end

  state_machine do
    initial_states [:connecting, :connected]
    default_initial_state :connecting
    state_attribute :status
    deprecated_states []

    transitions do
      # Agent lifecycle transitions
      transition :establish_connection, from: :connecting, to: :connected
      transition :connection_failed, from: :connecting, to: :disconnected
      transition :degrade, from: :connected, to: :degraded
      transition :restore_health, from: :degraded, to: :connected
      transition :lose_connection, from: [:connected, :degraded], to: :disconnected
      transition :reconnect, from: :disconnected, to: :connecting

      transition :mark_unavailable,
        from: [:connecting, :connected, :degraded, :disconnected],
        to: :unavailable

      transition :recover, from: :unavailable, to: :connecting
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? true
  end

  code_interface do
    define :get_by_uid, action: :by_uid, args: [:uid]
    define :list_by_poller, action: :by_poller, args: [:poller_id]
    define :list_connected, action: :connected
  end

  actions do
    defaults [:read]

    read :by_uid do
      argument :uid, :string, allow_nil?: false
      get? true
      filter expr(uid == ^arg(:uid))
    end

    read :by_poller do
      argument :poller_id, :string, allow_nil?: false
      filter expr(poller_id == ^arg(:poller_id))
    end

    read :by_device do
      argument :device_uid, :string, allow_nil?: false
      filter expr(device_uid == ^arg(:device_uid))
    end

    read :connected do
      description "All connected agents"
      filter expr(status == :connected and is_healthy == true)
    end

    read :by_status do
      argument :status, :atom,
        allow_nil?: false,
        constraints: [one_of: [:connecting, :connected, :degraded, :disconnected, :unavailable]]

      filter expr(status == ^arg(:status))
    end

    read :by_capability do
      argument :capability, :string, allow_nil?: false
      filter expr(^arg(:capability) in capabilities)
    end

    read :recently_seen do
      description "Agents seen in the last 5 minutes"
      filter expr(last_seen_time > ago(5, :minute))
    end

    create :register do
      description "Register a new agent (starts in connecting state)"

      accept [
        :uid,
        :name,
        :type_id,
        :type,
        :uid_alt,
        :vendor_name,
        :version,
        :policies,
        :poller_id,
        :device_uid,
        :capabilities,
        :host,
        :port,
        :spiffe_identity,
        :metadata
      ]

      change fn changeset, _context ->
        now = DateTime.utc_now()

        changeset
        |> Ash.Changeset.change_attribute(:first_seen_time, now)
        |> Ash.Changeset.change_attribute(:last_seen_time, now)
        |> Ash.Changeset.change_attribute(:created_time, now)
        |> Ash.Changeset.change_attribute(:is_healthy, true)
      end
    end

    create :register_connected do
      description "Register a new agent as already connected (skips connecting state)"

      accept [
        :uid,
        :name,
        :type_id,
        :type,
        :uid_alt,
        :vendor_name,
        :version,
        :policies,
        :poller_id,
        :device_uid,
        :capabilities,
        :host,
        :port,
        :spiffe_identity,
        :metadata
      ]

      change fn changeset, _context ->
        now = DateTime.utc_now()

        changeset
        |> Ash.Changeset.change_attribute(:first_seen_time, now)
        |> Ash.Changeset.change_attribute(:last_seen_time, now)
        |> Ash.Changeset.change_attribute(:created_time, now)
        |> Ash.Changeset.change_attribute(:status, :connected)
        |> Ash.Changeset.change_attribute(:is_healthy, true)
      end
    end

    update :update do
      accept [:name, :capabilities, :host, :port, :policies, :metadata]
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :heartbeat do
      description "Update last_seen_time and health status (for connected agents)"
      accept [:is_healthy, :capabilities]
      require_atomic? false

      change set_attribute(:last_seen_time, &DateTime.utc_now/0)
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    # State machine transition actions
    update :establish_connection do
      description "Mark agent as connected (from connecting state)"
      accept [:poller_id]

      change transition_state(:connected)
      change set_attribute(:is_healthy, true)
      change set_attribute(:last_seen_time, &DateTime.utc_now/0)
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :connection_failed do
      description "Mark connection attempt as failed"

      change transition_state(:disconnected)
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :degrade do
      description "Mark agent as degraded (connected but unhealthy)"

      change transition_state(:degraded)
      change set_attribute(:is_healthy, false)
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :restore_health do
      description "Restore agent health (from degraded to connected)"

      change transition_state(:connected)
      change set_attribute(:is_healthy, true)
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :lose_connection do
      description "Mark agent as disconnected (connection lost)"

      change transition_state(:disconnected)
      change set_attribute(:poller_id, nil)
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :reconnect do
      description "Start reconnection process (from disconnected to connecting)"

      change transition_state(:connecting)
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :mark_unavailable do
      description "Mark agent as unavailable (admin action)"
      argument :reason, :string

      change transition_state(:unavailable)
      change set_attribute(:is_healthy, false)
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :recover do
      description "Start recovery process (from unavailable to connecting)"

      change transition_state(:connecting)
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    # Legacy compatibility actions (mapped to state machine)
    update :connect do
      description "Mark agent as connected to a poller (legacy - use establish_connection)"
      accept [:poller_id]

      change transition_state(:connected)
      change set_attribute(:is_healthy, true)
      change set_attribute(:last_seen_time, &DateTime.utc_now/0)
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :disconnect do
      description "Mark agent as disconnected (legacy - use lose_connection)"

      change transition_state(:disconnected)
      change set_attribute(:poller_id, nil)
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :mark_unhealthy do
      description "Mark agent as unhealthy (legacy - use degrade)"
      change transition_state(:degraded)
      change set_attribute(:is_healthy, false)
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end
  end

  policies do
    # Super admins can see all agents across tenants
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # Tenant isolation: users can only see agents in their tenant
    policy action_type(:read) do
      authorize_if expr(tenant_id == ^actor(:tenant_id))
    end

    # Allow create/update for agents in user's tenant
    policy action_type(:create) do
      authorize_if expr(tenant_id == ^actor(:tenant_id))
    end

    policy action_type(:update) do
      authorize_if expr(tenant_id == ^actor(:tenant_id))
    end
  end

  attributes do
    # OCSF Core Identity - uid is the primary key
    attribute :uid, :string do
      allow_nil? false
      primary_key? true
      public? true
      description "Unique agent identifier (sensor ID)"
    end

    attribute :name, :string do
      public? true
      description "Agent display name"
    end

    attribute :type_id, :integer do
      default 0
      public? true
      description "OCSF agent type ID"
    end

    attribute :type, :string do
      public? true
      description "OCSF agent type name"
    end

    # OCSF Extended Identity
    attribute :uid_alt, :string do
      public? true
      description "Alternative unique identifier"
    end

    attribute :vendor_name, :string do
      default "ServiceRadar"
      public? true
      description "Agent vendor/author"
    end

    attribute :version, :string do
      public? true
      description "Agent semantic version"
    end

    # OCSF Policies (JSONB array)
    attribute :policies, {:array, :map} do
      default []
      public? true
      description "Policies applied to this agent (OCSF Policy objects)"
    end

    # ServiceRadar-specific fields
    attribute :poller_id, :string do
      public? true
      description "Poller this agent is connected to"
    end

    attribute :device_uid, :string do
      public? true
      description "Device this agent runs on"
    end

    attribute :capabilities, {:array, :string} do
      default []
      public? true
      description "Agent capabilities (e.g., 'ping', 'snmp', 'http')"
    end

    attribute :host, :string do
      public? true
      description "Host IP or hostname the agent listens on"
    end

    attribute :port, :integer do
      public? true
      description "Port the agent listens on for gRPC"
    end

    attribute :spiffe_identity, :string do
      public? true
      description "SPIFFE ID for mTLS authentication"
    end

    attribute :status, :atom do
      allow_nil? false
      default :connecting
      public? true
      constraints one_of: [:connecting, :connected, :degraded, :disconnected, :unavailable]
      description "Current lifecycle state (state machine managed)"
    end

    attribute :is_healthy, :boolean do
      default true
      public? true
      description "Current health status"
    end

    # Temporal fields
    attribute :first_seen_time, :utc_datetime do
      public? true
      description "When agent was first seen"
    end

    attribute :last_seen_time, :utc_datetime do
      public? true
      description "When agent was last seen"
    end

    attribute :created_time, :utc_datetime do
      public? true
      description "Record creation time"
    end

    attribute :modified_time, :utc_datetime do
      public? true
      description "Record modification time"
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
      description "Tenant this agent belongs to"
    end
  end

  relationships do
    belongs_to :poller, ServiceRadar.Infrastructure.Poller do
      source_attribute :poller_id
      destination_attribute :id
      allow_nil? true
      public? true
    end

    belongs_to :device, ServiceRadar.Inventory.Device do
      source_attribute :device_uid
      destination_attribute :uid
      allow_nil? true
      public? true
    end

    has_many :checkers, ServiceRadar.Infrastructure.Checker do
      source_attribute :uid
      destination_attribute :agent_uid
      public? true
    end
  end

  calculations do
    calculate :type_name,
              :string,
              expr(
                cond do
                  not is_nil(type) -> type
                  type_id == 0 -> "Unknown"
                  type_id == 1 -> "EDR"
                  type_id == 2 -> "DLP"
                  type_id == 3 -> "Backup/Recovery"
                  type_id == 4 -> "Performance"
                  type_id == 5 -> "Vulnerability"
                  type_id == 6 -> "Log Management"
                  type_id == 7 -> "MDM"
                  type_id == 8 -> "Config Management"
                  type_id == 9 -> "Remote Access"
                  type_id == 99 -> "Other"
                  true -> "Unknown"
                end
              )

    calculate :display_name,
              :string,
              expr(
                cond do
                  not is_nil(name) -> name
                  not is_nil(host) -> host
                  true -> uid
                end
              )

    calculate :is_online,
              :boolean,
              expr(
                status == :connected and
                  is_healthy == true and
                  last_seen_time > ago(5, :minute)
              )

    calculate :status_color,
              :string,
              expr(
                cond do
                  status == :connected and is_healthy == true -> "green"
                  status == :connected and is_healthy == false -> "yellow"
                  status == :degraded -> "yellow"
                  status == :connecting -> "blue"
                  status == :disconnected -> "red"
                  status == :unavailable -> "gray"
                  true -> "gray"
                end
              )

    calculate :status_label,
              :string,
              expr(
                cond do
                  status == :connected -> "Connected"
                  status == :connecting -> "Connecting"
                  status == :degraded -> "Degraded"
                  status == :disconnected -> "Disconnected"
                  status == :unavailable -> "Unavailable"
                  true -> "Unknown"
                end
              )

    calculate :endpoint,
              :string,
              expr(
                if not is_nil(host) and not is_nil(port) do
                  host <> ":" <> fragment("?::text", port)
                else
                  nil
                end
              )
  end

  identities do
    identity :unique_uid, [:uid]
  end
end
