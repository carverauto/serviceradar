defmodule ServiceRadar.Analytics.StarRocks.DestinationTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.Analytics.StarRocks.Identity
  alias ServiceRadar.Analytics.StarRocks.Rows

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

  test "binary UUID log ids encode as JSON-safe hyphenated UUIDs" do
    {:ok, bin} = Ecto.UUID.dump("550e8400-e29b-41d4-a716-446655440000")

    assert Identity.record_id(:logs, %{id: bin, timestamp: ~U[2026-01-15 10:00:01Z]}) ==
             "550e8400-e29b-41d4-a716-446655440000"

    encoded =
      Rows.encode(:logs, [
        %{id: bin, timestamp: ~U[2026-01-15 10:00:01Z], body: "synthetic uuid log"}
      ])

    assert hd(encoded)["id"] == "550e8400-e29b-41d4-a716-446655440000"
    assert {:ok, _} = Jason.encode(encoded)
  end

  test "shadow persist crash does not fail ACK while cutover is empty" do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev
      |> Keyword.put(:enabled, true)
      |> Keyword.put(:shadow_datasets, [:logs])
      |> Keyword.put(:cutover_datasets, [])
    )

    try do
      persist = fn _table, _rows, _opts -> raise "stream load unavailable" end

      assert {:ok, :disabled} =
               Destination.persist_after_cnpg(
                 :logs,
                 [%{id: "log-alpha-0001", timestamp: ~U[2026-01-15 10:00:01Z], body: "x"}],
                 persist: persist
               )
    after
      Application.put_env(:serviceradar_core, StarRocks, prev)
    end
  end

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

  test "flow Stream Load documents carry protocol and ports for the Flows UI" do
    [encoded] =
      Rows.encode(:flows, [
        %{
          time: ~U[2026-01-15 10:00:00Z],
          src_endpoint_ip: "192.0.2.10",
          src_endpoint_port: 443,
          dst_endpoint_ip: "198.51.100.20",
          dst_endpoint_port: 51_200,
          protocol_num: 6,
          protocol_name: "tcp",
          direction_label: "egress",
          bytes_in: 1200
        }
      ])

    assert encoded["protocol_num"] == 6
    assert encoded["protocol_name"] == "tcp"
    assert encoded["src_endpoint_port"] == 443
    assert encoded["dst_endpoint_port"] == 51_200
    assert encoded["direction_label"] == "egress"
  end

  @tag :flow_counter_regression
  test "flow encoding preserves canonical totals and missing directional counters" do
    for {counters, expected_bytes, expected_packets} <- [
          {%{bytes_total: 1200, packets_total: 12}, 1200, 12},
          {%{bytes_total: 1200, bytes_in: 1200, packets_total: 12, packets_in: 12}, 1200, 12},
          {%{bytes_total: 1200, bytes_out: 1200, packets_total: 12, packets_out: 12}, 1200, 12},
          {%{bytes_in: 1000, bytes_out: 200, packets_in: 10, packets_out: 2}, 1200, 12},
          {%{bytes_in: 1200, packets_in: 12}, 1200, 12},
          {%{bytes_total: 0, bytes_in: 1200, packets_total: 0, packets_in: 12}, 0, 0}
        ] do
      row = Map.put(counters, :id, "synthetic-flow-counter")

      for input <- [row, Map.new(row, fn {key, value} -> {Atom.to_string(key), value} end)] do
        [encoded] = Rows.encode(:flows, [input])
        assert encoded["bytes_total"] == expected_bytes
        assert encoded["packets_total"] == expected_packets

        for field <- [:bytes_in, :bytes_out, :packets_in, :packets_out] do
          assert encoded[Atom.to_string(field)] == Map.get(counters, field)
        end
      end
    end
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

  test "enabling the warehouse shadows every telemetry dataset" do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev |> Keyword.put(:enabled, true) |> Keyword.put(:shadow_datasets, [])
    )

    try do
      persist = fn table, _rows, _opts -> {:ok, %{loaded: 1, label: "sr-#{table}"}} end

      log = %{
        id: "log-alpha-0001",
        timestamp: ~U[2026-01-15 10:00:01Z],
        ingest_identity: "seq:1:0",
        severity_text: "info",
        body: "synthetic log line"
      }

      assert {:ok, %{missing: []}} =
               Destination.maybe_shadow(:logs, [log], persist: persist)
    after
      Application.put_env(:serviceradar_core, StarRocks, prev)
    end
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
