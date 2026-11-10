defmodule ServiceRadar.Camera.LocalStorageBindingConfigTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.LocalStorageBindingConfig

  @configuration %{
    "schema_version" => 1,
    "storage_id" => "00000000-0000-4000-8000-000000000021",
    "generation" => 1,
    "provider_resource_ref" => "invented-volume-reference",
    "profile_sha256" => "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }

  test "binding identity hashes the complete versioned canonical configuration" do
    assert {:ok, attrs} = LocalStorageBindingConfig.attributes(@configuration)
    assert attrs.storage_id == "00000000-0000-4000-8000-000000000021"
    assert attrs.generation == 1
    assert attrs.provider_resource_ref == "invented-volume-reference"

    # Independent wire vector: canonical key order, compact JSON, domain separation.
    canonical =
      ~s(["nvr-local-storage-binding-v1",{"generation":1,"profile_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","provider_resource_ref":"invented-volume-reference","schema_version":1,"storage_id":"00000000-0000-4000-8000-000000000021"}])

    assert attrs.binding_sha256 == Base.encode16(:crypto.hash(:sha256, canonical), case: :lower)
  end

  test "refuses unsupported fields, malformed identities and unbounded input" do
    invalid_values = [
      {"schema_version", 2},
      {"storage_id", "00000000-0000-4000-8000-00000000002A"},
      {"storage_id", "not-a-uuid"},
      {"generation", 0},
      {"generation", 9_223_372_036_854_775_808},
      {"generation", "1"},
      {"provider_resource_ref", ""},
      {"provider_resource_ref", "invented\nvolume"},
      {"provider_resource_ref", String.duplicate("a", 257)},
      {"profile_sha256", String.duplicate("A", 64)},
      {"profile_sha256", String.duplicate("a", 63)},
      {"profile_sha256", %{}}
    ]

    invalid_documents =
      [nil, [], %{}, Map.put(@configuration, "qualified", true)] ++
        Enum.map(Map.keys(@configuration), &Map.delete(@configuration, &1)) ++
        Enum.map(invalid_values, fn {key, value} -> Map.put(@configuration, key, value) end)

    for document <- invalid_documents do
      assert {:error, :invalid_local_storage_binding} =
               LocalStorageBindingConfig.attributes(document)
    end
  end

  test "accepts maximum generation and reference lengths without normalizing identity" do
    configuration =
      @configuration
      |> Map.put("generation", 9_223_372_036_854_775_807)
      |> Map.put("provider_resource_ref", String.duplicate("r", 256))

    assert {:ok, attrs} = LocalStorageBindingConfig.attributes(configuration)
    assert attrs.generation == 9_223_372_036_854_775_807
    assert attrs.provider_resource_ref == String.duplicate("r", 256)
  end
end
