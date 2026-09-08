defmodule ServiceRadar.Inventory.Sync.DeviceWritesTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Inventory.Sync.DeviceWrites

  setup do
    original_threshold =
      Application.fetch_env(:serviceradar_core, :inventory_rollup_bulk_refresh_threshold)

    on_exit(fn ->
      case original_threshold do
        {:ok, value} ->
          Application.put_env(
            :serviceradar_core,
            :inventory_rollup_bulk_refresh_threshold,
            value
          )

        :error ->
          Application.delete_env(:serviceradar_core, :inventory_rollup_bulk_refresh_threshold)
      end
    end)

    :ok
  end

  test "default threshold refreshes inventory rollups only for larger batches" do
    refute DeviceWrites.inventory_rollup_bulk_refresh_required?(nil)
    refute DeviceWrites.inventory_rollup_bulk_refresh_required?(0)
    refute DeviceWrites.inventory_rollup_bulk_refresh_required?(-1)
    refute DeviceWrites.inventory_rollup_bulk_refresh_required?(100)
    assert DeviceWrites.inventory_rollup_bulk_refresh_required?(101)
  end

  test "integer threshold is configurable" do
    Application.put_env(:serviceradar_core, :inventory_rollup_bulk_refresh_threshold, 2)

    refute DeviceWrites.inventory_rollup_bulk_refresh_required?(2)
    assert DeviceWrites.inventory_rollup_bulk_refresh_required?(3)
  end

  test "string threshold is configurable" do
    Application.put_env(:serviceradar_core, :inventory_rollup_bulk_refresh_threshold, "1")

    refute DeviceWrites.inventory_rollup_bulk_refresh_required?(1)
    assert DeviceWrites.inventory_rollup_bulk_refresh_required?(2)
  end

  test "invalid threshold falls back to default" do
    Application.put_env(:serviceradar_core, :inventory_rollup_bulk_refresh_threshold, "bad")

    refute DeviceWrites.inventory_rollup_bulk_refresh_required?(100)
    assert DeviceWrites.inventory_rollup_bulk_refresh_required?(101)
  end

  test "under-threshold successful rollup refresh is a no-op" do
    assert :ok = DeviceWrites.maybe_refresh_inventory_rollups(:ok, 1)
  end

  test "rollup refresh preserves non-success results" do
    assert {:error, :failed} =
             DeviceWrites.maybe_refresh_inventory_rollups({:error, :failed}, 999)
  end

  describe "upsert_lock_uids/2" do
    test "is the sorted unique union of release owners and prepared record uids" do
      records = [
        %{uid: "sr:z-claim", ip: "10.0.0.1"},
        %{uid: "sr:a-owner", ip: "10.0.0.2"},
        %{uid: "sr:m-mid", ip: "10.0.0.3"}
      ]

      releases = [
        {"sr:z-claim", "10.0.0.9"},
        {"sr:b-only-release", "10.0.0.8"}
      ]

      assert DeviceWrites.upsert_lock_uids(records, releases) == [
               "sr:a-owner",
               "sr:b-only-release",
               "sr:m-mid",
               "sr:z-claim"
             ]
    end

    test "includes prepared uids even when they are not release owners" do
      records = [%{uid: "sr:prepared-only", ip: "10.0.0.1"}]
      releases = [{"sr:release-owner", "10.0.0.2"}]

      assert DeviceWrites.upsert_lock_uids(records, releases) == [
               "sr:prepared-only",
               "sr:release-owner"
             ]
    end
  end

  describe "with_deadlock_retry/2" do
    test "retries on 40P01 and returns the eventual success" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      result =
        DeviceWrites.with_deadlock_retry(
          fn ->
            n = Agent.get_and_update(counter, fn c -> {c + 1, c + 1} end)

            if n == 1 do
              raise deadlock_error()
            end

            {:ok, :cleared}
          end,
          3
        )

      assert result == {:ok, :cleared}
      assert Agent.get(counter, & &1) == 2
    end

    test "exhausts the configured attempt budget before re-raising" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      assert_raise Postgrex.Error, fn ->
        DeviceWrites.with_deadlock_retry(
          fn ->
            Agent.update(counter, &(&1 + 1))
            raise deadlock_error()
          end,
          3
        )
      end

      # attempts_left starts at 3: try, retry (2 left), retry (1 left) → 3 calls.
      assert Agent.get(counter, & &1) == 3
    end

    test "does not retry non-deadlock Postgrex errors" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      assert_raise Postgrex.Error, fn ->
        DeviceWrites.with_deadlock_retry(
          fn ->
            Agent.update(counter, &(&1 + 1))
            raise unique_violation_error()
          end,
          3
        )
      end

      assert Agent.get(counter, & &1) == 1
    end
  end

  test "deadlock_detected?/1 matches atom-only and pg_code-only postgres maps" do
    assert DeviceWrites.deadlock_detected?(
             postgrex_error(%{code: :deadlock_detected, message: "deadlock detected"})
           )

    assert DeviceWrites.deadlock_detected?(
             postgrex_error(%{pg_code: "40P01", message: "deadlock detected"})
           )

    assert DeviceWrites.deadlock_detected?(deadlock_error())

    refute DeviceWrites.deadlock_detected?(unique_violation_error())
    refute DeviceWrites.deadlock_detected?(:other)
  end

  # Postgrex.Error.message/1 requires :message in the postgres map.
  defp deadlock_error do
    postgrex_error(%{
      code: :deadlock_detected,
      pg_code: "40P01",
      message: "deadlock detected",
      severity: "ERROR"
    })
  end

  defp unique_violation_error do
    postgrex_error(%{
      code: :unique_violation,
      pg_code: "23505",
      message: "duplicate key value violates unique constraint",
      severity: "ERROR"
    })
  end

  defp postgrex_error(postgres) do
    %Postgrex.Error{message: nil, postgres: postgres}
  end

  describe "jsonb_safe/1" do
    # The bytes below are the real ones that took farm01's sync ingestion down:
    # uuid ff82a43f-6e90-47c8-a126-0a75a1d234d9 as Postgrex returns it from a
    # `uuid` column -- a raw 16-byte binary, which satisfies is_binary/1 and so
    # slips through code that reasonably assumes a binary is text.
    @raw_uuid <<255, 130, 164, 63, 110, 144, 71, 200, 161, 38, 10, 117, 161, 210, 52, 217>>
    @printable "ff82a43f-6e90-47c8-a126-0a75a1d234d9"

    test "repairs a raw uuid binary into its printable form" do
      [record] =
        DeviceWrites.jsonb_safe([
          %{uid: "sr:1", metadata: %{"mac_vendor_oui_snapshot_id" => @raw_uuid}}
        ])

      assert record.metadata["mac_vendor_oui_snapshot_id"] == @printable
      assert {:ok, _} = Jason.encode(record.metadata)
    end

    test "drops an unencodable binary that is not a uuid, keeping the row" do
      [record] =
        DeviceWrites.jsonb_safe([
          %{uid: "sr:1", metadata: %{"junk" => <<255, 254, 253>>, "kept" => "value"}}
        ])

      refute Map.has_key?(record.metadata, "junk")
      assert record.metadata["kept"] == "value", "unrelated metadata must survive"
      assert {:ok, _} = Jason.encode(record.metadata)
    end

    test "one poisoned record does not affect the others in the batch" do
      # This is the whole point. insert_all is a single statement, so before this
      # guard existed one bad value failed every device in the batch -- on farm01
      # that was 87 devices at a time, for hours.
      records = [
        %{uid: "sr:clean-1", metadata: %{"a" => "1"}},
        %{uid: "sr:poisoned", metadata: %{"snapshot" => @raw_uuid}},
        %{uid: "sr:clean-2", metadata: %{"b" => "2"}}
      ]

      safe = DeviceWrites.jsonb_safe(records)

      assert length(safe) == 3
      assert Enum.all?(safe, fn r -> match?({:ok, _}, Jason.encode(r.metadata)) end)
      assert Enum.at(safe, 0).metadata == %{"a" => "1"}
      assert Enum.at(safe, 2).metadata == %{"b" => "2"}
      assert Enum.at(safe, 1).metadata["snapshot"] == @printable
    end

    test "leaves clean records untouched" do
      records = [%{uid: "sr:1", metadata: %{"vendor" => "Apple, Inc.", "n" => 3, "b" => true}}]

      assert DeviceWrites.jsonb_safe(records) == records
    end

    test "tolerates records with no metadata or non-map metadata" do
      records = [%{uid: "sr:1"}, %{uid: "sr:2", metadata: nil}]

      assert DeviceWrites.jsonb_safe(records) == records
    end
  end
end
