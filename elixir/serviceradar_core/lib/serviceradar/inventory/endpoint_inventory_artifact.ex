defmodule ServiceRadar.Inventory.EndpointInventoryArtifact do
  @moduledoc """
  Durable raw SBOM artifact metadata for an endpoint inventory scan.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "endpoint_inventory_artifacts"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :list_by_scan, action: :by_scan, args: [:scan_ref]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :scan_ref,
        :artifact_content_ref,
        :agent_id,
        :device_uid,
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
        :uploaded_at,
        :reused_content,
        :metadata
      ]
    end

    read :by_scan do
      argument :scan_ref, :uuid, allow_nil?: false
      filter expr(scan_ref == ^arg(:scan_ref))
      prepare build(sort: [inserted_at: :desc])
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

    attribute :scan_ref, :uuid do
      allow_nil? false
      public? true
    end

    attribute :artifact_content_ref, :uuid do
      public? true
    end

    attribute :agent_id, :string do
      allow_nil? false
      public? true
    end

    attribute :device_uid, :string do
      public? true
    end

    attribute :artifact_hash, :string do
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

    attribute :uploaded_at, :utc_datetime_usec do
      public? true
    end

    attribute :reused_content, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :scan, ServiceRadar.Inventory.EndpointInventoryScan do
      source_attribute :scan_ref
      destination_attribute :id
      define_attribute? false
      allow_nil? false
      public? true
    end

    belongs_to :content, ServiceRadar.Inventory.EndpointInventoryArtifactContent do
      source_attribute :artifact_content_ref
      destination_attribute :id
      define_attribute? false
      allow_nil? true
      public? true
    end
  end
end
