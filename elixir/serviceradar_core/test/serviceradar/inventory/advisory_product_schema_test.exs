defmodule ServiceRadar.Inventory.AdvisoryProductSchemaTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias AshPostgres.DataLayer.Info, as: PostgresInfo
  alias ServiceRadar.Inventory
  alias ServiceRadar.Inventory.AdvisoryPackageAssertion
  alias ServiceRadar.Inventory.AdvisoryProduct
  alias ServiceRadar.Inventory.AdvisoryProductSet

  @product_fields [
    :id,
    :content_sha256,
    :lookup_key,
    :normalization_version,
    :package_type,
    :namespace,
    :package_name,
    :package_version,
    :release,
    :release_channel,
    :architecture,
    :source_package,
    :source_version,
    :canonical_purl,
    :product_scope,
    :parent_product_id,
    :qualifiers,
    :metadata,
    :inserted_at,
    :updated_at
  ]

  @product_set_fields [
    :id,
    :content_sha256,
    :normalization_version,
    :product_ids,
    :product_count,
    :canonical_size_bytes,
    :metadata,
    :inserted_at,
    :updated_at
  ]

  test "product dictionary exposes immutable, caller-addressed normalized identities" do
    assert Code.ensure_loaded?(AdvisoryProduct)
    assert_platform_resource(AdvisoryProduct, "advisory_products")

    attributes = attributes_by_name(AdvisoryProduct)
    assert Enum.all?(@product_fields, &Map.has_key?(attributes, &1))
    assert Enum.all?(@product_fields -- [:inserted_at, :updated_at], &attributes[&1].public?)

    for field <- [
          :id,
          :content_sha256,
          :lookup_key,
          :normalization_version,
          :package_type,
          :namespace,
          :package_name,
          :package_version,
          :canonical_purl,
          :product_scope
        ] do
      refute attributes[field].allow_nil?
    end

    assert is_nil(attributes.id.default)
    assert is_nil(Info.action(AdvisoryProduct, :create))
    assert attributes.qualifiers.default == %{}
    assert attributes.metadata.default == %{}
    assert Info.identity(AdvisoryProduct, :unique_content_sha256).keys == [:content_sha256]

    assert Enum.map(Info.actions(AdvisoryProduct), & &1.name) == [:read]

    parent = Info.relationship(AdvisoryProduct, :parent_product)
    assert parent.destination == AdvisoryProduct
    assert parent.source_attribute == :parent_product_id
    assert %{on_delete: :restrict} = PostgresInfo.reference(AdvisoryProduct, :parent_product)

    assert_index(AdvisoryProduct, "advisory_products_lookup_key_idx", [:lookup_key])

    assert_index(
      AdvisoryProduct,
      "advisory_products_package_lookup_idx",
      [:package_type, :namespace, :package_name, :package_version, :release, :architecture]
    )

    assert_constraint_names(AdvisoryProduct, [
      "advisory_products_content_sha256_check",
      "advisory_products_normalization_version_check",
      "advisory_products_qualifiers_size_check",
      "advisory_products_metadata_size_check"
    ])
  end

  test "product sets retain a compact, indexed content-addressed membership vector" do
    assert Code.ensure_loaded?(AdvisoryProductSet)
    assert_platform_resource(AdvisoryProductSet, "advisory_product_sets")

    attributes = attributes_by_name(AdvisoryProductSet)
    assert Enum.all?(@product_set_fields, &Map.has_key?(attributes, &1))
    assert Enum.all?(@product_set_fields -- [:inserted_at, :updated_at], &attributes[&1].public?)

    for field <- [
          :id,
          :content_sha256,
          :normalization_version,
          :product_ids,
          :product_count,
          :canonical_size_bytes
        ] do
      refute attributes[field].allow_nil?
    end

    assert is_nil(attributes.id.default)
    assert is_nil(Info.action(AdvisoryProductSet, :create))
    assert attributes.product_ids.default == []
    assert attributes.metadata.default == %{}
    assert Info.identity(AdvisoryProductSet, :unique_content_sha256).keys == [:content_sha256]

    assert Enum.map(Info.actions(AdvisoryProductSet), & &1.name) == [:read]

    assert %{using: "gin"} =
             assert_index(
               AdvisoryProductSet,
               "advisory_product_sets_product_ids_gin_idx",
               [:product_ids]
             )

    assert_constraint_names(AdvisoryProductSet, [
      "advisory_product_sets_content_sha256_check",
      "advisory_product_sets_bounds_check",
      "advisory_product_sets_metadata_size_check"
    ])
  end

  test "package assertions can reference compact product sets without breaking scalar rows" do
    attributes = attributes_by_name(AdvisoryPackageAssertion)

    assert attributes.assertion_shape.default == "scalar"
    refute attributes.assertion_shape.allow_nil?
    assert attributes.product_set_ref.allow_nil?
    assert attributes.statement_fingerprint.allow_nil?
    assert attributes.release_channel.allow_nil?

    product_set = Info.relationship(AdvisoryPackageAssertion, :product_set)
    assert product_set.destination == AdvisoryProductSet
    assert product_set.source_attribute == :product_set_ref

    assert %{on_delete: :restrict} =
             PostgresInfo.reference(AdvisoryPackageAssertion, :product_set)

    assert_index(
      AdvisoryPackageAssertion,
      "advisory_package_assertions_product_set_ref_idx",
      [:product_set_ref]
    )

    assert_constraint_names(AdvisoryPackageAssertion, [
      "advisory_package_assertions_assertion_shape_check",
      "advisory_package_assertions_ubuntu_vex_product_set_check"
    ])

    shape_constraint =
      Enum.find(
        PostgresInfo.check_constraints(AdvisoryPackageAssertion),
        &(&1.name == "advisory_package_assertions_assertion_shape_check")
      )

    assert shape_constraint.check =~ "assertion_shape = 'scalar' AND product_set_ref IS NULL"
  end

  test "package assertions are readable but expose no operator write action" do
    assert Enum.map(Info.actions(AdvisoryPackageAssertion), & &1.name) == [:read]
    assert is_nil(Info.action(AdvisoryPackageAssertion, :create))
    assert is_nil(Info.action(AdvisoryPackageAssertion, :upsert))
    assert is_nil(Info.action(AdvisoryPackageAssertion, :destroy))
  end

  test "inventory registers compact product resources" do
    resources = Ash.Domain.Info.resources(Inventory)

    assert AdvisoryProduct in resources
    assert AdvisoryProductSet in resources
  end

  test "follow-on migration creates compact tables and restricts assertion references" do
    {version, migration} = compact_migration!()

    assert version > 20_260_902_143_747

    assert migration =~
             ~s|create table(:advisory_products, primary_key: false, prefix: "platform")|

    assert migration =~
             ~s|create table(:advisory_product_sets, primary_key: false, prefix: "platform")|

    assert migration =~
             ~s|alter table(:advisory_package_assertions, prefix: "platform")|

    assert migration =~ "advisory_products_content_sha256_check"
    assert migration =~ "advisory_products_lookup_key_idx"
    assert migration =~ "advisory_products_package_lookup_idx"
    assert migration =~ "advisory_product_sets_product_ids_gin_idx"
    assert migration =~ "product_count <= 65536"
    assert migration =~ "canonical_size_bytes <= 16777216"
    assert migration =~ "advisory_package_assertions_product_set_ref_idx"
    assert migration =~ "advisory_package_assertions_ubuntu_vex_product_set_check"
    assert migration =~ "assertion_shape = 'scalar' AND product_set_ref IS NULL"

    assert migration =~
             ~r/name: "advisory_package_assertions_product_set_ref_fkey",.*?on_delete: :restrict/s

    assert migration =~
             ~r/name: "advisory_products_parent_product_id_fkey",.*?on_delete: :restrict/s
  end

  defp assert_platform_resource(resource, table) do
    assert PostgresInfo.table(resource) == table
    assert PostgresInfo.schema(resource) == "platform"
    assert PostgresInfo.migrate?(resource)
    assert resource in Ash.Domain.Info.resources(Inventory)
    assert attributes_by_name(resource).id.primary_key?
  end

  defp attributes_by_name(resource) do
    resource
    |> Info.attributes()
    |> Map.new(&{&1.name, &1})
  end

  defp assert_index(resource, name, fields) do
    index = Enum.find(PostgresInfo.custom_indexes(resource), &(&1.name == name))
    assert index
    assert index.fields == fields
    index
  end

  defp assert_constraint_names(resource, expected) do
    names = resource |> PostgresInfo.check_constraints() |> Enum.map(& &1.name)
    assert Enum.all?(expected, &(&1 in names))
  end

  defp compact_migration! do
    case Path.wildcard("priv/repo/migrations/*_add_compact_advisory_products.exs") do
      [path] ->
        version =
          path |> Path.basename() |> String.split("_", parts: 2) |> hd() |> String.to_integer()

        {version, File.read!(path)}

      paths ->
        flunk("expected one compact advisory product migration, found #{inspect(paths)}")
    end
  end
end
