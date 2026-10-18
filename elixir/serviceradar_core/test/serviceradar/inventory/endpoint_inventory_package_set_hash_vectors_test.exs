defmodule ServiceRadar.Inventory.EndpointInventoryPackageSetHashVectorsTest do
  @moduledoc """
  package_set_hash vectors shared with the Go producer.

  `go/pkg/endpointinventory/testdata/package_set_hash_v1.json` was generated
  from this module's implementation, and `go/pkg/endpointinventory` tests its
  ComputePackageSetHash and BuildCycloneDX against the same file. Ingest compares the reported hash
  with the one recomputed here and forces a full re-upload on any difference, so
  a change that fails this test breaks every agent's delta uploads. Regenerate
  the vectors and change the Go side in the same commit, or bump the hash
  algorithm version.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.EndpointInventoryPackageSet, as: PackageSet

  defp vectors! do
    path =
      Path.expand(
        "../../../../../go/pkg/endpointinventory/testdata/package_set_hash_v1.json",
        __DIR__
      )

    case File.read(path) do
      {:ok, contents} -> Jason.decode!(contents)
      {:error, reason} -> flunk("could not read #{path}: #{inspect(reason)}")
    end
  end

  test "package payloads hash and canonicalize as the shared vectors record" do
    %{"hash_algorithm" => "sha256-v1", "cases" => [_ | _] = cases} = vectors!()

    for %{"name" => name, "packages" => packages} = vector <- cases do
      normalized = PackageSet.normalize_packages(%{"packages" => packages})

      purls =
        Enum.map(packages, fn package ->
          case PackageSet.normalize_packages(%{"packages" => [package]}) do
            [normalized_package] -> normalized_package.purl_canonical
            [] -> nil
          end
        end)

      assert purls == vector["expected_purls"], name
      assert length(normalized) == vector["expected_package_count"], name
      assert PackageSet.server_package_set_hash(normalized) == vector["expected_hash"], name
    end
  end

  # The producer hashes its packages but uploads them as CycloneDX components,
  # and ingest recomputes the hash from those components. Every case therefore
  # has to hash identically in both forms, or every upload is a mismatch.
  test "the uploaded CycloneDX components hash like the packages they encode" do
    %{"cases" => [_ | _] = cases} = vectors!()

    for %{"name" => name, "components" => [_ | _] = components} = vector <- cases do
      normalized = PackageSet.normalize_packages(%{"sbom" => %{"components" => components}})

      assert length(normalized) == vector["expected_package_count"], name
      assert PackageSet.server_package_set_hash(normalized) == vector["expected_hash"], name
    end
  end
end
