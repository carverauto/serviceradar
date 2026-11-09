defmodule ServiceRadar.Edge.PipelineSetting do
  @moduledoc """
  Operator settings for the durable edge-record pipeline at one scope.

  `scope` is `:global` (`scope_key` empty), `:partition` (`scope_key` is the partition id,
  which is also the network scope of its agents) or `:agent` (`scope_key` is the agent uid).
  A field left `nil` inherits from the wider scope, and `max_horizon_seconds` lives only on
  the global row. `ServiceRadar.Edge.PipelineSettings.resolve/2` combines them.

  The pipeline itself has no switch; these are its knobs: how far ahead sweeps are leased,
  and the agent spool byte budget. No row is needed for either.
  """

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @fields [:scope, :scope_key, :horizon_seconds, :max_horizon_seconds, :spool_max_bytes]

  postgres do
    table "edge_pipeline_settings"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      description "Set the edge pipeline settings of one scope"
      accept @fields
      upsert? true
      upsert_identity :unique_scope
      upsert_fields [:horizon_seconds, :max_horizon_seconds, :spool_max_bytes, :updated_at]
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

    attribute :spool_max_bytes, :integer do
      public? true
      constraints min: 64 * 1024 * 1024

      description "The agent edge-record spool byte budget (minimum 64 MiB); nil inherits, and the default is 1 GiB"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_scope, [:scope, :scope_key]
  end
end
