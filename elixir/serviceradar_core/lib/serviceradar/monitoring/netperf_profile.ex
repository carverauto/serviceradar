defmodule ServiceRadar.Monitoring.NetperfProfile do
  @moduledoc """
  Reusable bounded network performance test profile for embedded agent netperf.

  Defines protocol, direction, paced bandwidth ceiling, duration, omit warm-up
  window, parallel streams, UDP/TCP payload length, and recurring interval.
  """

  use Ash.Resource,
    domain: ServiceRadar.Monitoring,
    data_layer: AshPostgres.DataLayer,
    notifiers: [ServiceRadar.AgentConfig.DependencyNotifier],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Monitoring.Validations.NetperfProfileOmitDuration
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @manage_check {ActorHasPermission, permission: "settings.networks.manage"}

  @fields [
    :name,
    :description,
    :protocol,
    :direction,
    :bandwidth_bps,
    :duration_sec,
    :omit_sec,
    :parallel,
    :packet_length,
    :interval_seconds
  ]

  postgres do
    table "netperf_profiles"
    repo ServiceRadar.Repo
    schema "platform"

    check_constraints do
      check_constraint :protocol, "netperf_profiles_protocol_check",
        check: "protocol IN ('tcp', 'udp')",
        message: "must be tcp or udp"

      check_constraint :direction, "netperf_profiles_direction_check",
        check: "direction IN ('upload', 'download', 'bidirectional')",
        message: "must be upload, download, or bidirectional"

      check_constraint :bandwidth_bps, "netperf_profiles_bandwidth_bps_check",
        check: "bandwidth_bps >= 100000 AND bandwidth_bps <= 10000000000",
        message: "must be between 100000 and 10000000000 bps"

      check_constraint :duration_sec, "netperf_profiles_duration_sec_check",
        check: "duration_sec >= 1 AND duration_sec <= 30",
        message: "must be between 1 and 30 seconds"

      check_constraint :omit_sec, "netperf_profiles_omit_sec_check",
        check: "omit_sec >= 0 AND omit_sec <= 5 AND omit_sec < duration_sec",
        message: "must be between 0 and 5 seconds and strictly less than duration_sec"

      check_constraint :parallel, "netperf_profiles_parallel_check",
        check: "parallel >= 1 AND parallel <= 8",
        message: "must be between 1 and 8 streams"

      check_constraint :packet_length, "netperf_profiles_packet_length_check",
        check: "packet_length >= 64 AND packet_length <= 65507",
        message: "must be between 64 and 65507 bytes"

      check_constraint :interval_seconds, "netperf_profiles_interval_seconds_check",
        check: "interval_seconds >= 60 AND interval_seconds <= 86400",
        message: "must be between 60 and 86400 seconds"
    end
  end

  code_interface do
    define :list, action: :read
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_name, action: :by_name, args: [:name]
    define :create_profile, action: :create
    define :update_profile, action: :update
    define :delete_profile, action: :destroy
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_name do
      argument :name, :string, allow_nil?: false
      get? true
      filter expr(name == ^arg(:name))
    end

    create :create do
      accept @fields
      validate NetperfProfileOmitDuration
    end

    update :update do
      accept @fields
      validate NetperfProfileOmitDuration
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

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :description, :string do
      allow_nil? true
      public? true
    end

    attribute :protocol, :atom do
      allow_nil? false
      default :tcp
      public? true
      constraints one_of: [:tcp, :udp]
    end

    attribute :direction, :atom do
      allow_nil? false
      default :upload
      public? true
      constraints one_of: [:upload, :download, :bidirectional]
    end

    attribute :bandwidth_bps, :integer do
      allow_nil? false
      default 50_000_000
      public? true
      constraints min: 100_000, max: 10_000_000_000
    end

    attribute :duration_sec, :integer do
      allow_nil? false
      default 5
      public? true
      constraints min: 1, max: 30
    end

    attribute :omit_sec, :integer do
      allow_nil? false
      default 1
      public? true
      constraints min: 0, max: 5
    end

    attribute :parallel, :integer do
      allow_nil? false
      default 1
      public? true
      constraints min: 1, max: 8
    end

    attribute :packet_length, :integer do
      allow_nil? false
      default 1200
      public? true
      constraints min: 64, max: 65_507
    end

    attribute :interval_seconds, :integer do
      allow_nil? false
      default 900
      public? true
      constraints min: 60, max: 86_400
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :policies, ServiceRadar.Monitoring.NetperfPolicy do
      destination_attribute :profile_id
      public? true
    end
  end

  identities do
    identity :unique_name, [:name]
  end
end
