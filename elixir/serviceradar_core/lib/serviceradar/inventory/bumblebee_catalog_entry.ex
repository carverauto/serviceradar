defmodule ServiceRadar.Inventory.BumblebeeCatalogEntry do
  @moduledoc """
  Normalized Bumblebee exposure catalog entry.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "bumblebee_catalog_entries"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :snapshot_id,
        :catalog_id,
        :ecosystem,
        :package_name,
        :affected_versions,
        :severity,
        :source_url,
        :metadata
      ]
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

    attribute :snapshot_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :catalog_id, :string do
      allow_nil? false
      public? true
    end

    attribute :ecosystem, :string do
      allow_nil? false
      public? true
    end

    attribute :package_name, :string do
      allow_nil? false
      public? true
    end

    attribute :affected_versions, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end

    attribute :severity, :string do
      allow_nil? false
      public? true
    end

    attribute :source_url, :string do
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
    belongs_to :snapshot, ServiceRadar.Inventory.BumblebeeCatalogSnapshot do
      source_attribute :snapshot_id
      destination_attribute :id
      define_attribute? false
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_snapshot_catalog, [:snapshot_id, :catalog_id]
  end
end
