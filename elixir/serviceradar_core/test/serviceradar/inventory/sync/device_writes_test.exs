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

    test "re-raises after deadlock retries are exhausted" do
      assert_raise Postgrex.Error, fn ->
        DeviceWrites.with_deadlock_retry(fn -> raise deadlock_error() end, 2)
      end
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

  test "deadlock_detected?/1 recognizes pg_code and atom code" do
    assert DeviceWrites.deadlock_detected?(deadlock_error())

    assert DeviceWrites.deadlock_detected?(%Postgrex.Error{
             message: "deadlock",
             postgres: %{code: :deadlock_detected, pg_code: "40P01", message: "deadlock"}
           })

    refute DeviceWrites.deadlock_detected?(unique_violation_error())
    refute DeviceWrites.deadlock_detected?(:other)
  end

  # Postgrex.Error.message/1 requires :message in the postgres map.
  defp deadlock_error do
    %Postgrex.Error{
      message: nil,
      postgres: %{
        code: :deadlock_detected,
        pg_code: "40P01",
        message: "deadlock detected",
        severity: "ERROR"
      }
    }
  end

  defp unique_violation_error do
    %Postgrex.Error{
      message: nil,
      postgres: %{
        code: :unique_violation,
        pg_code: "23505",
        message: "duplicate key value violates unique constraint",
        severity: "ERROR"
      }
    }
  end
end
