defmodule ServiceRadar.Monitoring.NetperfResponder do
  @moduledoc """
  Enables Hub Responder mode (`5199/TCP` mTLS + optional `5199/UDP` HMAC) on
  an enrolled `ServiceRadar.Infrastructure.Agent`.
  """

  use Ash.Resource,
    domain: ServiceRadar.Monitoring,
    data_layer: AshPostgres.DataLayer,
    notifiers: [ServiceRadar.AgentConfig.DependencyNotifier],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Monitoring.NetperfPolicyResponder
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @manage_check {ActorHasPermission, permission: "settings.networks.manage"}

  @create_fields [
    :agent_uid,
    :name,
    :enabled,
    :advertise_address,
    :listen_port,
    :udp_enabled,
    :max_concurrent_sessions,
    :max_total_bandwidth_bps
  ]

  @update_fields [
    :name,
    :enabled,
    :advertise_address,
    :listen_port,
    :udp_enabled,
    :max_concurrent_sessions,
    :max_total_bandwidth_bps
  ]

  postgres do
    table "netperf_responders"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :agent, on_delete: :delete
    end

    check_constraints do
      check_constraint :listen_port, "netperf_responders_listen_port_check",
        check: "listen_port >= 1 AND listen_port <= 65535",
        message: "must be between 1 and 65535"

      check_constraint :max_concurrent_sessions,
                       "netperf_responders_max_concurrent_sessions_check",
                       check: "max_concurrent_sessions >= 1 AND max_concurrent_sessions <= 64",
                       message: "must be between 1 and 64"

      check_constraint :max_total_bandwidth_bps,
                       "netperf_responders_max_total_bandwidth_bps_check",
                       check:
                         "max_total_bandwidth_bps >= 100000 AND max_total_bandwidth_bps <= 100000000000",
                       message: "must be between 100000 and 100000000000 bps"

      check_constraint :authority_epoch, "netperf_responders_authority_epoch_check",
        check: "authority_epoch >= 1",
        message: "must be at least 1"
    end
  end

  code_interface do
    define :list, action: :read
    define :list_enabled, action: :enabled
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_agent_uid, action: :by_agent_uid, args: [:agent_uid]
    define :create_responder, action: :create
    define :update_responder, action: :update
    define :enable_responder, action: :enable
    define :disable_responder, action: :disable
    define :bump_authority_epoch, action: :bump_authority_epoch
    define :delete_responder, action: :destroy
  end

  actions do
    defaults [:read, :destroy]

    read :enabled do
      filter expr(enabled == true)
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_agent_uid do
      argument :agent_uid, :string, allow_nil?: false
      get? true
      filter expr(agent_uid == ^arg(:agent_uid))
    end

    create :create do
      accept @create_fields
    end

    update :update do
      accept @update_fields
    end

    update :enable do
      accept []
      change set_attribute(:enabled, true)
    end

    update :disable do
      accept []
      change set_attribute(:enabled, false)
      change atomic_update(:authority_epoch, expr(authority_epoch + 1))
    end

    update :bump_authority_epoch do
      accept []
      change atomic_update(:authority_epoch, expr(authority_epoch + 1))
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    action_type_with_permission([:create, :update, :destroy], @manage_check)
  end

  attributes do
    uuid_primary_key :id

    attribute :agent_uid, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :enabled, :boolean do
      allow_nil? false
      default true
      public? true
    end

    attribute :advertise_address, :string do
      allow_nil? true
      public? true
    end

    attribute :listen_port, :integer do
      allow_nil? false
      default 5199
      public? true
      constraints min: 1, max: 65_535
    end

    attribute :udp_enabled, :boolean do
      allow_nil? false
      default true
      public? true
    end

    attribute :max_concurrent_sessions, :integer do
      allow_nil? false
      default 4
      public? true
      constraints min: 1, max: 64
    end

    attribute :max_total_bandwidth_bps, :integer do
      allow_nil? false
      default 1_000_000_000
      public? true
      constraints min: 100_000, max: 100_000_000_000
    end

    attribute :authority_epoch, :integer do
      allow_nil? false
      default 1
      public? true
      constraints min: 1
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :agent, ServiceRadar.Infrastructure.Agent do
      source_attribute :agent_uid
      destination_attribute :uid
      define_attribute? false
      allow_nil? false
      public? true
    end

    has_many :policy_responders, NetperfPolicyResponder do
      destination_attribute :responder_id
      public? true
    end

    many_to_many :policies, ServiceRadar.Monitoring.NetperfPolicy do
      through NetperfPolicyResponder
      source_attribute_on_join_resource :responder_id
      destination_attribute_on_join_resource :policy_id
      public? true
    end
  end

  identities do
    identity :unique_agent_uid, [:agent_uid]
  end
end
