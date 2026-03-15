defmodule ServiceRadar.Plugins.PluginPackage do
  @moduledoc """
  Wasm plugin package metadata and import review state.

  Each record represents a specific plugin version (plugin_id + version).
  Packages are staged on import and require explicit approval before use.
  """

  use Ash.Resource,
    domain: ServiceRadar.Plugins,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine]

  @package_fields [
    :name,
    :description,
    :entrypoint,
    :runtime,
    :outputs,
    :manifest,
    :config_schema,
    :display_contract,
    :wasm_object_key,
    :content_hash,
    :signature,
    :source_type,
    :source_repo_url,
    :source_commit,
    :gpg_key_id,
    :gpg_verified_at
  ]

  @package_create_fields [:plugin_id, :version | @package_fields]
  @approval_fields [
    :approved_capabilities,
    :approved_permissions,
    :approved_resources,
    :approved_by
  ]
  @denial_fields [:denied_reason]

  postgres do
    table "plugin_packages"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :plugin, on_delete: :delete
    end
  end

  state_machine do
    initial_states [:staged]
    default_initial_state :staged
    state_attribute :status

    transitions do
      transition :approve, from: :staged, to: :approved
      transition :deny, from: :staged, to: :denied
      transition :revoke, from: [:approved], to: :revoked
      transition :restage, from: [:denied, :revoked], to: :staged
    end
  end

  actions do
    defaults [:read, :destroy]

    read :by_plugin_id do
      argument :plugin_id, :string, allow_nil?: false
      filter expr(plugin_id == ^arg(:plugin_id))
    end

    read :approved do
      description "Approved plugin packages"
      filter expr(status == :approved)
    end

    create :create do
      accept @package_create_fields

      validate ServiceRadar.Plugins.Validations.Manifest
    end

    update :update do
      accept @package_fields

      validate ServiceRadar.Plugins.Validations.Manifest
    end

    update :approve do
      description "Approve a staged plugin package for distribution"

      accept @approval_fields

      change transition_state(:approved)
      change set_attribute(:approved_at, &DateTime.utc_now/0)
    end

    update :deny do
      description "Deny a staged plugin package"
      accept @denial_fields

      change transition_state(:denied)
    end

    update :revoke do
      description "Revoke an approved plugin package"
      accept @denial_fields

      change transition_state(:revoked)
    end

    update :restage do
      description "Move a denied or revoked package back to staged"
      accept []

      change transition_state(:staged)
      change set_attribute(:denied_reason, nil)
      change set_attribute(:approved_at, nil)
    end
  end

  policies do
    import ServiceRadar.Plugins.Policies

    manage_action_types()
  end

  attributes do
    uuid_primary_key :id

    attribute :plugin_id, :string do
      allow_nil? false
      public? true
      description "Plugin identifier from manifest"
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Human-readable name"
    end

    attribute :version, :string do
      allow_nil? false
      public? true
      description "Plugin version (semver)"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
    end

    attribute :entrypoint, :string do
      allow_nil? false
      public? true
    end

    attribute :runtime, :string do
      allow_nil? true
      public? true
    end

    attribute :outputs, :string do
      allow_nil? false
      public? true
    end

    attribute :manifest, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :config_schema, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :display_contract, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :wasm_object_key, :string do
      allow_nil? true
      public? true
      description "Object store key for the wasm blob"
    end

    attribute :content_hash, :string do
      allow_nil? true
      public? true
      description "SHA256 of the package contents"
    end

    attribute :signature, :map do
      allow_nil? false
      public? true
      default %{}
      description "Signature metadata"
    end

    attribute :source_type, :atom do
      allow_nil? false
      public? true
      default :upload
      constraints one_of: [:upload, :github]
    end

    attribute :source_repo_url, :string do
      allow_nil? true
      public? true
    end

    attribute :source_commit, :string do
      allow_nil? true
      public? true
    end

    attribute :gpg_key_id, :string do
      allow_nil? true
      public? true
    end

    attribute :gpg_verified_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :staged
      constraints one_of: [:staged, :approved, :denied, :revoked]
    end

    attribute :approved_capabilities, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :approved_permissions, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :approved_resources, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :approved_by, :string do
      allow_nil? true
      public? true
    end

    attribute :approved_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :denied_reason, :string do
      allow_nil? true
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :plugin, ServiceRadar.Plugins.Plugin do
      allow_nil? false
      public? true
      source_attribute :plugin_id
      destination_attribute :plugin_id
      define_attribute? false
    end

    has_many :assignments, ServiceRadar.Plugins.PluginAssignment do
      destination_attribute :plugin_package_id
    end
  end

  identities do
    identity :unique_plugin_version, [:plugin_id, :version]
  end
end
