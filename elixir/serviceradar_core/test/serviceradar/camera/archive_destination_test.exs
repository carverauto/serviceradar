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
          {"schema_version", 3},
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

  test "schema version 2 accepts bounded operator key prefixes in namespace and hashes them" do
    base_v2 =
      "operator:primary"
      |> Fixtures.archive_destination()
      |> Map.put("schema_version", 2)

    assert {:ok, default_prefix} =
             ArchiveDestination.attributes(Map.put(base_v2, "namespace", "recordings/v1"))

    assert {:ok, custom_prefix} =
             ArchiveDestination.attributes(Map.put(base_v2, "namespace", "nvr/archive_v2-site"))

    assert custom_prefix.schema_version == 2
    assert custom_prefix.namespace == "nvr/archive_v2-site"
    refute custom_prefix.destination_sha256 == default_prefix.destination_sha256

    max_prefix = String.duplicate("a", 128)

    assert {:ok, %{namespace: ^max_prefix}} =
             ArchiveDestination.attributes(Map.put(base_v2, "namespace", max_prefix))

    for bad_namespace <- [
          "",
          "/recordings/v1",
          "recordings/v1/",
          "recordings//v1",
          "Recordings/v1",
          "recordings/v1.0",
          String.duplicate("a", 129)
        ] do
      assert {:error, [{:namespace, _}]} =
               ArchiveDestination.validate(Map.put(base_v2, "namespace", bad_namespace))

      assert {:error, :invalid_archive_destination} =
               ArchiveDestination.attributes(Map.put(base_v2, "namespace", bad_namespace))
    end
  end

  test "validate/1 reports offending field names instead of a generic failure" do
    invalid =
      "operator:primary"
      |> Fixtures.archive_destination()
      |> Map.merge(%{
        "schema_version" => 2,
        "endpoint" => "https://192.0.2.10",
        "region" => "EXAMPLE_BAD",
        "bucket" => "x",
        "namespace" => "/bad-leading-slash"
      })

    assert {:error, errors} = ArchiveDestination.validate(invalid)
    fields = Enum.map(errors, &elem(&1, 0))
    assert :endpoint in fields
    assert :region in fields
    assert :bucket in fields
    assert :namespace in fields
  end
end
