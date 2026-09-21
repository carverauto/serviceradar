defmodule ServiceRadar.Analytics.StarRocks.LogEventConsumersTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.LogEventConsumers
  alias ServiceRadar.Analytics.StarRocks.Rows
  alias ServiceRadar.Observability.AnomalyIngestSilenceWorker
  alias ServiceRadar.PrefixTags.DnsPolicySource
  alias ServiceRadar.PrefixTags.Store

  @moduletag :db_free

  defmodule EventsCutoverRepoStub do
    @moduledoc false

    import ExUnit.Assertions

    def query(sql, [_cutoff]) do
      cond do
        sql =~ "timeseries_metrics" -> {:ok, %{rows: [[true]]}}
        sql =~ "anomaly_episodes" -> {:ok, %{rows: [[false]]}}
        sql =~ "addon_statuses" -> {:ok, %{rows: [[false]]}}
        sql =~ "ocsf_events" -> flunk("events cutover must not query platform.ocsf_events")
      end
    end
  end

  setup do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])
    Store.clear()

    on_exit(fn ->
      Store.clear()
      Application.put_env(:serviceradar_core, StarRocks, prev)
    end)

    %{prev: prev}
  end

  test "event encode flattens RPZ and anomaly fields for remaining readers" do
    encoded =
      Rows.encode(:events, [
        %{
          id: "evt-alpha-0001",
          time: ~U[1999-06-15 12:00:00Z],
          class_uid: 4003,
          src_endpoint: %{"ip" => "192.0.2.10"},
          raw_data: ~s({"firewall_rule":{"name":"hagezi-pro"}}),
          metadata: %{"service_radar" => %{"source_type" => "anomaly_detection"}}
        }
      ])

    assert hd(encoded)["src_endpoint_ip"] == "192.0.2.10"
    assert hd(encoded)["firewall_rule_name"] == "hagezi-pro"
    assert hd(encoded)["source_type"] == "anomaly_detection"
    refute Map.has_key?(hd(encoded), "bytes_in")
  end

  test "event encode keeps the documents SRQL filters by path" do
    [encoded] =
      Rows.encode(:events, [
        %{
          id: "evt-alpha-0002",
          time: ~U[1999-06-15 12:00:00Z],
          class_uid: 2004,
          category_uid: 2,
          log_level: "error",
          metadata: %{"service_radar" => %{"device_uid" => "sr:device-0001"}},
          unmapped: ~s({"event_type":"anomaly"}),
          device: %{}
        }
      ])

    assert encoded["log_level"] == "error"

    assert Jason.decode!(encoded["metadata"]) == %{
             "service_radar" => %{"device_uid" => "sr:device-0001"}
           }

    assert Jason.decode!(encoded["unmapped"]) == %{"event_type" => "anomaly"}
    # An empty document is stored as one; NULL is left to mean "never written".
    assert encoded["device"] == "{}"
  end

  test "event encode drops a document wider than its warehouse column, not the event" do
    [encoded] =
      Rows.encode(:events, [
        %{
          id: "evt-alpha-0003",
          time: ~U[1999-06-15 12:00:00Z],
          class_uid: 2004,
          metadata: %{"blob" => String.duplicate("x", 1_048_576)},
          unmapped: "not json",
          device: nil
        }
      ])

    assert encoded["id"]
    assert is_nil(encoded["metadata"])
    assert is_nil(encoded["unmapped"])
    assert is_nil(encoded["device"])
  end

  test "whole-hour event windows read the rollup while row helpers stay on raw events",
       %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:events])
    )

    query = fn sql ->
      refute sql =~ "platform.ocsf_events"
      send(self(), {:event_sql, sql})

      cond do
        # The rollup gate probes through the same :query seam every other
        # statement uses, so the stub answers both high-water marks: the view
        # has kept up with the table it aggregates.
        sql == "SELECT MAX(`bucket`) FROM serviceradar.events_hourly" ->
          {:ok, %{rows: [["1999-06-15 23:00:00"]], num_rows: 1}}

        sql == "SELECT MAX(`time`) FROM serviceradar.events" ->
          {:ok, %{rows: [["1999-06-15 23:30:00"]], num_rows: 1}}

        sql =~ "SUM(total_count)" ->
          assert sql =~ "serviceradar.events_hourly"
          assert sql =~ "`bucket` >= '1999-06-15T00:00:00Z'"
          assert sql =~ "`bucket` < '1999-06-16T01:00:00Z'"
          {:ok, %{rows: [["1999-06-15 12:00:00", 6, 11]]}}

        sql =~ "class_uid = 4003" ->
          assert sql =~ "serviceradar.events"
          refute sql =~ "events_hourly"
          {:ok, %{rows: [["192.0.2.10", "hagezi-pro", "1999-06-15 12:00:00"]]}}

        sql =~ "class_uid = 2004" ->
          assert sql =~ "source_type = 'anomaly_detection'"
          refute sql =~ "events_hourly"
          {:ok, %{rows: [[1]], num_rows: 1}}

        true ->
          {:ok, %{rows: [], num_rows: 0}}
      end
    end

    assert {:ok, %{rows: [[bucket, 6, 11]]}} =
             LogEventConsumers.event_window_rows(
               ~U[1999-06-15 00:00:00Z],
               ~U[1999-06-16 00:00:00Z],
               86_400,
               query: query
             )

    assert %DateTime{} = bucket

    assert {:ok, %{rows: [["192.0.2.10", "hagezi-pro", "1999-06-15 12:00:00"]]}} =
             LogEventConsumers.dns_rpz_clients(24, 50, query: query)

    assert {:ok, true} =
             LogEventConsumers.anomaly_detection_present?(~U[1999-06-15 12:00:00Z], query: query)

    assert {:ok, %{rows: [[_, 6, 11]]}} =
             LogEventConsumers.event_window_rows(
               ~U[1999-06-15 00:00:00Z],
               ~U[1999-06-15 01:00:00Z],
               60,
               query: fn sql ->
                 refute sql =~ "events_hourly"
                 assert sql =~ "COUNT(*)"
                 assert sql =~ "`time` >= '1999-06-15T00:00:00Z'"
                 {:ok, %{rows: [["1999-06-15 00:30:00", 6, 11]]}}
               end
             )

    assert_received {:event_sql, _}
  end

  # The gate swaps the source underneath an unchanged window, so it must not be
  # able to change the answer. A whole-hour bucket is scored on the hour, so both
  # edge hours belong in the answer whole on BOTH sources; before this, the
  # rollup read them whole while the raw fallback truncated the leading hour at
  # 00:37 and the trailing hour at 00:37, silently shrinking the first and last
  # points of the chart.
  test "fresh and stale event windows score the same whole hours" do
    probe = fn mv_max ->
      fn sql ->
        cond do
          sql == "SELECT MAX(`bucket`) FROM serviceradar.events_hourly" ->
            {:ok, %{rows: [[mv_max]], num_rows: 1}}

          sql == "SELECT MAX(`time`) FROM serviceradar.events" ->
            {:ok, %{rows: [[~N[1999-06-15 12:00:00]]], num_rows: 1}}

          true ->
            send(self(), {:window_sql, sql})
            {:ok, %{rows: [["1999-06-15 12:00:00", 6, 11]]}}
        end
      end
    end

    read = fn mv_max, start_at, end_at ->
      assert {:ok, %{rows: [[_, 6, 11]]}} =
               LogEventConsumers.event_window_rows(start_at, end_at, 21_600,
                 query: probe.(mv_max)
               )

      assert_received {:window_sql, sql}
      sql
    end

    windows = [
      {~U[1999-06-15 00:37:12Z], ~U[1999-06-16 00:37:12Z], "1999-06-15T00:00:00Z",
       "1999-06-16T01:00:00Z"},
      {~U[1999-06-15 00:00:00Z], ~U[1999-06-16 00:00:00Z], "1999-06-15T00:00:00Z",
       "1999-06-16T01:00:00Z"}
    ]

    for {start_at, end_at, lower, upper} <- windows do
      fresh = read.(~N[1999-06-15 12:00:00], start_at, end_at)
      stale = read.(~N[1999-06-14 00:00:00], start_at, end_at)

      assert fresh =~ "serviceradar.events_hourly"
      assert stale =~ "serviceradar.events"
      refute stale =~ "events_hourly"

      for sql <- [fresh, stale] do
        assert sql =~ ">= '#{lower}'"
        assert sql =~ "< '#{upper}'"
      end
    end
  end

  test "a stale rollup view falls back to the raw StarRocks events table" do
    # The view sits a day and a half behind the table it aggregates, which is
    # staleness; the same gap against the wall clock on an idle dataset is not.
    query = fn sql ->
      cond do
        sql == "SELECT MAX(`bucket`) FROM serviceradar.events_hourly" ->
          {:ok, %{rows: [[~N[1999-06-14 00:00:00]]], num_rows: 1}}

        sql == "SELECT MAX(`time`) FROM serviceradar.events" ->
          {:ok, %{rows: [[~N[1999-06-15 12:00:00]]], num_rows: 1}}

        true ->
          # Stale MV: the whole-hour window reads raw events, never CNPG.
          refute sql =~ "events_hourly"
          refute sql =~ "platform.ocsf_events"
          assert sql =~ "serviceradar.events"
          assert sql =~ "COUNT(*)"
          assert sql =~ "`time` >= '1999-06-15T00:00:00Z'"
          {:ok, %{rows: [["1999-06-15 12:00:00", 6, 11]]}}
      end
    end

    assert {:ok, %{rows: [[bucket, 6, 11]]}} =
             LogEventConsumers.event_window_rows(
               ~U[1999-06-15 00:00:00Z],
               ~U[1999-06-16 00:00:00Z],
               86_400,
               query: query
             )

    assert %DateTime{} = bucket
  end

  test "an idle events dataset keeps reading its rollup" do
    query = fn sql ->
      cond do
        sql == "SELECT MAX(`bucket`) FROM serviceradar.events_hourly" ->
          {:ok, %{rows: [[~N[1999-06-15 03:00:00]]], num_rows: 1}}

        sql == "SELECT MAX(`time`) FROM serviceradar.events" ->
          {:ok, %{rows: [[~N[1999-06-15 03:40:00]]], num_rows: 1}}

        true ->
          assert sql =~ "serviceradar.events_hourly"
          assert sql =~ "SUM(total_count)"
          {:ok, %{rows: [["1999-06-15 12:00:00", 6, 11]]}}
      end
    end

    assert {:ok, %{rows: [[_bucket, 6, 11]]}} =
             LogEventConsumers.event_window_rows(
               ~U[1999-06-15 00:00:00Z],
               ~U[1999-06-16 00:00:00Z],
               86_400,
               query: query
             )
  end

  test "dns-policy reload reads StarRocks when events are cut over", %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:events])
    )

    query = fn sql ->
      assert sql =~ "serviceradar.events"
      refute sql =~ "platform.ocsf_events"
      refute sql =~ "events_hourly"
      send(self(), {:dns_sql, sql})
      {:ok, %{rows: [["192.0.2.10", "hagezi-pro", ~U[1999-06-15 12:00:00Z]]]}}
    end

    assert {:ok, %{row_count: 1, snapshot_at: %DateTime{}}} =
             DnsPolicySource.reload(broadcast?: false, query: query)

    assert_received {:dns_sql, _sql}
    tags = "192.0.2.10" |> Store.lookup() |> Enum.flat_map(& &1.tags)
    assert "dns-policy:hit" in tags
    assert "dns-policy:hagezi-pro" in tags
  end

  test "anomaly ingest silence uses StarRocks for 2004 rows when events are cut over",
       %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:events])
    )

    query = fn sql ->
      assert sql =~ "serviceradar.events"
      refute sql =~ "platform.ocsf_events"
      refute sql =~ "events_hourly"
      send(self(), {:silence_event_sql, sql})
      {:ok, %{rows: [[1]], num_rows: 1}}
    end

    assert :ok =
             AnomalyIngestSilenceWorker.run(
               query: query,
               now: ~U[1999-06-15 12:00:00Z],
               repo: EventsCutoverRepoStub,
               health_recorder: fn check, healthy?, _ ->
                 send(self(), {:health, check, healthy?})
                 :ok
               end
             )

    assert_received {:silence_event_sql, _sql}
    assert_received {:health, "anomaly-ingest-silence", true}
  end
end
