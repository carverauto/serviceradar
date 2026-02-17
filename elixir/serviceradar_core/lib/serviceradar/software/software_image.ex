defmodule ServiceRadar.Software.SoftwareImage do
  @moduledoc """
  A firmware or software image stored in the software library.

  Images go through a lifecycle:
    uploaded → verified → active → archived → deleted

  Images can be served to agents via TFTP for device firmware upgrades
  and zero-touch provisioning.
  """

  use Ash.Resource,
    domain: ServiceRadar.Software,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine]

  postgres do
    table "software_images"
    repo ServiceRadar.Repo
    schema "platform"
  end

  state_machine do
    initial_states [:uploaded]
    default_initial_state :uploaded
    state_attribute :status

    transitions do
      transition :verify, from: :uploaded, to: :verified
      transition :activate, from: :verified, to: :active
      transition :archive, from: [:active, :verified], to: :archived
      transition :soft_delete, from: [:uploaded, :verified, :active, :archived], to: :deleted
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :name,
        :version,
        :description,
        :device_type,
        :content_hash,
        :file_size,
        :object_key,
        :signature,
        :filename
      ]

      change set_attribute(:status, :uploaded)
    end

    read :list do
      description "List software images"

      pagination do
        default_limit 25
        offset? true
        countable :by_default
      end
    end

    read :active do
      description "List active images available for serving"
      filter expr(status == :active)
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    update :verify do
      description "Mark image as verified after integrity check"
      accept []
    end

    update :activate do
      description "Mark image as active and available for serving"
      accept []
      require_atomic? false

      validate {ServiceRadar.Software.Validations.RequireSignature, []}
    end

    update :archive do
      description "Archive an image (no longer available for new sessions)"
      accept []
    end

    update :soft_delete do
      description "Soft-delete an image"
      accept []
    end

    update :update do
      accept [:name, :description, :device_type]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Human-readable name for this image"
    end

    attribute :version, :string do
      allow_nil? false
      public? true
      description "Version string (e.g. '15.2(4)M7', '4.2.1')"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
    end

    attribute :device_type, :string do
      allow_nil? true
      public? true
      description "Target device type (e.g. 'cisco-ios', 'junos', 'arista-eos')"
    end

    attribute :filename, :string do
      allow_nil? false
      public? true
      description "Original filename of the uploaded image"
    end

    attribute :content_hash, :string do
      allow_nil? true
      public? true
      description "SHA-256 hash of the image content"
    end

    attribute :file_size, :integer do
      allow_nil? true
      public? true
      description "File size in bytes"
    end

    attribute :object_key, :string do
      allow_nil? true
      public? true
      description "Storage object key (local path or S3 key)"
    end

    attribute :signature, :map do
      allow_nil? true
      public? true
      description "Optional signature metadata (type, key_id, verified_at, etc.)"
    end

    attribute :status, :atom do
      allow_nil? false
      default :uploaded
      public? true
      constraints one_of: [:uploaded, :verified, :active, :archived, :deleted]
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_name_version, [:name, :version]
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:read) do
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "settings.software.view"}
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "settings.software.manage"}
    end

    policy action(:create) do
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "software.image.upload"}
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "settings.software.manage"}
    end

    policy action([:verify, :activate, :archive, :update]) do
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "settings.software.manage"}
    end

    policy action([:soft_delete, :destroy]) do
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "software.image.delete"}
      authorize_if {ServiceRadar.Policies.Checks.ActorHasPermission,
                    permission: "settings.software.manage"}
    end
  end
end
