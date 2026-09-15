defmodule ServiceRadar.AnalyticsStore.ArchiveBatchTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore.ArchiveBatch
  alias ServiceRadar.ColdTier.Registry

  @time ~U[2025-03-02 01:00:00Z]

  defp row(overrides \\ %{}) do
    columns = Enum.map(Registry.fetch!("timeseries_metrics").columns, &elem(&1, 0))

    columns
    |> Map.new(&{&1, nil})
    |> Map.merge(%{
      "timestamp" => @time,
      "created_at" => @time,
      "gateway_id" => "synthetic-gateway",
      "series_key" => "synthetic-series",
      "metric_name" => "synthetic_metric",
      "metric_type" => "gauge",
      "value" => 12.5,
      "tags" => %{"fixture" => "invented"},
      "metadata" => %{"counter_bits" => 64}
    })
    |> Map.merge(overrides)
  end

  test "payloads preserve canonical row types and actual bounds across late arrivals" do
    earlier = DateTime.add(@time, -60)
    previous_day = DateTime.add(@time, -86_400)
    rows = [row(), row(%{"timestamp" => previous_day}), row(%{"timestamp" => earlier})]
    assert {:ok, [previous, current]} = ArchiveBatch.prepare_batches("timeseries_metrics", rows)
    assert previous.partition_date == ~D[2025-03-01]
    assert current.partition_date == ~D[2025-03-02]
    assert current.min_timestamp == earlier
    assert current.max_timestamp == @time
    assert {:ok, [decoded, _]} = ArchiveBatch.decode_payload(current)
    assert DateTime.compare(decoded.timestamp, @time) == :eq
    assert decoded.value == 12.5
    assert decoded.tags == %{"fixture" => "invented"}
    assert decoded.metadata == %{"counter_bits" => 64}
    assert previous.id != current.id
  end

  test "partitioning uses UTC rather than the input clock's local date" do
    local = %{
      @time
      | day: 1,
        hour: 23,
        utc_offset: -7200,
        time_zone: "Etc/GMT+2",
        zone_abbr: "UTC-02"
    }

    assert {:ok, [batch]} =
             ArchiveBatch.prepare_batches("timeseries_metrics", [row(%{"timestamp" => local})])

    assert batch.partition_date == ~D[2025-03-02]
    assert batch.min_timestamp.time_zone == "Etc/UTC"
  end

  test "both row count and serialized byte limits split batches without dropping rows" do
    assert {:ok, batches} =
             ArchiveBatch.prepare_batches("timeseries_metrics", List.duplicate(row(), 10_001))

    assert Enum.map(batches, & &1.row_count) == [10_000, 1]
    assert {:ok, decoded} = ArchiveBatch.decode_payload(hd(batches))
    assert length(decoded) == 10_000

    large = row(%{"metadata" => %{"synthetic_padding" => String.duplicate("x", 4_500_000)}})
    assert {:ok, batches} = ArchiveBatch.prepare_batches("timeseries_metrics", [large, large])
    assert length(batches) == 2
    assert Enum.map(batches, & &1.row_count) == [1, 1]
    assert Enum.all?(batches, &(&1.payload_bytes <= 8_388_608))

    oversized = row(%{"metadata" => %{"synthetic_padding" => String.duplicate("x", 8_388_608)}})

    assert {:error, :archive_row_too_large} =
             ArchiveBatch.prepare_batches("timeseries_metrics", [oversized])
  end

  test "payload corruption and mismatched metadata fail before publication" do
    assert {:ok, [batch]} = ArchiveBatch.prepare_batches("timeseries_metrics", [row()])

    for invalid <- [
          %{batch | payload: batch.payload <> "x"},
          %{batch | content_checksum: String.duplicate("0", 64)},
          %{batch | schema_version: 2},
          %{batch | row_count: 2},
          %{batch | partition_date: ~D[2025-03-01]},
          %{batch | min_timestamp: DateTime.add(@time, -1)}
        ] do
      assert {:error, :invalid_archive_payload} = ArchiveBatch.decode_payload(invalid)
    end
  end

  test "unknown columns, missing identity and unsupported tables fail closed" do
    assert {:error, :invalid_archive_columns} =
             ArchiveBatch.prepare_batches("timeseries_metrics", [
               Map.put(row(), "unknown_column", "value")
             ])

    assert {:error, :invalid_archive_row} =
             ArchiveBatch.prepare_batches("timeseries_metrics", [row(%{"gateway_id" => nil})])

    assert {:error, :unsupported_archive_table} =
             ArchiveBatch.prepare_batches("not_an_analytics_table", [row()])

    assert {:ok, []} = ArchiveBatch.prepare_batches("timeseries_metrics", [])
  end
end
