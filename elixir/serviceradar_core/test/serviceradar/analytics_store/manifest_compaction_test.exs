defmodule ServiceRadar.AnalyticsStore.ManifestCompactionTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore.FileManifest
  alias ServiceRadar.AnalyticsStore.ManifestCompaction

  test "packing bounds both files and rows without splitting objects or UTC partitions" do
    first = source(1, 2)
    second = source(2, 3)
    third = source(3, 4)
    next_day = %{source(4, 1) | partition_date: ~D[2001-01-03]}

    assert [^first, ^second] = ManifestCompaction.select_group([first, second, third], 2, 20)
    assert [^first, ^second] = ManifestCompaction.select_group([first, second, third], 10, 5)
    assert [] = ManifestCompaction.select_group([first, next_day], 10, 20)
  end

  test "a singleton old partition cannot block a later compactable partition" do
    old = %{source(1, 2) | partition_date: ~D[2001-01-01]}
    first = source(2, 3)
    second = source(3, 4)
    assert [^first, ^second] = ManifestCompaction.select_group([old, first, second], 10, 20)
  end

  test "replacement preserves source count, timestamp envelope and partition" do
    sources = [source(1, 2), source(2, 3)]
    target = target()
    assert :ok = ManifestCompaction.validate_replacement(sources, target)

    for changed <- [
          %{target | row_count: 4},
          %{target | min_timestamp: ~U[2001-01-02 00:01:00Z]},
          %{target | max_timestamp: ~U[2001-01-02 00:02:00Z]},
          %{target | table_name: "logs"},
          %{target | partition_date: ~D[2001-01-03]},
          %{target | content_checksum: ""},
          %{target | staging_key: hd(sources).object_key},
          Map.put(target, :archive_batch_id, "00000000-0000-0000-0000-000000000001")
        ] do
      assert {:error, :compaction_candidate_mismatch} =
               ManifestCompaction.validate_replacement(sources, changed)
    end
  end

  test "only a fresh immutable candidate key can become the replacement" do
    sources = [source(1, 2), source(2, 3)]

    for key <- [
          hd(sources).object_key,
          "analytics/v1/timeseries_metrics/date=2001-01-02/example.parquet",
          "analytics/v1/timeseries_metrics/_candidates/date=2001-01-02/../other.parquet",
          "analytics/v1/timeseries_metrics/_candidates/date=2001-01-02/*.parquet"
        ] do
      assert {:error, :compaction_candidate_mismatch} =
               ManifestCompaction.validate_replacement(sources, %{target() | object_key: key})
    end
  end

  test "unknown bounds, repeated sources and superseded files cannot be republished" do
    first = source(1, 2)
    second = source(2, 3)

    for sources <- [
          [],
          [first],
          [first, first],
          [first, %{second | status: :superseded}],
          [first, %{second | status: :expired}],
          [first, %{second | min_timestamp: nil}],
          [first, %{second | row_count: nil}]
        ] do
      assert {:error, :invalid_compaction_sources} =
               ManifestCompaction.validate_replacement(sources, target())
    end
  end

  test "retirement limits reject unbounded work before querying the catalog" do
    for limit <- [0, 257] do
      assert {:error, :invalid_retirement_limit} =
               ManifestCompaction.retire_expired("timeseries_metrics", ~D[2034-01-01],
                 limit: limit
               )
    end
  end

  test "candidate budget rejects invalid limits before querying the catalog" do
    for limits <- [[max_files: 1], [max_files: 257], [max_rows: 0], [max_rows: 500_001]] do
      assert {:error, :invalid_compaction_limits} =
               ManifestCompaction.compaction_candidates("timeseries_metrics", limits)
    end
  end

  defp source(id, rows) do
    %FileManifest{
      id: id,
      table_name: "timeseries_metrics",
      partition_date: ~D[2001-01-02],
      object_key:
        "analytics/v1/timeseries_metrics/_candidates/date=2001-01-02/example-#{id}.parquet",
      staging_key: "analytics/v1/timeseries_metrics/_staging/example-#{id}.parquet",
      row_count: rows,
      min_timestamp: ~U[2001-01-02 00:00:00Z],
      max_timestamp: ~U[2001-01-02 00:01:00Z],
      status: :published
    }
  end

  defp target do
    %{
      table_name: "timeseries_metrics",
      partition_date: ~D[2001-01-02],
      object_key:
        "analytics/v1/timeseries_metrics/_candidates/date=2001-01-02/compact-example.parquet",
      staging_key:
        "analytics/v1/timeseries_metrics/_candidates/date=2001-01-02/compact-example.parquet",
      row_count: 5,
      min_timestamp: ~U[2001-01-02 00:00:00Z],
      max_timestamp: ~U[2001-01-02 00:01:00Z],
      content_checksum: "synthetic-verification-checksum"
    }
  end
end
