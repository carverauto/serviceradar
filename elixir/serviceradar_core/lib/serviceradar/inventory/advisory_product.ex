defmodule ServiceRadar.Inventory.AdvisoryProduct do
  @moduledoc """
  Immutable, content-addressed package identity from an advisory authority.

  Callers derive both the UUID primary key and the full SHA-256 collision
  identity from the normalized product projection. Product-set membership can
  therefore reuse a UUID vector without duplicating package metadata.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "advisory_products"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? true

    identity_index_names unique_content_sha256: "advisory_products_content_sha256_uidx"

    references do
      reference :parent_product, on_delete: :restrict
    end

    custom_indexes do
      index [:lookup_key], name: "advisory_products_lookup_key_idx"

      index [:package_type, :namespace, :package_name, :package_version, :release, :architecture],
        name: "advisory_products_package_lookup_idx"
    end

    check_constraints do
      check_constraint :content_sha256, "advisory_products_content_sha256_check",
        check: "content_sha256 ~ '^[0-9a-f]{64}$'",
        message: "must be a lowercase SHA-256 digest"

      check_constraint :normalization_version, "advisory_products_normalization_version_check",
        check: "normalization_version > 0",
        message: "must be positive"

      check_constraint :qualifiers, "advisory_products_qualifiers_size_check",
        check: "jsonb_typeof(qualifiers) = 'object' AND pg_column_size(qualifiers) <= 8192",
        message: "must be an object no larger than 8192 bytes"

      check_constraint :metadata, "advisory_products_metadata_size_check",
        check: "jsonb_typeof(metadata) = 'object' AND pg_column_size(metadata) <= 8192",
        message: "must be an object no larger than 8192 bytes"
    end
  end

  actions do
    defaults [:read]
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
  end

  attributes do
    attribute :id, :uuid,
      allow_nil?: false,
      primary_key?: true,
      public?: true

    attribute :content_sha256, :string, allow_nil?: false, public?: true
    attribute :lookup_key, :uuid, allow_nil?: false, public?: true
    attribute :normalization_version, :integer, allow_nil?: false, public?: true
    attribute :package_type, :string, allow_nil?: false, public?: true
    attribute :namespace, :string, allow_nil?: false, public?: true
    attribute :package_name, :string, allow_nil?: false, public?: true
    attribute :package_version, :string, allow_nil?: false, public?: true
    attribute :release, :string, public?: true
    attribute :release_channel, :string, public?: true
    attribute :architecture, :string, public?: true
    attribute :source_package, :string, public?: true
    attribute :source_version, :string, public?: true
    attribute :canonical_purl, :string, allow_nil?: false, public?: true
    attribute :product_scope, :string, allow_nil?: false, public?: true
    attribute :parent_product_id, :uuid, public?: true
    attribute :qualifiers, :map, allow_nil?: false, default: %{}, public?: true
    attribute :metadata, :map, allow_nil?: false, default: %{}, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :parent_product, __MODULE__ do
      source_attribute :parent_product_id
      destination_attribute :id
      define_attribute? false
      allow_nil? true
      public? true
    end

    has_many :child_products, __MODULE__ do
      source_attribute :id
      destination_attribute :parent_product_id
      public? true
    end
  end

  identities do
    identity :unique_content_sha256, [:content_sha256]
  end
end
