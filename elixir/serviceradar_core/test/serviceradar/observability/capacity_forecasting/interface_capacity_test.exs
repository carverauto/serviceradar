defmodule ServiceRadar.Observability.CapacityForecasting.InterfaceCapacityTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.CapacityForecasting.InterfaceCapacity

  defmodule CaptureRepo do
    @moduledoc false

    def one(query) do
      send(Process.get(:test_pid), {:interface_capacity_query, query})
      nil
    end
  end

  setup do
    Process.put(:test_pid, self())
    :ok
  end

  test "inventory lookup is scoped by the metric row partition" do
    assert {:ok, nil} =
             InterfaceCapacity.resolve(
               %{
                 "if_index" => 7,
                 "device_id" => "device-a",
                 "partition_id" => "edge-a"
               },
               repo: CaptureRepo
             )

    assert_received {:interface_capacity_query, query}

    assert Enum.any?(query.wheres, fn where ->
             where.params == [{"edge-a", :string}] and
               inspect(where.expr) =~ ":partition"
           end)

    assert inspect(query.select.expr) =~ ":partition"
  end
end
