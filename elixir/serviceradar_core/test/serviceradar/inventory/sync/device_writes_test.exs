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
end
