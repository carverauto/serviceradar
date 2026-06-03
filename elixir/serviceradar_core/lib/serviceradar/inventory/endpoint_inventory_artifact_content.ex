defmodule ServiceRadar.Inventory.EndpointInventoryArtifactContent do
  @moduledoc """
  Content-addressed raw SBOM artifact object metadata.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "endpoint_inventory_artifact_contents"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :get_by_artifact_hash, action: :by_artifact_hash, args: [:artifact_hash]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :artifact_hash,
        :object_key,
        :bucket,
        :domain,
        :content_type,
        :format,
        :spec_version,
        :sha256,
        :size_bytes,
        :storage_backend,
        :first_uploaded_at,
        :last_referenced_at,
        :reference_count,
        :metadata
      ]
    end

    read :by_artifact_hash do
      argument :artifact_hash, :string, allow_nil?: false
      get? true
      filter expr(artifact_hash == ^arg(:artifact_hash))
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    operator_action_type(:create)
    admin_action_type(:destroy)
  end

  attributes do
    uuid_primary_key :id

    attribute :artifact_hash, :string do
      allow_nil? false
      public? true
    end

    attribute :object_key, :string do
      allow_nil? false
      public? true
    end

    attribute :bucket, :string do
      public? true
    end

    attribute :domain, :string do
      public? true
    end

    attribute :content_type, :string do
      allow_nil? false
      default "application/json"
      public? true
    end

    attribute :format, :string do
      allow_nil? false
      default "CycloneDX"
      public? true
    end

    attribute :spec_version, :string do
      public? true
    end

    attribute :sha256, :string do
      allow_nil? false
      public? true
    end

    attribute :size_bytes, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :storage_backend, :string do
      allow_nil? false
      default "datasvc_object_store"
      public? true
    end

    attribute :first_uploaded_at, :utc_datetime_usec do
      public? true
    end

    attribute :last_referenced_at, :utc_datetime_usec do
      public? true
    end

    attribute :reference_count, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :scan_artifacts, ServiceRadar.Inventory.EndpointInventoryArtifact do
      source_attribute :id
      destination_attribute :artifact_content_ref
      public? true
    end
  end

  identities do
    identity :unique_artifact_hash, [:artifact_hash]
    identity :unique_object_key, [:object_key]
  end
end
