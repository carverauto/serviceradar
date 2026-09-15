defmodule ServiceRadar.AnalyticsStore.FileManifestTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore.Catalog
  alias ServiceRadar.AnalyticsStore.FileManifest

  @start ~U[2034-08-09 10:00:00.000000Z]
  @stop ~U[2034-08-09 11:00:00.000000Z]

  test "same-day file bounds prune nonoverlapping batches while retaining inclusive boundaries" do
    records = [
      file("before", ~U[2034-08-09 08:00:00.000000Z], ~U[2034-08-09 09:59:59.999999Z]),
      file("start-boundary", ~U[2034-08-09 09:45:00.000000Z], @start),
      file("inside", ~U[2034-08-09 10:20:00.000000Z], ~U[2034-08-09 10:40:00.000000Z]),
      file("end-boundary", @stop, ~U[2034-08-09 11:15:00.000000Z]),
      file("after", ~U[2034-08-09 11:00:00.000001Z], ~U[2034-08-09 12:00:00.000000Z])
    ]

    assert ["start-boundary", "inside", "end-boundary"] == matching_keys(records, @start, @stop)
  end

  test "unknown bounds remain visible without weakening known bounds" do
    records = [
      file("legacy", nil, nil),
      file("unknown-start", nil, @start),
      file("unknown-end", @stop, nil),
      file("known-before", nil, ~U[2034-08-09 09:59:59.999999Z]),
      file("known-after", ~U[2034-08-09 11:00:00.000001Z], nil)
    ]

    assert ["legacy", "unknown-start", "unknown-end"] == matching_keys(records, @start, @stop)
  end

  test "published table and coarse UTC partition filters still apply to legacy rows" do
    records = [
      file("selected", nil, nil),
      %{file("staging", nil, nil) | status: :pending},
      %{file("other-table", nil, nil) | table_name: "other_metrics"},
      %{file("old-day", nil, nil) | partition_date: ~D[2034-08-08]},
      %{file("later-day", nil, nil) | partition_date: ~D[2034-08-10]}
    ]

    assert ["selected"] == matching_keys(records, @start, @stop)
    assert ["selected", "old-day", "later-day"] == matching_keys(records, nil, nil)
  end

  test "one-sided windows only apply their corresponding bound" do
    records = [
      file("before", ~U[2034-08-09 08:00:00.000000Z], ~U[2034-08-09 09:00:00.000000Z]),
      file("after", ~U[2034-08-09 12:00:00.000000Z], ~U[2034-08-09 13:00:00.000000Z])
    ]

    assert ["after"] == matching_keys(records, @start, nil)
    assert ["before"] == matching_keys(records, nil, @stop)
  end

  defp file(key, min_timestamp, max_timestamp) do
    %FileManifest{
      table_name: "timeseries_metrics",
      object_key: key,
      partition_date: ~D[2034-08-09],
      min_timestamp: min_timestamp,
      max_timestamp: max_timestamp,
      status: :published
    }
  end

  defp matching_keys(records, start_time, end_time) do
    query = FileManifest.published_query("timeseries_metrics", start_time, end_time)
    assert query.valid?
    assert {:ok, selected} = Ash.Filter.Runtime.filter_matches(Catalog, records, query.filter)
    Enum.map(selected, & &1.object_key)
  end
end
