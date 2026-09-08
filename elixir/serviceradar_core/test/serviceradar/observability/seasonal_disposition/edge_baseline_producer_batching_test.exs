defmodule ServiceRadar.Observability.SeasonalDisposition.EdgeBaselineProducerBatchingTest do
  @moduledoc """
  Database-free regression coverage for device-chunked edge baseline fetching.

  A single fleet-wide 168-bucket full-profile aggregation (180d x every series,
  with two `percentile_cont` passes) exceeds the database statement_timeout as
  the fleet grows (issues #4391/#4393). The producer therefore fetches the full
  profile in per-device chunks bounded by `:edge_baseline_max_combos_per_query`.
  These tests pin the chunking contract: one latest-bucket discovery query,
  full-profile chunk queries scoped by `device_id:(...)` IN filters, complete
  coverage with no device fetched twice, and chunk-error propagation.

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
               edge_baseline_max_combos_per_query: 2
             )

    # Every device still gets its complete 168-bucket baseline.
    for device <- ChunkedProfileRunner.devices() do
      assert %{"buckets" => buckets} = baselines["#{device}|cpu.usage_percent"]
      assert length(buckets) == 168
    end

    # 3 single-combo devices with a cap of 2: one discovery query + 2 chunks.
    [discovery | chunks] = collect_chunk_queries()
    assert length(chunks) == 2

    refute String.contains?(discovery, "profile_hour_of_week_full(")

    assert Enum.all?(chunks, &String.contains?(&1, "profile_hour_of_week_full("))
    assert Enum.all?(chunks, &String.contains?(&1, "device_id:("))

    covered = chunks |> Enum.flat_map(&ChunkedProfileRunner.chunk_devices/1) |> Enum.sort()
    assert covered == Enum.sort(ChunkedProfileRunner.devices())
  end

  test "small fleets stay on a single chunk query under the default cap" do
    source = Enum.find(Source.defaults(), &(&1.name == "cpu_seasonal"))

    assert {:ok, baselines} =
             EdgeBaselineProducer.build(sources: [source], runner: ChunkedProfileRunner)

    assert map_size(baselines) == 3

    [discovery, chunk] = collect_chunk_queries()
    refute String.contains?(discovery, "profile_hour_of_week_full(")
    assert String.contains?(chunk, "profile_hour_of_week_full(")

    assert ChunkedProfileRunner.chunk_devices(chunk) |> Enum.sort() ==
             Enum.sort(ChunkedProfileRunner.devices())
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
