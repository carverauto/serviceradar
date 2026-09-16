defmodule ServiceRadar.Analytics.StarRocks.DestinationTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.Analytics.StarRocks.Identity

  @moduletag :db_free

  @flow_rows [
    %{
      id: "flow-alpha-0001",
      time: ~U[2026-01-15 10:00:00Z],
      device_uid: "sr:host-alpha",
      src_endpoint_ip: "192.0.2.10",
      dst_endpoint_ip: "198.51.100.20",
      bytes_in: 1200,
      bytes_out: 80,
      packets_in: 4,
      packets_out: 2,
      sampling_rate: 1
    }
  ]

  test "flow identity is the observation, not only the five-tuple" do
    shared = %{
      src_endpoint_ip: "192.0.2.10",
      src_endpoint_port: 443,
      dst_endpoint_ip: "198.51.100.20",
      dst_endpoint_port: 51_200,
      protocol_num: 6,
      sampler_address: "192.0.2.1"
    }

    first = Map.merge(shared, %{time: ~U[2026-01-15 10:00:00Z], bytes_in: 1200, packets_in: 4})
    second = Map.merge(shared, %{time: ~U[2026-01-15 10:01:00Z], bytes_in: 44, packets_in: 1})

    refute Identity.record_id(:flows, first) == Identity.record_id(:flows, second)
  end

  test "tables are dataset-specific and not the demo namespace" do
    assert Destination.table_for(:flows) == "ocsf_network_activity"
    assert Destination.table_for(:flow_attribution) == "ocsf_network_activity"
    assert Destination.table_for(:metrics) == "timeseries_metrics"
    assert Destination.table_for(:logs) == "logs"
    assert Destination.table_for(:events) == "events"
  end

  test "disabled shadow writes are a no-op" do
    assert {:ok, :disabled} = Destination.maybe_shadow(:flows, @flow_rows, enabled: false)
  end

  test "partial success retries only the missing StarRocks destination" do
    persist_calls = :counters.new(1, [])

    persist = fn table, rows, _opts ->
      :counters.add(persist_calls, 1, 1)
      assert table == "ocsf_network_activity"
      assert hd(rows)["id"] == "flow-alpha-0001"
      {:ok, %{loaded: 1, label: "sr-flow-alpha"}}
    end

    assert {:ok, %{completed: [:cnpg, :starrocks], missing: [], loaded: 1}} =
             Destination.persist_shadow(:flows, @flow_rows,
               completed: [:cnpg],
               persist: persist
             )

    assert :counters.get(persist_calls, 1) == 1

    assert {:ok, %{completed: [:cnpg, :starrocks], missing: []}} =
             Destination.persist_shadow(:flows, @flow_rows,
               completed: [:cnpg, :starrocks],
               persist: persist
             )

    assert :counters.get(persist_calls, 1) == 1
  end

  test "StarRocks failure leaves the destination missing without requiring CNPG rewrite" do
    persist = fn _table, _rows, _opts -> {:error, :publish_timeout} end

    assert {:ok, %{completed: [:cnpg], missing: [:starrocks], partial: true}} =
             Destination.persist_shadow(:flows, @flow_rows,
               completed: [:cnpg],
               persist: persist
             )
  end

  test "metrics, logs and events encode through the destination seam" do
    persist = fn table, rows, _opts ->
      send(self(), {:loaded, table, rows})
      {:ok, %{loaded: length(rows)}}
    end

    metric = %{
      timestamp: ~U[2026-01-15 10:00:00Z],
      gateway_id: "gw-alpha",
      series_key: "if:1:bytes_in",
      metric_name: "if_octets_in",
      metric_type: "counter",
      value: 42.0,
      device_id: "sr:host-alpha"
    }

    log = %{
      id: "log-alpha-0001",
      timestamp: ~U[2026-01-15 10:00:01Z],
      ingest_identity: "seq:1:0",
      severity_text: "info",
      body: "synthetic log line"
    }

    event = %{
      id: "evt-alpha-0001",
      time: ~U[2026-01-15 10:00:02Z],
      class_uid: 1008,
      severity_id: 1
    }

    assert {:ok, %{missing: []}} =
             Destination.persist_shadow(:metrics, [metric], completed: [:cnpg], persist: persist)

    assert_received {:loaded, "timeseries_metrics", [loaded_metric]}
    assert loaded_metric["series_key"] == "if:1:bytes_in"

    assert {:ok, %{missing: []}} =
             Destination.persist_shadow(:logs, [log], completed: [:cnpg], persist: persist)

    assert_received {:loaded, "logs", [loaded_log]}
    assert loaded_log["id"] == "log-alpha-0001"

    assert {:ok, %{missing: []}} =
             Destination.persist_shadow(:events, [event], completed: [:cnpg], persist: persist)

    assert_received {:loaded, "events", [loaded_event]}
    assert loaded_event["id"] == "evt-alpha-0001"
  end

  test "persist_after_cnpg stays best-effort while cutover_datasets is empty" do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev |> Keyword.put(:cutover_datasets, []) |> Keyword.put(:shadow_datasets, [])
    )

    try do
      persist = fn _table, _rows, _opts -> {:error, :publish_timeout} end

      assert {:ok, :disabled} =
               Destination.persist_after_cnpg(:flows, @flow_rows,
                 persist: persist,
                 enabled: false
               )
    after
      Application.put_env(:serviceradar_core, StarRocks, prev)
    end
  end

  test "ack_cnpg_batch requires Stream Load when flows are cut over" do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:flows])
    )

    try do
      persist = fn table, rows, _opts ->
        send(self(), {:persist, table, rows})
        {:error, :publish_timeout}
      end

      insert = fn rows -> {:ok, length(rows)} end

      assert {:error, {:missing_destinations, %{missing: [:starrocks]}}} =
               Destination.ack_cnpg_batch(:flows, @flow_rows, insert, persist: persist)

      assert_received {:persist, "ocsf_network_activity", [row]}
      assert row["bytes_in"]
      assert row["bytes_in"] == 1200

      ok_persist = fn _table, _rows, _opts -> {:ok, %{loaded: 1}} end

      assert {:ok, 1} =
               Destination.ack_cnpg_batch(:flows, @flow_rows, insert, persist: ok_persist)

      quarantine = fn _table, _rows, _opts -> {:quarantine, {:filtered_rows, 1, "sr-lab"}} end

      assert {:ok, 1} =
               Destination.ack_cnpg_batch(:flows, @flow_rows, insert, persist: quarantine)
    after
      Application.put_env(:serviceradar_core, StarRocks, prev)
    end
  end
end
