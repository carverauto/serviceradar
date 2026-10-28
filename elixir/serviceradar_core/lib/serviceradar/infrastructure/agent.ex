defmodule ServiceRadar.Infrastructure.Agent do
  @moduledoc """
  Agent resource for managing Go agents (OCSF v1.4.0 Agent object).

  Agents are Go processes that run on monitored hosts, proxying service checks
  to local checkers. They connect to gateways via gRPC and are tracked in the
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

  use Ash.Resource,
    domain: ServiceRadar.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    notifiers: [ServiceRadar.AgentConfig.DependencyNotifier],
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, AshJsonApi.Resource]

  alias ServiceRadar.Infrastructure.Changes.EnsureStateMonitor
  alias ServiceRadar.Infrastructure.Changes.PublishStateChange
  alias ServiceRadar.Infrastructure.Preparations.AgentPicker

  @capability_definitions %{
    icmp: %{
      icon: "hero-signal",
      color: "info",
      description: "ICMP ping checks for host reachability"
    },
    tcp: %{
      icon: "hero-server-stack",
      color: "success",
      description: "TCP port checks for service availability"
    },
    http: %{icon: "hero-globe-alt", color: "warning", description: "HTTP/HTTPS endpoint checks"},
    grpc: %{
      icon: "hero-cpu-chip",
      color: "secondary",
      description: "gRPC health checks via external checkers"
    },
    dns: %{icon: "hero-at-symbol", color: "info", description: "DNS resolution checks"},
    process: %{icon: "hero-cog-6-tooth", color: "accent", description: "Local process monitoring"},
    snmp: %{
      icon: "hero-chart-bar",
      color: "accent",
      description: "SNMP monitoring via external checker"
    },
    sweep: %{
      icon: "hero-magnifying-glass",
      color: "primary",
      description: "Network sweep/discovery"
    },
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
    Map.get(@capability_definitions, capability, %{
      icon: "hero-cube",
      color: "ghost",
      description: to_string(capability)
    })
  end

  def capability_info(capability) when is_binary(capability) do
    case capability do
      "host-network-visibility" ->
        %{icon: "hero-eye", color: "primary", description: "Host network visibility sidecar"}

      "host-network-visibility." <> _surface ->
        %{icon: "hero-eye", color: "ghost", description: capability}

      "icmp.unavailable" ->
        %{
          icon: "hero-signal-slash",
          color: "warning",
          description:
            "The agent cannot open raw ICMP sockets (it needs CAP_NET_RAW or root), " <>
              "so ICMP sweeps are not assigned to it"
        }

      "mtr.unavailable" ->
        %{
          icon: "hero-signal-slash",
          color: "warning",
          description:
            "The agent cannot open ICMP sockets for traceroute, " <>
              "so MTR sweeps and traces are not assigned to it"
        }

      _ ->
        capability_info(String.to_existing_atom(capability))
    end
  rescue
    ArgumentError -> %{icon: "hero-cube", color: "ghost", description: capability}
  end

  @doc "Returns OCSF type names map"
  def type_names, do: @type_names

  @doc "Returns type name for a given type_id"
  def type_name(type_id), do: Map.get(@type_names, type_id, "Unknown")

  @doc """
  Label shown for an agent.

  The operator-facing display name wins, then the gateway-reported name,
  then the reported host, then the uid.
  """
  def listed_name(agent) when is_map(agent) do
    first_present([
      map_field(agent, :display_name),
      map_field(agent, :name),
      map_field(agent, :host),
      map_field(agent, :uid)
    ])
  end

  defp map_field(agent, key) do
    case Map.get(agent, Atom.to_string(key)) do
      nil -> Map.get(agent, key)
      value -> value
    end
  end

  defp first_present(values) do
    Enum.find_value(values, "—", &present_label/1)
  end

  defp present_label(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_label(_value), do: nil

  @cert_lifecycle_fields [
    :cert_not_before,
    :cert_expires_at,
    :cert_serial,
    :cert_fingerprint_sha256,
    :cert_renewed_at
  ]
  @agent_registration_fields [
                               :uid,
                               :name,
                               :type_id,
                               :type,
                               :uid_alt,
                               :vendor_name,
                               :version,
                               :policies,
                               :gateway_id,
                               :device_uid,
                               :capabilities,
                               :host,
                               :ip,
                               :port,
                               :spiffe_identity,
                               :metadata
                             ] ++ @cert_lifecycle_fields
  @agent_connected_upsert_fields [
                                   :name,
                                   :type_id,
                                   :type,
                                   :uid_alt,
                                   :vendor_name,
                                   :version,
                                   :policies,
                                   :gateway_id,
                                   :device_uid,
                                   :capabilities,
                                   :host,
                                   :ip,
                                   :port,
                                   :spiffe_identity,
                                   :metadata,
                                   :last_seen_time,
                                   :modified_time,
                                   :status,
                                   :is_healthy
                                 ] ++ @cert_lifecycle_fields
  @agent_update_fields [
                         :name,
                         :capabilities,
                         :host,
                         :ip,
                         :port,
                         :policies,
                         :metadata,
                         :plugin_engine_max_memory_mb,
                         :plugin_engine_max_cpu_ms,
                         :plugin_engine_max_concurrent,
                         :plugin_engine_max_open_connections
                       ] ++ @cert_lifecycle_fields
  @agent_gateway_sync_fields [
                               :name,
                               :capabilities,
                               :host,
                               :port,
                               :spiffe_identity,
                               :metadata,
                               :gateway_id,
                               :version,
                               :ip,
                               :type_id,
                               :device_uid,
                               :config_source,
                               :desired_version,
                               :release_rollout_state,
                               :last_update_at,
                               :last_update_error
                             ] ++ @cert_lifecycle_fields
  @agent_heartbeat_fields [
                            :is_healthy,
                            :capabilities,
                            :config_source,
                            :gateway_id,
                            :host,
                            :ip
                          ] ++ @cert_lifecycle_fields
  @agent_config_ack_fields [:acked_config_version, :config_acked_at, :config_section_statuses]
  @agent_config_push_fields [:pushed_config_version, :config_pushed_at]
  @agent_gateway_fields [:gateway_id]
  @agent_device_fields [:device_uid]
  @agent_release_status_fields [
    :desired_version,
    :release_rollout_state,
    :last_update_at,
    :last_update_error,
    :version
  ]

  postgres do
    table "ocsf_agents"
    repo ServiceRadar.Repo
    schema "platform"
  end

  json_api do
    type "agent"

    routes do
      base "/agents"

      # Read operations
      get :by_uid
      index :read
      index :by_gateway, route: "/by-gateway/:gateway_id"

      # Admin/onboarding creates agent records (host:port known from onboarding package)
      post :register

      # Gateway updates agent status after connecting via gRPC
      patch :establish_connection, route: "/:id/connect"
      patch :update
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

      # Only :supersede enters :superseded, and only :revive_superseded leaves
      # it. :recover must not pull a replaced identity back into service.
      transition :supersede,
        from: [:connecting, :connected, :degraded, :disconnected, :unavailable],
        to: :superseded

      transition :revive_superseded, from: :superseded, to: :connected
    end
  end

  code_interface do
    define :get_by_uid, action: :by_uid, args: [:uid]
    define :list_by_gateway, action: :by_gateway, args: [:gateway_id]
    define :list_connected, action: :connected
  end

  actions do
    read :read do
      primary? true

      pagination keyset?: true,
                 required?: false,
                 default_limit: 250,
                 max_page_size: 5000
    end

    read :by_uid do
      argument :uid, :string, allow_nil?: false
      get? true
      filter expr(uid == ^arg(:uid))
    end

    read :by_gateway do
      argument :gateway_id, :string, allow_nil?: false
      filter expr(gateway_id == ^arg(:gateway_id))
    end

    read :by_device do
      argument :device_uid, :string, allow_nil?: false
      filter expr(device_uid == ^arg(:device_uid))
    end

    read :connected do
      description "All connected agents"

      filter expr(
               status == :connected and is_healthy == true and last_seen_time > ago(30, :minute)
             )
    end

    read :by_status do
      argument :status, :atom,
        allow_nil?: false,
        constraints: [
          one_of: [:connecting, :connected, :degraded, :disconnected, :unavailable, :superseded]
        ]

      filter expr(status == ^arg(:status))
    end

    read :by_capability do
      argument :capability, :string, allow_nil?: false
      filter expr(^arg(:capability) in capabilities)
    end

    read :agent_picker do
      description "A bounded, stable page of agents for the sweep-group picker"

      argument :search, :string, default: ""

      prepare AgentPicker

      pagination keyset?: true,
                 required?: true,
                 via_data_layer?: false,
                 default_limit: 50,
                 max_page_size: 50,
                 stable_sort: [picker_sort_key: :asc, uid: :asc]
    end

    read :recently_seen do
      description "Agents seen in the last 5 minutes"
      filter expr(last_seen_time > ago(5, :minute))
    end

    create :register do
      description "Register a new agent (starts in connecting state)"

      accept @agent_registration_fields

      change fn changeset, _context ->
        now = DateTime.utc_now()

        changeset
        |> Ash.Changeset.change_attribute(:first_seen_time, now)
        |> Ash.Changeset.change_attribute(:last_seen_time, now)
        |> Ash.Changeset.change_attribute(:created_time, now)
        |> Ash.Changeset.change_attribute(:is_healthy, true)
      end

      change EnsureStateMonitor
    end

    create :register_connected do
      description "Register a new agent as already connected (skips connecting state)"

      accept @agent_registration_fields

      upsert? true
      upsert_identity :unique_uid

      # A superseded row is revived only by :revive_superseded, which records
      # the decision. A failed WHERE surfaces as a stale record.
      upsert_condition expr(status != :superseded)

      upsert_fields @agent_connected_upsert_fields

      change fn changeset, _context ->
        now = DateTime.utc_now()

        changeset
        |> Ash.Changeset.change_new_attribute(:first_seen_time, now)
        |> Ash.Changeset.change_attribute(:last_seen_time, now)
        |> Ash.Changeset.change_new_attribute(:created_time, now)
        |> Ash.Changeset.change_attribute(:modified_time, now)
        |> Ash.Changeset.change_attribute(:status, :connected)
        |> Ash.Changeset.change_attribute(:is_healthy, true)
      end

      change EnsureStateMonitor
    end

    update :update do
      accept @agent_update_fields

      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :gateway_sync do
      description "Sync agent metadata from the agent-gateway"

      accept @agent_gateway_sync_fields

      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :update_certificate do
      description "Record active mTLS leaf certificate lifecycle metadata"

      accept @cert_lifecycle_fields

      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :edit_details do
      description "Set the operator-facing label and note. The uid and enrollment fields stay unchanged."

      accept [:display_name, :description]

      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :heartbeat do
      description "Update last_seen_time and health status (for connected agents)"
      accept @agent_heartbeat_fields

      change set_attribute(:last_seen_time, &DateTime.utc_now/0)
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    # State machine transition actions
    # Each action includes PublishStateChange to record health events

    update :establish_connection do
      description "Mark agent as connected (from connecting state)"
      accept @agent_gateway_fields

      change transition_state(:connected)
      change set_attribute(:is_healthy, true)
      change set_attribute(:last_seen_time, &DateTime.utc_now/0)
      change set_attribute(:modified_time, &DateTime.utc_now/0)

      change {PublishStateChange, entity_type: :agent, new_state: :connected}
    end

    update :connection_failed do
      description "Mark connection attempt as failed"

      change transition_state(:disconnected)
      change set_attribute(:modified_time, &DateTime.utc_now/0)

      change {PublishStateChange, entity_type: :agent, new_state: :disconnected}
    end

    update :degrade do
      description "Mark agent as degraded (connected but unhealthy)"

      change transition_state(:degraded)
      change set_attribute(:is_healthy, false)
      change set_attribute(:modified_time, &DateTime.utc_now/0)

      change {PublishStateChange, entity_type: :agent, new_state: :degraded}
    end

    update :restore_health do
      description "Restore agent health (from degraded to connected)"

      change transition_state(:connected)
      change set_attribute(:is_healthy, true)
      change set_attribute(:modified_time, &DateTime.utc_now/0)

      change {PublishStateChange, entity_type: :agent, new_state: :connected}
    end

    update :lose_connection do
      description "Mark agent as disconnected (connection lost)"

      change transition_state(:disconnected)
      change set_attribute(:gateway_id, nil)
      change set_attribute(:modified_time, &DateTime.utc_now/0)

      change {PublishStateChange, entity_type: :agent, new_state: :disconnected}
    end

    update :reconnect do
      description "Start reconnection process (from disconnected to connecting)"

      change transition_state(:connecting)
      change set_attribute(:modified_time, &DateTime.utc_now/0)

      change {PublishStateChange, entity_type: :agent, new_state: :connecting}
    end

    update :mark_unavailable do
      description "Mark agent as unavailable (admin action)"
      argument :reason, :string

      change transition_state(:unavailable)
      change set_attribute(:is_healthy, false)
      change set_attribute(:modified_time, &DateTime.utc_now/0)

      change {PublishStateChange, entity_type: :agent, new_state: :unavailable}
    end

    update :retire_stale do
      description "Retire a stale historical agent row from active operational views"

      change transition_state(:unavailable)
      change set_attribute(:is_healthy, false)
      change set_attribute(:gateway_id, nil)
      change set_attribute(:modified_time, &DateTime.utc_now/0)

      change {PublishStateChange, entity_type: :agent, new_state: :unavailable}
    end

    update :recover do
      description "Start recovery process (from unavailable to connecting)"

      change transition_state(:connecting)
      change set_attribute(:modified_time, &DateTime.utc_now/0)

      change {PublishStateChange, entity_type: :agent, new_state: :connecting}
    end

    update :supersede do
      description "Mark this identity superseded by another agent uid on the same device"
      argument :superseded_by, :string, allow_nil?: false

      change transition_state(:superseded)
      change set_attribute(:superseded_by, arg(:superseded_by))
      change set_attribute(:superseded_at, &DateTime.utc_now/0)
      change set_attribute(:is_healthy, false)
      change set_attribute(:modified_time, &DateTime.utc_now/0)

      change {PublishStateChange, entity_type: :agent, new_state: :superseded}
    end

    update :revive_superseded do
      description "Return a superseded identity to service after it reports in again"

      change transition_state(:connected)
      change set_attribute(:superseded_by, nil)
      change set_attribute(:superseded_at, nil)
      change set_attribute(:is_healthy, true)
      change set_attribute(:last_seen_time, &DateTime.utc_now/0)
      change set_attribute(:modified_time, &DateTime.utc_now/0)

      change {PublishStateChange, entity_type: :agent, new_state: :connected}
    end

    update :reassign_device do
      description "Reassign agent to a new device (used during merges)"
      accept @agent_device_fields
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :update_release_status do
      description "Sync desired version and rollout state for the agent"
      accept @agent_release_status_fields
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :record_config_ack do
      description "Record a config acknowledgement forwarded by the agent-gateway"
      accept @agent_config_ack_fields
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :record_config_section_statuses do
      description "Record the per-section config apply statuses an agent reported on its hello"
      accept [:config_section_statuses]
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :record_config_push do
      description "Record the config version most recently pushed to the agent"
      accept @agent_config_push_fields
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    update :set_config_health do
      description "Set config-apply health from wedge-detection evaluation"
      accept [:config_health]
      change set_attribute(:modified_time, &DateTime.utc_now/0)
    end

    # Legacy compatibility actions (mapped to state machine)
    update :connect do
      description "Mark agent as connected to a gateway (legacy - use establish_connection)"
      accept @agent_gateway_fields

      change transition_state(:connected)
      change set_attribute(:is_healthy, true)
      change set_attribute(:last_seen_time, &DateTime.utc_now/0)
      change set_attribute(:modified_time, &DateTime.utc_now/0)

      change {PublishStateChange, entity_type: :agent, new_state: :connected}
    end

    update :disconnect do
      description "Mark agent as disconnected (legacy - use lose_connection)"

      change transition_state(:disconnected)
      change set_attribute(:gateway_id, nil)
      change set_attribute(:modified_time, &DateTime.utc_now/0)

      change {PublishStateChange, entity_type: :agent, new_state: :disconnected}
    end

    update :mark_unhealthy do
      description "Mark agent as unhealthy (legacy - use degrade)"

      change transition_state(:degraded)
      change set_attribute(:is_healthy, false)
      change set_attribute(:modified_time, &DateTime.utc_now/0)

      change {PublishStateChange, entity_type: :agent, new_state: :degraded}
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    operator_action_type([:create, :update])
  end

  changes do
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
      description "Gateway-reported agent name"
    end

    attribute :display_name, :string do
      public? true
      constraints max_length: 200
      description "Operator-facing label. Does not change the agent uid or enrollment."
    end

    attribute :description, :string do
      public? true
      constraints max_length: 2000
      description "Operator note about this agent."
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

    attribute :desired_version, :string do
      public? true
      description "Desired version assigned by release management"
    end

    # OCSF Policies (JSONB array)
    attribute :policies, {:array, :map} do
      default []
      public? true
      description "Policies applied to this agent (OCSF Policy objects)"
    end

    # ServiceRadar-specific fields
    attribute :gateway_id, :string do
      public? true
      description "Gateway this agent is connected to"
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
      description "Hostname or host the agent reports"
    end

    attribute :ip, :string do
      public? true
      description "Source IP address for the agent connection when known"
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

      constraints one_of: [
                    :connecting,
                    :connected,
                    :degraded,
                    :disconnected,
                    :unavailable,
                    :superseded
                  ]

      description "Current lifecycle state (state machine managed)"
    end

    attribute :superseded_by, :string do
      public? true
      description "Agent uid that replaced this identity on the same device"
    end

    attribute :superseded_at, :utc_datetime do
      public? true
      description "When this identity was superseded. Set exactly while status is superseded"
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

    attribute :release_rollout_state, :atom do
      public? true

      constraints one_of: [
                    :pending,
                    :dispatched,
                    :downloading,
                    :verifying,
                    :staged,
                    :restarting,
                    :healthy,
                    :failed,
                    :rolled_back,
                    :canceled
                  ]

      description "Current release rollout state for this agent"
    end

    attribute :last_update_at, :utc_datetime do
      public? true
      description "Last time a managed release update state changed"
    end

    attribute :last_update_error, :string do
      public? true
      description "Last managed release update error"
    end

    attribute :config_source, :atom do
      public? true
      constraints one_of: [:remote, :local, :cached, :unassigned]

      description "Source of sysmon config: remote (from backend), local (file override), cached, or unassigned"
    end

    attribute :acked_config_version, :string do
      public? true
      description "Last config version the agent acknowledged (or reported committed)"
    end

    attribute :config_acked_at, :utc_datetime do
      public? true
      description "When the last config acknowledgement was recorded"
    end

    attribute :config_section_statuses, {:array, :map} do
      default []
      public? true

      description "Per-section config apply statuses from the last sectioned ack or " <>
                    "agent hello (empty for legacy whole-version acks)"
    end

    attribute :pushed_config_version, :string do
      public? true
      description "Config version most recently pushed to the agent over the control stream"
    end

    attribute :config_pushed_at, :utc_datetime do
      public? true

      description "Anchor of the oldest outstanding config push. A matching acked " <>
                    "version, or an ack at or after this time, lets the next push replace it"
    end

    attribute :config_health, :atom do
      default :unknown
      public? true
      constraints one_of: [:unknown, :healthy, :unhealthy]
      description "Config-apply health derived from acks and section statuses (wedge detection)"
    end

    attribute :plugin_engine_max_memory_mb, :integer do
      allow_nil? true
      public? true
      description "Max total memory (MB) for Wasm plugins on this agent"
    end

    attribute :plugin_engine_max_cpu_ms, :integer do
      allow_nil? true
      public? true
      description "Max total CPU time window (ms) for Wasm plugins on this agent"
    end

    attribute :plugin_engine_max_concurrent, :integer do
      allow_nil? true
      public? true
      description "Max number of concurrent Wasm plugin executions on this agent"
    end

    attribute :plugin_engine_max_open_connections, :integer do
      allow_nil? true
      public? true
      description "Max total open connections for Wasm plugins on this agent"
    end

    attribute :cert_not_before, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "NotBefore timestamp of the agent's active mTLS leaf certificate"
    end

    attribute :cert_expires_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "NotAfter expiration timestamp of the agent's active mTLS leaf certificate"
    end

    attribute :cert_serial, :string do
      allow_nil? true
      public? true
      description "Hex-encoded X.509 serial number of the agent's active mTLS leaf certificate"
    end

    attribute :cert_fingerprint_sha256, :string do
      allow_nil? true
      public? true
      description "Lowercase SHA-256 hex digest of the agent's active mTLS leaf certificate"
    end

    attribute :cert_renewed_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "Timestamp when the agent's mTLS leaf certificate was most recently renewed"
    end
  end

  relationships do
    belongs_to :gateway, ServiceRadar.Infrastructure.Gateway do
      source_attribute :gateway_id
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

    has_many :k8s_inventory_cluster_bindings,
             ServiceRadar.Infrastructure.K8sInventoryClusterBinding do
      source_attribute :uid
      destination_attribute :agent_id
      public? true
    end
  end

  calculations do
    calculate :picker_sort_key,
              :string,
              expr(fragment("lower(coalesce(?, ?))", name, uid))

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
                  status == :superseded -> "gray"
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
                  status == :superseded -> "Superseded"
                  true -> "Unknown"
                end
              )

    calculate :endpoint,
              :string,
              expr(
                if not is_nil(host) and not is_nil(port) do
                  fragment("? || ':' || ?::text", host, port)
                end
              )
  end

  identities do
    identity :unique_uid, [:uid]
  end
end
