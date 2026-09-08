defmodule ServiceRadar.Inventory.BumblebeeCatalogParserTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.BumblebeeCatalogParser

  test "normalizes wrapped catalog entries" do
    body =
      Jason.encode!(%{
        "schema_version" => "0.1.0",
        "version" => "catalog-1",
        "revision" => "rev-1",
        "entries" => [
          %{
            "id" => "pkg-a",
            "package" => "left-pad",
            "ecosystem" => "npm",
            "versions" => ["1.0.0", "1.0.1"],
            "severity" => "critical",
            "url" => "https://example.invalid/advisory/pkg-a"
          },
          %{"id" => "missing-package"}
        ]
      })

    assert {:ok, parsed} = BumblebeeCatalogParser.parse(body)
    assert parsed.catalog_version == "catalog-1"
    assert parsed.schema_version == "0.1.0"
    assert parsed.metadata["source_revision"] == "rev-1"
    assert parsed.validation_result["entry_count"] == 1
    assert parsed.validation_result["dropped_entry_count"] == 1

    assert [
             %{
               catalog_id: "pkg-a",
               package_name: "left-pad",
               ecosystem: "npm",
               affected_versions: ["1.0.0", "1.0.1"],
               severity: "critical",
               source_url: "https://example.invalid/advisory/pkg-a"
             }
           ] = parsed.entries
  end

  test "normalizes ndjson entries and enforces max entries" do
    body = """
    {"id":"pkg-a","package":"a","ecosystem":"pypi","severity":"high"}
    {"id":"pkg-b","package":"b","ecosystem":"npm","severity":"informational"}
    """

    assert {:ok, parsed} = BumblebeeCatalogParser.parse(body, max_entries: 1)
    assert [%{catalog_id: "pkg-a", package_name: "a", severity: "high"}] = parsed.entries
  end

  test "rejects catalogs without usable entries" do
    assert {:error, :empty_catalog} =
             BumblebeeCatalogParser.parse(Jason.encode!(%{"entries" => [%{"id" => "pkg-a"}]}))
  end
end
