defmodule ServiceRadar.AgentConfig.ConfigVersion do
  @moduledoc """
  Version history for configuration instances.

  Tracks all versions of a config instance for audit and rollback purposes.
  """

  use Ash.Resource,
    domain: ServiceRadar.AgentConfig,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "agent_config_versions"
    repo ServiceRadar.Repo

    custom_indexes do
      index [:config_instance_id, :version],
        unique: true,
        name: "agent_config_versions_instance_version_idx"

      index [:tenant_id, :created_at],
        name: "agent_config_versions_tenant_created_idx"
    end
  end

  multitenancy do
    strategy :context
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :config_instance_id,
        :version,
        :compiled_config,
        :content_hash,
        :source_ids,
        :actor_id,
        :actor_email,
        :change_reason
      ]

    end

    read :for_instance do
      argument :config_instance_id, :uuid, allow_nil?: false

      filter expr(config_instance_id == ^arg(:config_instance_id))

      prepare build(sort: [version: :desc])
    end

    read :by_version do
      argument :config_instance_id, :uuid, allow_nil?: false
      argument :version, :integer, allow_nil?: false

      get? true

      filter expr(
               config_instance_id == ^arg(:config_instance_id) and
                 version == ^arg(:version)
             )
    end
  end

  policies do
    # Super admins can do anything
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # System actors can perform all operations (tenant isolation via schema)
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    # Tenant admins can read version history
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # System creates versions (use authorize?: false when calling)
    policy action_type(:create) do
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
      description "Tenant this version belongs to"
    end

    attribute :config_instance_id, :uuid do
      allow_nil? false
      public? true
      description "The config instance this version belongs to"
    end

    attribute :version, :integer do
      allow_nil? false
      public? true
      description "Version number"
    end

    attribute :compiled_config, :map do
      allow_nil? false
      public? true
      default %{}
      description "Compiled configuration at this version"
    end

    attribute :content_hash, :string do
      allow_nil? false
      public? true
      description "SHA256 hash of compiled_config"
    end

    attribute :source_ids, {:array, :uuid} do
      allow_nil? false
      public? true
      default []
      description "IDs of source resources at this version"
    end

    attribute :actor_id, :uuid do
      allow_nil? true
      public? true
      description "ID of user who made this change"
    end

    attribute :actor_email, :string do
      allow_nil? true
      public? true
      description "Email of user who made this change"
    end

    attribute :change_reason, :string do
      allow_nil? true
      public? true
      description "Reason for this version change"
    end

    create_timestamp :created_at
  end

  relationships do
    belongs_to :config_instance, ServiceRadar.AgentConfig.ConfigInstance do
      allow_nil? false
      attribute_type :uuid
      define_attribute? false
      destination_attribute :id
      source_attribute :config_instance_id
    end
  end
end
