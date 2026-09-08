defmodule ServiceRadar.Inventory.AdvisoryProductSet do
  @moduledoc """
  Immutable, content-addressed set of normalized advisory products.

  `product_ids` is emitted by the normalizer in sorted, duplicate-free order;
  `content_sha256` covers that canonical vector and its normalization version.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "advisory_product_sets"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? true

    identity_index_names unique_content_sha256: "advisory_product_sets_content_sha256_uidx"

    custom_indexes do
      index [:product_ids], name: "advisory_product_sets_product_ids_gin_idx", using: "gin"
    end

    check_constraints do
      check_constraint :content_sha256, "advisory_product_sets_content_sha256_check",
        check: "content_sha256 ~ '^[0-9a-f]{64}$'",
        message: "must be a lowercase SHA-256 digest"

      check_constraint :product_count, "advisory_product_sets_bounds_check",
        check: """
        normalization_version > 0
        AND product_count > 0
        AND product_count <= 65536
        AND product_count = cardinality(product_ids)
        AND canonical_size_bytes > 0
        AND canonical_size_bytes <= 16777216
        AND array_position(product_ids, NULL) IS NULL
        """,
        message: "must match the bounded canonical membership vector"

      check_constraint :metadata, "advisory_product_sets_metadata_size_check",
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
    attribute :normalization_version, :integer, allow_nil?: false, public?: true
    attribute :product_ids, {:array, :uuid}, allow_nil?: false, default: [], public?: true
    attribute :product_count, :integer, allow_nil?: false, public?: true
    attribute :canonical_size_bytes, :integer, allow_nil?: false, public?: true
    attribute :metadata, :map, allow_nil?: false, default: %{}, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :package_assertions, ServiceRadar.Inventory.AdvisoryPackageAssertion do
      source_attribute :id
      destination_attribute :product_set_ref
      public? true
    end
  end

  identities do
    identity :unique_content_sha256, [:content_sha256]
  end
end
