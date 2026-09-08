defmodule ServiceRadar.CompositeChecks.Resolvers.DeviceMetadataTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.Resolvers.DeviceMetadata

  @now ~U[2026-08-11 22:00:00.000000Z]

  defp input(max_age_seconds) do
    config = %{"path" => "nac_applied", "value_type" => "boolean"}

    config =
      if max_age_seconds, do: Map.put(config, "max_age_seconds", max_age_seconds), else: config

    %CompositeCheckInput{key: "nac", kind: :device_metadata, config: config}
  end

  defp metadata(value, written_ago_seconds) do
    base = %{"nac_applied" => value}

    case written_ago_seconds do
      nil ->
        base

      seconds ->
        Map.put(base, DeviceMetadata.provenance_key(), %{
          "nac_applied" => %{
            "source" => "nco",
            "updated_at" => @now |> DateTime.add(-seconds) |> DateTime.to_iso8601()
          }
        })
    end
  end

  test "fresh boolean fact resolves to its value" do
    assert %{value: true, stale: false} =
             DeviceMetadata.resolve(input(86_400), metadata(true, 7_200), @now)
  end

  test "false is a real value, not unknown" do
    assert %{value: false, stale: false} =
             DeviceMetadata.resolve(input(86_400), metadata(false, 7_200), @now)
  end

  test "stale fact resolves to unknown" do
    assert %{value: :unknown, reason: :stale, stale: true} =
             DeviceMetadata.resolve(input(86_400), metadata(true, 90_000), @now)
  end

  test "absent key resolves to unknown" do
    assert %{value: :unknown, reason: :absent} = DeviceMetadata.resolve(input(86_400), %{}, @now)
  end

  test "nil metadata resolves to unknown" do
    assert %{value: :unknown, reason: :absent} = DeviceMetadata.resolve(input(86_400), nil, @now)
  end

  test "type mismatch resolves to unknown" do
    assert %{value: :unknown, reason: :type_mismatch} =
             DeviceMetadata.resolve(input(86_400), metadata("yes", 60), @now)
  end

  test "missing provenance with a max_age resolves to unknown" do
    assert %{value: :unknown, reason: :no_provenance} =
             DeviceMetadata.resolve(input(86_400), metadata(true, nil), @now)
  end

  test "missing provenance with no max_age resolves to the stored value" do
    # Without this, every metadata key predating the provenance side-channel
    # would resolve unknown forever and be unusable as a composite input.
    assert %{value: true, stale: false, reason: nil} =
             DeviceMetadata.resolve(input(nil), metadata(true, nil), @now)
  end

  test "unparseable provenance timestamp resolves to unknown when freshness is required" do
    metadata = %{
      "nac_applied" => true,
      DeviceMetadata.provenance_key() => %{
        "nac_applied" => %{"source" => "nco", "updated_at" => "not-a-timestamp"}
      }
    }

    assert %{value: :unknown, reason: :no_provenance} =
             DeviceMetadata.resolve(input(86_400), metadata, @now)
  end

  test "provenance for a different key does not satisfy freshness" do
    metadata = %{
      "nac_applied" => true,
      DeviceMetadata.provenance_key() => %{
        "something_else" => %{
          "source" => "nco",
          "updated_at" => DateTime.to_iso8601(@now)
        }
      }
    }

    assert %{value: :unknown, reason: :no_provenance} =
             DeviceMetadata.resolve(input(86_400), metadata, @now)
  end
end
