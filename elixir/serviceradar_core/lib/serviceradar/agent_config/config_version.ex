defmodule ServiceRadar.AgentConfig.ConfigVersion do
  @moduledoc """
  Version history for configuration instances.

  Tracks all versions of a config instance for audit and rollback purposes.
  """

  use Ash.Resource,
    domain: ServiceRadar.AgentConfig,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require ServiceRadar.AgentConfig.ResourceAttributes

  @create_fields [
    :config_instance_id,
    :version,
    :compiled_config,
    :content_hash,
    :source_ids,
    :actor_id,
    :actor_email,
    :change_reason
  ]

  postgres do
    table("agent_config_versions")
    repo(ServiceRadar.Repo)
    schema("platform")

    custom_indexes do
      index([:config_instance_id, :version],
        unique: true,
        name: "agent_config_versions_instance_version_idx"
      )
    end
  end

  actions do
    defaults([:read])

    create :create do
      accept(@create_fields)
    end

    read :for_instance do
      argument(:config_instance_id, :uuid, allow_nil?: false)

      filter(expr(config_instance_id == ^arg(:config_instance_id)))

      prepare(build(sort: [version: :desc]))
    end

    read :by_version do
      argument(:config_instance_id, :uuid, allow_nil?: false)
      argument(:version, :integer, allow_nil?: false)

      get?(true)

      filter(
        expr(
          config_instance_id == ^arg(:config_instance_id) and
            version == ^arg(:version)
        )
      )
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    admin_action_type([:read, :create])
  end

  attributes do
    uuid_primary_key(:id)

    attribute :config_instance_id, :uuid do
      allow_nil?(false)
      public?(true)
      description("The config instance this version belongs to")
    end

    attribute :version, :integer do
      allow_nil?(false)
      public?(true)
      description("Version number")
    end

    ServiceRadar.AgentConfig.ResourceAttributes.config_snapshot_attributes(
      compiled_config_description: "Compiled configuration at this version",
      content_hash_description: "SHA256 hash of compiled_config",
      source_ids_description: "IDs of source resources at this version"
    )

    attribute :actor_id, :uuid do
      allow_nil?(true)
      public?(true)
      description("ID of user who made this change")
    end

    attribute :actor_email, :string do
      allow_nil?(true)
      public?(true)
      description("Email of user who made this change")
    end

    attribute :change_reason, :string do
      allow_nil?(true)
      public?(true)
      description("Reason for this version change")
    end

    create_timestamp(:created_at)
  end

  relationships do
    belongs_to :config_instance, ServiceRadar.AgentConfig.ConfigInstance do
      allow_nil?(false)
      attribute_type(:uuid)
      define_attribute?(false)
      destination_attribute(:id)
      source_attribute(:config_instance_id)
    end
  end
end
