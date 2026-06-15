defmodule ServiceRadar.Inventory.AdvisoryCoordinate do
  @moduledoc """
  Normalized, indexed coordinate extracted from a `VulnerabilityAdvisory` at load
  time (design D4b).

  One row per CPE / PURL / vendor_product coordinate, carrying parsed CPE-2.3
  components and discrete NVD version-range bounds so the endpoint matcher joins
  on indexed columns instead of parsing JSONB at query time.

  Bulk upserts go through `Repo.insert_all` (see
  `ServiceRadar.Inventory.AdvisoryFeeds.Loader`); this resource exists for reads,
  policy enforcement, and the domain registry.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "advisory_coordinates"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  actions do
    defaults [:read, :destroy]

    read :for_advisory do
      argument :advisory_ref, :uuid, allow_nil?: false
      filter expr(advisory_ref == ^arg(:advisory_ref))
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

    attribute :advisory_ref, :uuid, allow_nil?: false, public?: true
    attribute :provider, :string, allow_nil?: false, public?: true
    attribute :feed_key, :string, allow_nil?: false, public?: true
    attribute :generation, :integer, allow_nil?: false, default: 0, public?: true
    attribute :coordinate_type, :string, allow_nil?: false, public?: true
    attribute :value, :string, allow_nil?: false, public?: true

    attribute :cpe_part, :string, public?: true
    attribute :cpe_vendor, :string, public?: true
    attribute :cpe_product, :string, public?: true
    attribute :cpe_version, :string, public?: true

    attribute :version_start, :string, public?: true
    attribute :version_start_inclusive, :boolean, public?: true
    attribute :version_end, :string, public?: true
    attribute :version_end_inclusive, :boolean, public?: true

    attribute :metadata, :map, allow_nil?: false, default: %{}, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :advisory, ServiceRadar.Inventory.VulnerabilityAdvisory do
      source_attribute :advisory_ref
      destination_attribute :id
      define_attribute? false
      public? true
    end
  end

  identities do
    identity :unique_coordinate, [
      :advisory_ref,
      :coordinate_type,
      :value,
      :version_start,
      :version_end
    ]
  end
end
