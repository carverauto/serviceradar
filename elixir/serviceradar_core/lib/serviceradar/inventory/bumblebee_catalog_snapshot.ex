defmodule ServiceRadar.Inventory.BumblebeeCatalogSnapshot do
  @moduledoc """
  Promotable Bumblebee exposure catalog snapshot.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "bumblebee_catalog_snapshots"
    repo ServiceRadar.Repo
    schema "platform"
  end

  paper_trail do
    primary_key_type :uuid
    table_name "bumblebee_catalog_snapshot_versions"
    mixin {ServiceRadar.Security.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :source_id,
        :snapshot_ref,
        :source_revision,
        :catalog_version,
        :schema_version,
        :status,
        :entry_count,
        :content_sha256,
        :object_key,
        :object_size_bytes,
        :promoted_at,
        :validation_result,
        :artifact_metadata,
        :metadata
      ]
    end

    update :promote do
      accept [
        :entry_count,
        :content_sha256,
        :object_key,
        :object_size_bytes,
        :validation_result,
        :artifact_metadata,
        :metadata
      ]

      change set_attribute(:status, "active")
      change set_attribute(:promoted_at, &DateTime.utc_now/0)
    end

    read :active do
      filter expr(status == "active")
      prepare build(sort: [promoted_at: :desc], limit: 1)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    operator_action_type([:create, :update])
    admin_action_type(:destroy)
  end

  attributes do
    uuid_primary_key :id

    attribute :source_id, :uuid do
      public? true
    end

    attribute :snapshot_ref, :string do
      allow_nil? false
      public? true
    end

    attribute :source_revision, :string do
      public? true
    end

    attribute :catalog_version, :string do
      public? true
    end

    attribute :schema_version, :string do
      public? true
    end

    attribute :status, :string do
      allow_nil? false
      default "candidate"
      public? true
    end

    attribute :entry_count, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :content_sha256, :string do
      public? true
    end

    attribute :object_key, :string do
      public? true
    end

    attribute :object_size_bytes, :integer do
      public? true
    end

    attribute :promoted_at, :utc_datetime_usec do
      public? true
    end

    attribute :validation_result, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :artifact_metadata, :map do
      allow_nil? false
      default %{}
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
    belongs_to :source, ServiceRadar.Inventory.BumblebeeCatalogSource do
      source_attribute :source_id
      destination_attribute :id
      define_attribute? false
      allow_nil? true
      public? true
    end

    has_many :entries, ServiceRadar.Inventory.BumblebeeCatalogEntry do
      source_attribute :id
      destination_attribute :snapshot_id
      public? true
    end
  end

  identities do
    identity :unique_snapshot_ref, [:snapshot_ref]
  end
end
