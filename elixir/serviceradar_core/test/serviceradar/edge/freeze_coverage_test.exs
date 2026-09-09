defmodule ServiceRadar.Edge.FreezeCoverageTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.RecordValidate
  alias Serviceradar.Edge.V1.EdgeRecordRouteProfile
  alias Serviceradar.Edge.V1.EdgeRecordV1

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)

  test "all finite route profiles retain large registry epochs and signed authority" do
    rows = "freeze_route_registry_corpus.txt" |> fixture() |> String.split("\n", trim: true)

    inventory =
      for row <- rows do
        [name, route, source, epoch, accepted] = String.split(row)
        raw = fixture(name)
        record = EdgeRecordV1.decode(raw)
        route = String.to_integer(route)
        assert EdgeRecordRouteProfile.value(record.route_profile) == route
        assert record.output_contract.registry_epoch == String.to_integer(epoch)
        assert record.output_contract.registry_epoch == 4_294_967_296 + route
        assert {:production, claims} = record.production_capability.claims
        assert claims.registry_epoch == record.output_contract.registry_epoch
        assert claims.route_profile == record.route_profile

        assert CapabilitySigning.verify(
                 record.production_capability,
                 :production,
                 fixture("issuer_key_a.pub")
               )

        if source == "true" do
          assert {:source, src} = record.source_authorization.capability.claims
          assert src.route_profile == record.route_profile

          assert CapabilitySigning.verify(
                   record.source_authorization.capability,
                   :source,
                   fixture("issuer_key_b.pub")
                 )
        else
          assert record.source_authorization == nil
        end

        if accepted == "true" do
          assert {:ok, ^record} = RecordValidate.validate_bytes(raw)
        else
          assert route == 3 and source == "false"
          assert {:error, :recovery_lane} = RecordValidate.validate_bytes(raw)
        end

        {route, source, accepted}
      end

    assert Enum.sort(inventory) == [
             {1, "false", "true"},
             {1, "true", "true"},
             {2, "false", "true"},
             {2, "true", "true"},
             {3, "false", "false"},
             {3, "true", "true"}
           ]

    # The fixture inventory must fail if the generated finite profile set grows.
    assert EdgeRecordRouteProfile.mapping() |> Map.values() |> Enum.sort() == [0, 1, 2, 3]
  end

  defp fixture(name), do: @testdata |> Path.join(name) |> File.read!()
end
