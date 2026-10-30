defmodule ServiceRadar.SweepJobs.SweepLeaseSetting do
  @moduledoc """
  Operator settings for sweep schedule leases at one scope.

  `scope` is `:global` (`scope_key` empty), `:partition` (`scope_key` is the partition id,
  which is also the network scope of its agents) or `:agent` (`scope_key` is the agent uid).
  A field left `nil` inherits from the wider scope, and `max_horizon_seconds` lives only on
  the global row. `ServiceRadar.SweepJobs.LeaseSettings.resolve/2` combines them.
  """

  use Ash.Resource,
    domain: ServiceRadar.SweepJobs,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @fields [:scope, :scope_key, :leasing_enabled, :horizon_seconds, :max_horizon_seconds]

  postgres do
    table "sweep_lease_settings"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      description "Set the lease settings of one scope"
      accept @fields
      upsert? true
      upsert_identity :unique_scope
      upsert_fields [:leasing_enabled, :horizon_seconds, :max_horizon_seconds, :updated_at]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    admin_action(:upsert)
    admin_action_type(:destroy)
  end

  attributes do
    uuid_primary_key :id

    attribute :scope, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:global, :partition, :agent]
    end

    attribute :scope_key, :string do
      allow_nil? false
      default ""
      public? true
      constraints allow_empty?: true
      description "Empty for the global scope, the partition id, or the agent uid"
    end

    attribute :leasing_enabled, :boolean do
      public? true

      description "Whether core schedules sweeps ahead of time; nil inherits, and the default is off"
    end

    attribute :horizon_seconds, :integer do
      public? true
      constraints min: 1
      description "How far ahead sweeps are scheduled; nil inherits"
    end

    attribute :max_horizon_seconds, :integer do
      public? true
      constraints min: 1
      description "Administrator ceiling on any horizon (global scope only)"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_scope, [:scope, :scope_key]
  end
end
