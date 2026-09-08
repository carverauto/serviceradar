defmodule ServiceRadar.Inventory.AdvisoryPackageAssertion do
  @moduledoc """
  Provider-neutral package applicability asserted by an advisory authority.

  Assertions retain native package and release scope so matching never has to
  reinterpret an upstream advisory's raw document.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "advisory_package_assertions"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? true

    references do
      reference :advisory, on_delete: :delete
      reference :product_set, on_delete: :restrict
    end

    custom_indexes do
      index [:cve_id, :namespace, :release, :binary_package],
        name: "advisory_package_assertions_cve_binary_idx"

      index [:cve_id, :namespace, :release, :source_package],
        name: "advisory_package_assertions_cve_source_idx"

      index [:provider, :feed_key, :generation],
        name: "advisory_package_assertions_generation_idx"

      index [:product_set_ref],
        name: "advisory_package_assertions_product_set_ref_idx"
    end

    check_constraints do
      check_constraint :assertion_shape, "advisory_package_assertions_assertion_shape_check",
        check:
          "assertion_shape IN ('scalar', 'product_set') AND ((assertion_shape = 'product_set' AND product_set_ref IS NOT NULL) OR (assertion_shape = 'scalar' AND product_set_ref IS NULL))",
        message: "must use a supported shape with a product set when required"

      check_constraint :product_set_ref,
                       "advisory_package_assertions_ubuntu_vex_product_set_check",
                       check:
                         "provider <> 'ubuntu' OR source_kind <> 'ubuntu_openvex' OR product_set_ref IS NOT NULL",
                       message: "must reference a normalized product set for Ubuntu OpenVEX"
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
    uuid_primary_key :id

    attribute :assertion_key, :string, allow_nil?: false, public?: true
    attribute :advisory_ref, :uuid, allow_nil?: false, public?: true
    attribute :provider, :string, allow_nil?: false, public?: true
    attribute :feed_key, :string, allow_nil?: false, public?: true
    attribute :generation, :integer, allow_nil?: false, public?: true
    attribute :cve_id, :string, allow_nil?: false, public?: true
    attribute :authority, :string, allow_nil?: false, public?: true
    attribute :source_kind, :string, allow_nil?: false, public?: true
    attribute :source_timestamp, :utc_datetime_usec, public?: true
    attribute :assertion_shape, :string, allow_nil?: false, default: "scalar", public?: true
    attribute :product_set_ref, :uuid, public?: true
    attribute :statement_fingerprint, :string, public?: true
    attribute :package_type, :string, public?: true
    attribute :namespace, :string, public?: true
    attribute :release, :string, public?: true
    attribute :release_channel, :string, public?: true
    attribute :product_scope, :string, public?: true
    attribute :source_package, :string, public?: true
    attribute :binary_package, :string, public?: true
    attribute :architecture, :string, public?: true
    attribute :version_scheme, :string, public?: true
    attribute :disposition, :string, allow_nil?: false, public?: true
    attribute :introduced_version, :string, public?: true
    attribute :fixed_version, :string, public?: true
    attribute :affected_versions, {:array, :string}, allow_nil?: false, default: [], public?: true
    attribute :package_purl, :string, public?: true
    attribute :justification, :string, public?: true
    attribute :status_text, :string, public?: true
    attribute :action_text, :string, public?: true
    attribute :validation, :map, allow_nil?: false, default: %{}, public?: true
    attribute :raw, :map, allow_nil?: false, default: %{}, public?: true
    attribute :metadata, :map, allow_nil?: false, default: %{}, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :advisory, ServiceRadar.Inventory.VulnerabilityAdvisory do
      source_attribute :advisory_ref
      destination_attribute :id
      define_attribute? false
      allow_nil? false
      public? true
    end

    belongs_to :product_set, ServiceRadar.Inventory.AdvisoryProductSet do
      source_attribute :product_set_ref
      destination_attribute :id
      define_attribute? false
      allow_nil? true
      public? true
    end
  end

  identities do
    identity :unique_assertion_key, [:assertion_key]
  end
end
