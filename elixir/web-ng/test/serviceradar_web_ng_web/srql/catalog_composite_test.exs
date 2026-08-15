defmodule ServiceRadarWebNGWeb.SRQL.CatalogCompositeTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.SRQL.Catalog

  @moduletag :db_free

  defp devices(entities), do: Enum.find(entities, &(&1.id == "devices"))

  defp check(slug, verdicts) do
    %{slug: slug, name: slug, verdicts: verdicts}
  end

  describe "with_composite_checks/2" do
    test "is a no-op with no checks" do
      entities = Catalog.entities()
      assert Catalog.with_composite_checks(entities, []) == entities
    end

    test "adds a verdict and a status field per check" do
      entities =
        Catalog.with_composite_checks(Catalog.entities(), [
          check("pci-isolation", ["isolated_verified", "not_isolated"])
        ])

      fields = devices(entities).filter_fields

      assert "composite.pci-isolation" in fields
      assert "composite.pci-isolation.status" in fields
    end

    test "offers the check's authored verdicts as completions" do
      entities =
        Catalog.with_composite_checks(Catalog.entities(), [
          check("pci-isolation", ["isolated_verified", "not_isolated"])
        ])

      known = devices(entities).known_values

      assert known["composite.pci-isolation"] == ["isolated_verified", "not_isolated"]
      assert known["composite.pci-isolation.status"] == ["healthy", "degraded", "down", "unknown"]
    end

    test "preserves the existing device fields and completions" do
      entities =
        Catalog.with_composite_checks(Catalog.entities(), [check("a", ["x"])])

      device = devices(entities)

      assert "hostname" in device.filter_fields
      assert "discovery_sources" in device.filter_fields
      assert device.known_values["discovery_sources"]
    end

    test "does not touch other entities" do
      before = Catalog.entities()
      after_inject = Catalog.with_composite_checks(before, [check("a", ["x"])])

      for id <- ["agents", "composite_results", "capacity_forecasts"] do
        assert Enum.find(before, &(&1.id == id)) == Enum.find(after_inject, &(&1.id == id)),
               "#{id} should be untouched"
      end
    end

    test "handles several checks" do
      entities =
        Catalog.with_composite_checks(Catalog.entities(), [
          check("alpha", ["a1"]),
          check("beta", ["b1", "b2"])
        ])

      fields = devices(entities).filter_fields

      assert "composite.alpha" in fields
      assert "composite.beta" in fields
      assert devices(entities).known_values["composite.beta"] == ["b1", "b2"]
    end

    test "a check with no authored verdicts still gets a field" do
      entities = Catalog.with_composite_checks(Catalog.entities(), [check("empty", [])])

      assert "composite.empty" in devices(entities).filter_fields
      assert devices(entities).known_values["composite.empty"] == []
    end

    test "changes the catalog version so clients do not serve a stale ETag" do
      # The version is a content hash, so injected fields must change it --
      # otherwise a client caches a catalog without the new check for the full
      # five-minute max-age.
      base = Catalog.structured_from_entities(Catalog.entities())

      enriched =
        Catalog.entities()
        |> Catalog.with_composite_checks([check("pci-isolation", ["x"])])
        |> Catalog.structured_from_entities()

      refute base["version"] == enriched["version"]
    end
  end

  describe "the composite_results entity" do
    test "is registered with its filter fields" do
      entity = Enum.find(Catalog.entities(), &(&1.id == "composite_results"))

      assert entity
      # The builder route now exists, so the catalog points at it rather than at
      # the parent Networks page it fell back to before plan 3 landed.
      assert entity.route == "/settings/networks/composite-checks"
      assert "check" in entity.filter_fields
      assert "verdict" in entity.filter_fields
      assert "status" in entity.filter_fields
      assert "device_uid" in entity.filter_fields
    end

    test "offers the fixed status enum but not verdicts" do
      entity = Enum.find(Catalog.entities(), &(&1.id == "composite_results"))

      assert entity.known_values["status"] == ["healthy", "degraded", "down", "unknown"]
      # Verdicts are operator-defined per check, so a static list would be wrong.
      refute Map.has_key?(entity.known_values, "verdict")
    end
  end
end
