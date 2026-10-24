defmodule ServiceRadar.Camera.ArchiveDestinationTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.ArchiveDestination
  alias ServiceRadar.Test.CameraRelayFixtures, as: Fixtures

  test "versioned destination identity matches canonical bytes and changes with its destination" do
    input = Fixtures.archive_destination("allocation-example")
    assert {:ok, destination} = ArchiveDestination.attributes(input)
    assert destination.endpoint == "https://objects.example.com"
    assert destination.namespace == "recordings/v1"
    assert destination.required_encryption == "sse_s3_aes256"

    assert destination.destination_sha256 ==
             "154ecbe5d6d232275123a7cf847e491d627197980ea8c4a050593d2e0f474020"

    for {field, value} <- [
          {"generation", 2},
          {"bucket", "example-other"},
          {"region", "another-region"}
        ] do
      assert {:ok, changed} = ArchiveDestination.attributes(Map.put(input, field, value))
      refute changed.destination_sha256 == destination.destination_sha256
    end
  end

  test "unqualified input refuses capability claims, secrets, unsafe origins and unsupported formats" do
    input = Fixtures.archive_destination("allocation-example")

    for {field, value} <- [
          {"capability_state", "ready"},
          {"credential_reference", "invented-reference"},
          {"schema_version", 2},
          {"generation", 0},
          {"generation", 9_223_372_036_854_775_808},
          {"purpose", "evidence"},
          {"provider", "unqualified-provider"},
          {"namespace", "recordings/../other"},
          {"archive_format_version", 2},
          {"required_encryption", "none"},
          {"endpoint", "http://objects.example.com"},
          {"endpoint", "https://user:invented@objects.example.com"},
          {"endpoint", "https://objects.example.com/path"},
          {"endpoint", "https://objects.example.com?signature=invented"},
          {"endpoint", "https://objects.example.com/#fragment"},
          {"endpoint", "https://192.0.2.1"},
          {"endpoint", "https://objects.example.com:443"},
          {"endpoint", "https://" <> String.duplicate("x", 64) <> ".example.com"},
          {"bucket", "../another-purpose"},
          {"provisioning_ref", String.duplicate("a", 129)}
        ] do
      assert {:error, :invalid_archive_destination} =
               ArchiveDestination.attributes(Map.put(input, field, value))
    end

    assert {:error, :invalid_archive_destination} =
             ArchiveDestination.attributes(Map.delete(input, "region"))
  end
end
