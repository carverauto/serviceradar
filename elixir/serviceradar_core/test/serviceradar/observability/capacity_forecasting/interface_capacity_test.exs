defmodule ServiceRadar.Observability.CapacityForecasting.InterfaceCapacityTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.CapacityForecasting.InterfaceCapacity

  defmodule RepoSpy do
    @moduledoc false

    def one(query) do
      send(Process.get(:interface_capacity_test_pid), {:interface_capacity_query, query})

      %{
        device_id: "device-a",
        device_ip: "10.0.0.10",
        if_index: 7,
        if_name: "uplink",
        if_alias: "core",
        speed_bps: 1_000_000_000,
        if_speed: nil,
        timestamp: ~U[2026-06-12 12:00:00Z],
        partition: "edge-a"
      }
    end
  end

  setup do
    Process.put(:interface_capacity_test_pid, self())

    on_exit(fn ->
      Process.delete(:interface_capacity_test_pid)
    end)
  end

  test "lookup is constrained to the forecast row partition" do
    row = %{
      "partition" => "edge-a",
      "target_device_ip" => "10.0.0.10",
      "if_index" => 7
    }

    assert {:ok, %{speed_bps: 1_000_000_000, partition: "edge-a"}} =
             InterfaceCapacity.resolve(row, repo: RepoSpy)

    assert_receive {:interface_capacity_query, query}

    assert Enum.any?(query.wheres, fn where ->
             where.expr |> Macro.to_string() |> String.contains?("partition")
           end)
  end

  test "missing partition skips instead of running an unscoped lookup" do
    assert {:ok, %{skip_reason: :missing_partition}} =
             InterfaceCapacity.resolve(%{"target_device_ip" => "10.0.0.10", "if_index" => 7},
               repo: RepoSpy
             )

    refute_receive {:interface_capacity_query, _query}
  end
end
