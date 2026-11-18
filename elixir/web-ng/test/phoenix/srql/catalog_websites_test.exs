defmodule ServiceRadarWebNGWeb.SRQL.CatalogWebsitesTest do
  @moduledoc """
  DB-free contract tests for `in:websites` / `in:web_properties` SRQL catalog
  and Rust translator integration.
  """
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.SRQL.Native
  alias ServiceRadarWebNGWeb.SRQL.Builder
  alias ServiceRadarWebNGWeb.SRQL.Catalog

  @moduletag :db_free

  test "catalog exposes websites entity with explicit sort, route, and field types" do
    entity = Catalog.entity("websites")

    assert entity.id == "websites"
    assert entity.label == "Websites"
    assert entity.route == "/websites"
    assert entity.default_sort_field == "name"
    assert entity.default_sort_dir == "asc"
    assert entity.default_filter_field == "name"
    assert entity.boolean_fields == ["rum_enabled", "anonymize_client_ip"]
    assert entity.array_fields == ["allowed_origins", "observed_vips"]

    assert entity.timestamp_fields == [
             "tls_not_after",
             "last_posture_checked_at",
             "created_at",
             "updated_at"
           ]

    for field <- [
          "id",
          "name",
          "canonical_origin",
          "environment",
          "edge_provider",
          "rum_enabled",
          "anonymize_client_ip",
          "tls_issuer",
          "allowed_origins",
          "observed_vips",
          "tag"
        ] do
      assert field in entity.filter_fields
    end
  end

  test "all Rust website aliases map to the canonical websites catalog entry" do
    for alias_name <- ["websites", "website", "web_properties", "web_property"] do
      assert Catalog.entity(alias_name).id == "websites"
      assert {:ok, _ast} = Native.parse_ast("in:#{alias_name} limit:1")
    end

    builder = Builder.default_state("websites", 50)
    assert Builder.build(builder) == "in:websites sort:name:asc limit:50"
  end

  test "Rust translator builds SQL against platform.web_properties" do
    assert {:ok, json} =
             Native.translate(
               "in:web_properties environment:production rum_enabled:true limit:10",
               nil,
               nil,
               nil,
               "legacy"
             )

    decoded = Jason.decode!(json)
    assert decoded["sql"] =~ "platform.web_properties"
    assert decoded["sql"] =~ "wp.environment = $1"
    assert decoded["sql"] =~ "wp.rum_enabled = $2"
  end

  test "catalog default_filter_op and Builder.build align with Rust websites translator" do
    assert Catalog.default_filter_op("websites", "observed_vips") == "equals"
    assert Catalog.default_filter_op("websites", "tag") == "equals"
    assert Catalog.default_filter_op("websites", "id") == "equals"
    assert Catalog.default_filter_op("websites", "allowed_origins") == "contains"

    state = %{
      "entity" => "websites",
      "limit" => 25,
      "sort_field" => "name",
      "sort_dir" => "asc",
      "filters" => [
        %{
          "field" => "allowed_origins",
          "op" => Catalog.default_filter_op("websites", "allowed_origins"),
          "value" => "example.com"
        },
        %{
          "field" => "allowed_origins",
          "op" => "not_contains",
          "value" => "staging.local"
        },
        %{
          "field" => "observed_vips",
          "op" => Catalog.default_filter_op("websites", "observed_vips"),
          "value" => "203.0.113.10"
        },
        %{
          "field" => "tag",
          "op" => Catalog.default_filter_op("websites", "tag"),
          "value" => "tier"
        }
      ]
    }

    srql = Builder.build(state)
    assert srql =~ "allowed_origins:%example.com%"
    assert srql =~ "!allowed_origins:%staging.local%"
    assert srql =~ "observed_vips:(203.0.113.10)"
    assert srql =~ "tag:tier"

    assert {:ok, json} = Native.translate(srql, nil, nil, nil, "legacy")
    decoded = Jason.decode!(json)
    sql = decoded["sql"]

    assert sql =~ "wp.observed_vips && $1"
    assert sql =~ "jsonb_exists(wp.tags, $2)"
    assert sql =~ "EXISTS (SELECT 1 FROM unnest(wp.allowed_origins) AS item WHERE item ILIKE $3)"

    assert sql =~
             "NOT EXISTS (SELECT 1 FROM unnest(wp.allowed_origins) AS item WHERE item ILIKE $4)"

    assert sql =~ "LIMIT $5 OFFSET $6"
    refute sql =~ "?"
  end
end
