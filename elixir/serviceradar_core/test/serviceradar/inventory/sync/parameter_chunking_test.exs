defmodule ServiceRadar.Inventory.Sync.ParameterChunkingTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Sync.ParameterChunking

  @max_bound_parameters 65_535

  describe "insert_all_chunks/2" do
    test "splits rows on the chunk-size boundary and preserves order" do
      rows = for i <- 1..20, do: %{uid: "device-#{i}", ip: nil, hostname: "h-#{i}"}

      chunks =
        ParameterChunking.insert_all_chunks(rows, extra_parameters: @max_bound_parameters - 15)

      # Budget of 15 parameters over 3 bound columns per row => 5 rows per statement.
      assert Enum.map(chunks, &length/1) == [5, 5, 5, 5]
      assert List.flatten(chunks) == rows
    end

    test "sizes chunks on the union of every row's keys, not one row's width" do
      # The first row is narrow, later rows carry an extra column. A chunker
      # that sizes on the first row's width (2 columns => 32,767 rows per
      # statement) binds 3 parameters per row and overflows; the union-sized
      # chunks stay at the limit.
      narrow = %{uid: "seed", ip: nil}
      wide_rows = for _ <- 1..33_000, do: %{uid: "device", ip: nil, hostname: "h"}

      chunks = ParameterChunking.insert_all_chunks([narrow | wide_rows])

      assert Enum.map(chunks, &length/1) == [21_845, 11_156]
    end

    test "no chunk of a wide batch exceeds the limit" do
      rows = for i <- 1..50_000, do: %{uid: "device-#{i}", hostname: "h", mac: nil}

      chunks = ParameterChunking.insert_all_chunks(rows)

      assert Enum.map(chunks, &length/1) == [21_845, 21_845, 6_310]
    end

    test "a single row wider than the limit still yields a one-row chunk" do
      row = Map.new(1..70_000, fn i -> {:"col_#{i}", i} end)

      assert ParameterChunking.insert_all_chunks([row]) == [[row]]
    end

    test "empty input yields no chunks" do
      assert ParameterChunking.insert_all_chunks([]) == []
    end
  end
end
