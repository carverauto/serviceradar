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
             identifier_type: :armis_device_id,
             source_id: "source-1",
             device_ids: ["device-a", "device-b"],
             source_ids: %{"device-a" => ["100"], "device-b" => ["200"]}
           } = SourceAuthorityGuard.conflict_from_rows(rows, ["device-b", "device-a"])
  end

  test "allows an empty side" do
    one_sided = [row("device-a", "100", "partition-a:armis:source-1", "source-1")]

    assert SourceAuthorityGuard.conflict_from_rows(one_sided, ["device-a", "device-b"]) == nil
  end

  test "blocks a shared source ID: both records have a history of the type" do
    shared = [
      row("device-a", "100", "partition-a:armis:source-1", "source-1"),
      archived(row("device-b", "100", "partition-a:armis:source-1", "source-1"))
    ]

    assert %{
             source_ids: %{"device-a" => ["100"], "device-b" => []},
             retired_source_ids: %{"device-a" => [], "device-b" => ["100"]}
           } = SourceAuthorityGuard.conflict_from_rows(shared, ["device-a", "device-b"])
  end

  test "a retired ID blocks a merge with a record holding a current one" do
    rows = [
      archived(row("device-a", "100", "partition-a:armis:source-1", "source-1")),
      row("device-b", "200", "partition-a:armis:source-1", "source-1")
    ]

    assert %{
             identifier_type: :armis_device_id,
             device_ids: ["device-a", "device-b"],
             source_ids: %{"device-a" => [], "device-b" => ["200"]},
             retired_source_ids: %{"device-a" => ["100"], "device-b" => []}
           } = SourceAuthorityGuard.conflict_from_rows(rows, ["device-b", "device-a"])
  end

  test "archived rows arrive with the type as text" do
    rows = [
      archived(
        row("device-a", "100", "partition-a:armis:source-1", "source-1", "armis_device_id")
      ),
      row("device-b", "200", "partition-a:armis:source-1", "source-1")
    ]

    assert %{identifier_type: :armis_device_id} =
             SourceAuthorityGuard.conflict_from_rows(rows, ["device-a", "device-b"])
  end

  test "a retired ID in another source scope does not block" do
    rows = [
      archived(row("device-a", "100", "partition-a:armis:source-2", "source-2")),
      row("device-b", "200", "partition-a:armis:source-1", "source-1")
    ]

    assert SourceAuthorityGuard.conflict_from_rows(rows, ["device-a", "device-b"]) == nil
  end

  test "does not compare IDs from different source scopes" do
    rows = [
      row("device-a", "100", "partition-a:armis:source-1", "source-1"),
      row("device-b", "200", "partition-a:armis:source-2", "source-2")
    ]

    assert SourceAuthorityGuard.conflict_from_rows(rows, ["device-a", "device-b"]) == nil
  end

  test "blocks disjoint NetBox IDs in one source scope" do
    rows = [
      row("device-a", "source-1:7", "default", "source-1", :netbox_device_id),
      row("device-b", "source-1:9", "default", "source-1", :netbox_device_id)
    ]

    assert %{
             identifier_type: :netbox_device_id,
             device_ids: ["device-a", "device-b"],
             source_ids: %{"device-a" => ["source-1:7"], "device-b" => ["source-1:9"]}
           } = SourceAuthorityGuard.conflict_from_rows(rows, ["device-b", "device-a"])
  end

  test "does not compare IDs of different source-authoritative types" do
    rows = [
      row("device-a", "100", "default", "source-1"),
      row("device-b", "source-1:9", "default", "source-1", :netbox_device_id)
    ]

    assert SourceAuthorityGuard.conflict_from_rows(rows, ["device-a", "device-b"]) == nil
  end

  describe "source_mismatch?/3" do
    setup do
      held = %{
        "device-a" => MapSet.new([{:armis_device_id, "default", "100", :live}]),
        "device-b" => MapSet.new([{:armis_device_id, "default:armis:source-2", "200", :live}]),
        "device-n" => MapSet.new([{:netbox_device_id, "default", "source-1:7", :live}]),
        "device-r" => MapSet.new([{:armis_device_id, "default", "300", :archived}]),
        "device-k" =>
          MapSet.new([
            {:armis_device_id, "default", "400", :live},
            {:armis_device_id, "default", "300", :archived}
          ])
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

    test "refuses a record holding a different NetBox id in the update's scope", %{held: held} do
      assert SourceAuthorityGuard.source_mismatch?(netbox("source-1:9"), "device-n", held)
      refute SourceAuthorityGuard.source_mismatch?(netbox("source-1:7"), "device-n", held)
    end

    test "compares only identifiers of the same type", %{held: held} do
      refute SourceAuthorityGuard.source_mismatch?(netbox("source-1:9"), "device-a", held)
      refute SourceAuthorityGuard.source_mismatch?(ids("200", "default"), "device-n", held)
    end

    test "refuses a record whose only id of the type retired, for a new id", %{held: held} do
      assert SourceAuthorityGuard.source_mismatch?(ids("500", "default"), "device-r", held)

      assert SourceAuthorityGuard.scoped_source_ids(held, "device-r", ids("500", "default")) ==
               ["300"]
    end

    test "does not return a retired id to the record that held it", %{held: held} do
      assert SourceAuthorityGuard.source_mismatch?(ids("300", "default"), "device-r", held)
      assert SourceAuthorityGuard.source_mismatch?(ids("300", "default"), "device-k", held)
    end

    test "accepts the current id of a record that also holds a retired one", %{held: held} do
      refute SourceAuthorityGuard.source_mismatch?(ids("400", "default"), "device-k", held)

      assert SourceAuthorityGuard.scoped_source_ids(held, "device-k", ids("400", "default")) ==
               ["300", "400"]
    end

    test "a retired id in another scope does not refuse", %{held: held} do
      refute SourceAuthorityGuard.source_mismatch?(ids("500", "other"), "device-r", held)
    end
  end

  test "claim/3 makes a claimed id refuse a later update carrying a different one" do
    held = SourceAuthorityGuard.claim(%{}, netbox("source-1:7"), "device-n")

    assert SourceAuthorityGuard.source_mismatch?(netbox("source-1:9"), "device-n", held)
    refute SourceAuthorityGuard.source_mismatch?(netbox("source-1:7"), "device-n", held)
    assert SourceAuthorityGuard.scoped_source_ids(held, "device-n", netbox("x")) == ["source-1:7"]
  end

  describe "collection_scope/2" do
    test "an Armis source instance accounts for its own partition suffix" do
      assert SourceAuthorityGuard.collection_scope("armis", "source-1") ==
               {:ok, %{identifier_type: :armis_device_id, partition_suffix: ":armis:source-1"}}
    end

    test "fails closed for a source without exact collections or without an instance" do
      assert SourceAuthorityGuard.collection_scope("netbox", "source-1") == :error
      assert SourceAuthorityGuard.collection_scope("armis", "") == :error
    end
  end

  defp ids(armis_id, partition), do: %{armis_id: armis_id, partition: partition}
  defp netbox(netbox_id), do: %{netbox_id: netbox_id, partition: "default"}

  defp archived(row), do: Map.put(row, :archived, true)

  defp row(device_id, identifier_value, partition, source_id, type \\ :armis_device_id) do
    %{
      device_id: device_id,
      identifier_type: type,
      identifier_value: identifier_value,
      partition: partition,
      metadata: %{"sync_service_id" => source_id}
    }
  end
end
