defmodule ServiceRadar.Inventory.Identity.SourceAuthorityGuardTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.SourceAuthorityGuard

  test "blocks disjoint Armis IDs in one source scope" do
    rows = [
      row("device-a", "100", "partition-a:armis:source-1", "source-1"),
      row("device-b", "200", "partition-a:armis:source-1", "source-1")
    ]

    assert %{
             source_id: "source-1",
             device_ids: ["device-a", "device-b"],
             source_ids: %{"device-a" => ["100"], "device-b" => ["200"]}
           } = SourceAuthorityGuard.conflict_from_rows(rows, ["device-b", "device-a"])
  end

  test "allows an empty side or a shared source ID" do
    shared = [
      row("device-a", "100", "partition-a:armis:source-1", "source-1"),
      row("device-b", "100", "partition-a:armis:source-1", "source-1")
    ]

    assert SourceAuthorityGuard.conflict_from_rows(shared, ["device-a", "device-b"]) == nil

    one_sided = [row("device-a", "100", "partition-a:armis:source-1", "source-1")]

    assert SourceAuthorityGuard.conflict_from_rows(one_sided, ["device-a", "device-b"]) == nil
  end

  test "does not compare IDs from different source scopes" do
    rows = [
      row("device-a", "100", "partition-a:armis:source-1", "source-1"),
      row("device-b", "200", "partition-a:armis:source-2", "source-2")
    ]

    assert SourceAuthorityGuard.conflict_from_rows(rows, ["device-a", "device-b"]) == nil
  end

  test "blocks disjoint NetBox ids without comparing them to Armis ids" do
    rows = [
      row("device-a", "nb-1", "default", "netbox-source", :netbox_device_id),
      row("device-b", "nb-2", "default", "netbox-source", :netbox_device_id),
      row("device-a", "100", "default", "armis-source", :armis_device_id)
    ]

    assert %{identifier_type: :netbox_device_id, source_id: "netbox-source"} =
             SourceAuthorityGuard.conflict_from_rows(rows, ["device-a", "device-b"])
  end

  describe "source_mismatch?/3" do
    setup do
      held = %{
        "device-a" => MapSet.new([{"default", "100"}]),
        "device-b" => MapSet.new([{"default:armis:source-2", "200"}])
      }

      {:ok, held: held}
    end

    test "refuses a record holding a different id in the update's scope", %{held: held} do
      assert SourceAuthorityGuard.source_mismatch?(ids("200", "default"), "device-a", held)
    end

    test "accepts a record holding the update's own id", %{held: held} do
      refute SourceAuthorityGuard.source_mismatch?(ids("100", "default"), "device-a", held)
    end

    test "accepts a record holding no id, or ids only in another scope", %{held: held} do
      refute SourceAuthorityGuard.source_mismatch?(ids("100", "default"), "device-c", held)
      refute SourceAuthorityGuard.source_mismatch?(ids("100", "default"), "device-b", held)
    end

    test "never refuses for an update without a source-authoritative id", %{held: held} do
      refute SourceAuthorityGuard.source_mismatch?(%{partition: "default"}, "device-a", held)
    end

    test "refuses a different NetBox id and a different integration id in the same scope" do
      held = %{
        "device-a" =>
          MapSet.new([
            {"default", "netbox_device_id", "nb-1"},
            {"default", "integration_id", "netbox:source-a:device:nb-1"}
          ])
      }

      assert SourceAuthorityGuard.source_mismatch?(
               %{netbox_id: "nb-2", partition: "default"},
               "device-a",
               held
             )

      assert SourceAuthorityGuard.source_mismatch?(
               %{integration_id: "netbox:source-a:device:nb-2", partition: "default"},
               "device-a",
               held
             )

      refute SourceAuthorityGuard.source_mismatch?(
               %{netbox_id: "nb-1", partition: "default"},
               "device-a",
               held
             )

      refute SourceAuthorityGuard.source_mismatch?(
               %{armis_id: "200", partition: "default"},
               "device-a",
               held
             )
    end
  end

  defp ids(armis_id, partition), do: %{armis_id: armis_id, partition: partition}

  defp row(device_id, identifier_value, partition, source_id, identifier_type \\ :armis_device_id) do
    %{
      device_id: device_id,
      identifier_type: identifier_type,
      identifier_value: identifier_value,
      partition: partition,
      metadata: %{"sync_service_id" => source_id}
    }
  end
end
