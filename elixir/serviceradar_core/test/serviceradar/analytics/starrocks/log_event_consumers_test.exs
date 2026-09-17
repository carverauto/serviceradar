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

  test "event window and dns/anomaly helpers query StarRocks events not platform.ocsf_events",
       %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:events])
    )

    query = fn sql ->
      refute sql =~ "platform.ocsf_events"
      refute sql =~ "events_hourly"
      send(self(), {:event_sql, sql})

      cond do
        sql =~ "serviceradar.events" and sql =~ "COUNT(*)" ->
          {:ok, %{rows: [["1999-06-15 12:00:00", 6, 11]]}}

        sql =~ "class_uid = 4003" ->
          assert sql =~ "serviceradar.events"
          {:ok, %{rows: [["192.0.2.10", "hagezi-pro", "1999-06-15 12:00:00"]]}}

        sql =~ "class_uid = 2004" ->
          assert sql =~ "source_type = 'anomaly_detection'"
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

    assert_received {:event_sql, _}
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
