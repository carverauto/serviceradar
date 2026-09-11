defmodule ServiceRadar.Observability.SeasonalDisposition.EdgeBaselineProducerBatchingTest do
  @moduledoc """
  Database-free regression coverage for device-chunked edge baseline fetching.

  Covers the producer's chunking contract: latest-bucket discovery, device and
  interface filters, complete series coverage without overlap, and chunk-error
  propagation. The batching rationale lives in the producer.

  Runs in the database-free unit tier (no `:requires_app` tag): every query is
  served by the fake runners below.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.SeasonalDisposition.EdgeBaselineProducer
  alias ServiceRadar.Observability.SeasonalDisposition.Source

  defmodule ChunkedProfileRunner do
    @moduledoc false
    # Discovery (latest-only `profile_hour_of_week`) returns one row per device;
    # chunk queries (`profile_hour_of_week_full` + a `device_id:(...)` filter)
    # return the full 168-bucket profile scoped to the filtered devices.
    @devices ["sr:chunk-a", "sr:chunk-b", "sr:chunk-c"]

    def query(query, _opts) do
      send(self(), {:chunked_query, query})

      if String.contains?(query, "profile_hour_of_week_full(") do
        {:ok, Enum.flat_map(chunk_devices(query), &full_rows/1)}
      else
        {:ok, Enum.map(@devices, &latest_row/1)}
      end
    end

    def devices, do: @devices

    def chunk_devices(query) do
      case Regex.run(~r/device_id:\(([^)]*)\)/, query) do
        [_, ids] ->
          ids
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim(&1, "\""))
          |> Enum.filter(&(&1 in @devices))

        _ ->
          []
      end
    end

    defp latest_row(device) do
      %{
        "series" => device,
        "dow" => 1,
        "hod" => 9,
        "sample_value" => 40.0,
        "bucket" => "2026-06-22T09:00:00Z",
        "bucket_count" => 8,
        "center" => 40.0,
        "mad" => 2.0
      }
    end

    defp full_rows(device) do
      for dow <- 0..6,
          hod <- 0..23,
          do: Map.merge(latest_row(device), %{"dow" => dow, "hod" => hod})
    end
  end

  test "build fetches the full profile in bounded device chunks" do
    source = Enum.find(Source.defaults(), &(&1.name == "cpu_seasonal"))

    assert {:ok, baselines} =
             EdgeBaselineProducer.build(
               sources: [source],
               runner: ChunkedProfileRunner,
               edge_baseline_max_devices_per_query: 2
             )

    # Every device still gets its complete 168-bucket baseline.
    for device <- ChunkedProfileRunner.devices() do
      assert %{"buckets" => buckets} = baselines["#{device}|cpu.usage_percent"]
      assert length(buckets) == 168
    end

    # 3 host devices with a budget of 2 devices per statement: one discovery
    # query + 2 chunks.
    [discovery | chunks] = collect_chunk_queries()
    assert length(chunks) == 2

    refute String.contains?(discovery, "profile_hour_of_week_full(")

    assert Enum.all?(chunks, &String.contains?(&1, "profile_hour_of_week_full("))
    assert Enum.all?(chunks, &String.contains?(&1, "device_id:("))

    covered = chunks |> Enum.flat_map(&ChunkedProfileRunner.chunk_devices/1) |> Enum.sort()
    assert covered == Enum.sort(ChunkedProfileRunner.devices())
  end

  # A host device's full profile is 168 buckets over the whole history, and the
  # statement cost is non-linear in the device count (measured on demo: 5 devices
  # 0.8 s, 10 devices cancelled by the 30 s statement_timeout). One device per
  # statement is the only sizing that is predictable across fleets, so it is the
  # default; the interface path already chunks per device.
  test "host sources fetch one full-profile statement per device by default" do
    source = Enum.find(Source.defaults(), &(&1.name == "cpu_seasonal"))

    assert {:ok, baselines} =
             EdgeBaselineProducer.build(sources: [source], runner: ChunkedProfileRunner)

    assert map_size(baselines) == 3

    [discovery | chunks] = collect_chunk_queries()
    refute String.contains?(discovery, "profile_hour_of_week_full(")
    assert length(chunks) == 3
    assert Enum.all?(chunks, &String.contains?(&1, "profile_hour_of_week_full("))

    covered = Enum.map(chunks, &ChunkedProfileRunner.chunk_devices/1)
    assert Enum.all?(covered, &match?([_single_device], &1))
    assert covered |> List.flatten() |> Enum.sort() == Enum.sort(ChunkedProfileRunner.devices())
  end

  defmodule WideInterfaceRunner do
    @moduledoc false

    def query(query, _opts) do
      if String.contains?(query, "profile_hour_of_week_full(") do
        indexes =
          case Regex.run(~r/if_index:\(([^)]*)\)/, query) do
            [_, values] -> values |> String.split(",") |> Enum.map(&String.to_integer/1)
            nil -> Enum.to_list(1..512)
          end

        cap = Process.get(:interface_query_cap, 200)

        if length(indexes) > cap do
          {:error, :statement_timeout}
        else
          send(self(), {:fetched_interfaces, indexes})
          {:ok, for(index <- indexes, dow <- 0..6, hod <- 0..23, do: row(index, dow, hod))}
        end
      else
        {:ok, for(index <- 1..512, do: row(index, 1, 9))}
      end
    end

    defp row(index, dow, hod) do
      %{
        "series" => "sr:wide-device",
        "if_index" => index,
        "partition" => "synthetic-partition",
        "target_device_ip" => "192.0.2.10",
        "metric_name" => "ifInOctets",
        "dow" => dow,
        "hod" => hod,
        "sample_value" => index * 1.0,
        "bucket" => "2026-06-22T09:00:00Z",
        "bucket_count" => 8,
        "center" => index * 1.0,
        "mad" => 2.0
      }
    end
  end

  test "wide devices use disjoint interface chunks within the default and configured caps" do
    source = Enum.find(Source.defaults(), &(&1.name == "interface_if_in_octets_seasonal"))

    for cap <- [200, 127] do
      Process.put(:interface_query_cap, cap)

      opts = [
        sources: [source],
        runner: WideInterfaceRunner,
        interface_top_k_per_device: 512
      ]

      opts =
        if cap == 200, do: opts, else: Keyword.put(opts, :edge_baseline_max_combos_per_query, cap)

      assert {:ok, baselines} = EdgeBaselineProducer.build(opts)
      assert map_size(baselines) == 512

      for index <- 1..512 do
        assert %{"centers" => centers} = baselines["192.0.2.10|ifInOctets|#{index}"]
        assert centers == List.duplicate(index * 1.0, 168)
      end

      fetched =
        for _ <- 1..ceil(512 / cap) do
          assert_received {:fetched_interfaces, indexes}
          assert length(indexes) <= cap
          indexes
        end

      assert fetched |> List.flatten() |> Enum.sort() == Enum.to_list(1..512)
      refute_received {:fetched_interfaces, _}
    end
  end

  defmodule FailingChunkRunner do
    @moduledoc false

    def query(query, _opts) do
      if String.contains?(query, "profile_hour_of_week_full(") do
        {:error, :chunk_timeout}
      else
        {:ok, [latest_row_for("sr:chunk-a")]}
      end
    end

    defp latest_row_for(device) do
      %{
        "series" => device,
        "dow" => 1,
        "hod" => 9,
        "sample_value" => 40.0,
        "bucket" => "2026-06-22T09:00:00Z",
        "bucket_count" => 8,
        "center" => 40.0,
        "mad" => 2.0
      }
    end
  end

  test "a failing chunk query fails the source fetch" do
    source = Enum.find(Source.defaults(), &(&1.name == "cpu_seasonal"))

    assert {:error, :chunk_timeout} =
             EdgeBaselineProducer.build(sources: [source], runner: FailingChunkRunner)
  end

  defp collect_chunk_queries(acc \\ []) do
    receive do
      {:chunked_query, query} -> collect_chunk_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
