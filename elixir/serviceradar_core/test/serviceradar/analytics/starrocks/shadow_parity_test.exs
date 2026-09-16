defmodule ServiceRadar.Analytics.StarRocks.ShadowParityTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Analytics.StarRocks.Backfill
  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.Analytics.StarRocks.ShadowParity

  @moduletag :db_free

  @interval_start ~U[2026-01-15 10:00:00Z]
  @interval_end ~U[2026-01-15 10:01:00Z]

  @flow_truth [
    %{
      id: "flow-alpha-0001",
      time: @interval_start,
      device_uid: "sr:host-alpha",
      src_endpoint_ip: "192.0.2.10",
      src_endpoint_port: 443,
      dst_endpoint_ip: "198.51.100.20",
      dst_endpoint_port: 51_200,
      bytes_in: 1200,
      bytes_out: 80,
      packets_in: 4,
      packets_out: 2,
      sampling_rate: 1
    },
    %{
      id: "flow-alpha-0002",
      time: @interval_end,
      device_uid: "sr:host-alpha",
      src_endpoint_ip: "192.0.2.11",
      src_endpoint_port: nil,
      dst_endpoint_ip: "198.51.100.21",
      dst_endpoint_port: nil,
      bytes_in: 44,
      bytes_out: nil,
      packets_in: 1,
      packets_out: nil,
      sampling_rate: 100
    }
  ]

  @metric_truth [
    %{
      timestamp: @interval_start,
      gateway_id: "gw-alpha",
      series_key: "cpu:0:usage",
      metric_name: "usage_percent",
      metric_type: "gauge",
      device_id: "sr:host-alpha",
      value: 12.5,
      unit: "percent",
      if_index: nil
    },
    %{
      timestamp: @interval_end,
      gateway_id: "gw-alpha",
      series_key: "if:1:bytes_in",
      metric_name: "if_octets_in",
      metric_type: "counter",
      device_id: "sr:host-alpha",
      value: 900.0,
      unit: nil,
      if_index: 1
    }
  ]

  test "flow shadow destination matches counts, totals, NULLs, sampling and rate" do
    source = ShadowParity.summarize(:flows, @flow_truth)
    destination = shadow_summary(:flows, @flow_truth)

    assert source.count == 2
    assert source["bytes_in_total"] == 1244
    assert source["bytes_out_total"] == 80
    assert source["null_bytes_out"] == 1
    assert source["null_src_endpoint_port"] == 1
    assert source["sampling_weighted_bytes_in"] == 1200 + 44 * 100
    assert source.rate_count_per_s == 2 / 60

    assert :ok = ShadowParity.compare(source, destination)
  end

  test "a dropped flow row is a mismatch that blocks cutover" do
    source = ShadowParity.summarize(:flows, @flow_truth)
    destination = ShadowParity.summarize(:flows, Enum.take(@flow_truth, 1))

    assert {:mismatch, diffs} = ShadowParity.compare(source, destination)
    assert diffs.count == %{source: 2, destination: 1}
    assert diffs["bytes_in_total"] == %{source: 1244, destination: 1200}
  end

  test "metric shadow destination matches values and NULL unit/if_index" do
    source = ShadowParity.summarize(:metrics, @metric_truth)
    destination = shadow_summary(:metrics, @metric_truth)

    assert source.count == 2
    assert source["value_total"] == 912.5
    assert source["null_unit"] == 1
    assert source["null_if_index"] == 1
    assert :ok = ShadowParity.compare(source, destination)
  end

  test "log and event shadow destinations match invented ground truth" do
    logs = [
      %{
        id: "log-alpha-0001",
        timestamp: @interval_start,
        ingest_identity: "seq:1:0",
        severity_text: "info",
        severity_number: 9,
        body: "synthetic info line",
        service_name: "flow-collector"
      },
      %{
        id: "log-alpha-0002",
        timestamp: @interval_end,
        ingest_identity: "seq:1:1",
        severity_text: nil,
        severity_number: nil,
        body: nil,
        service_name: nil
      }
    ]

    events = [
      %{
        id: "evt-alpha-0001",
        time: @interval_start,
        class_uid: 1008,
        severity_id: 1,
        severity: "informational",
        source: "trapd"
      },
      %{
        id: "evt-alpha-0002",
        time: @interval_end,
        class_uid: 1008,
        severity_id: nil,
        severity: nil,
        source: nil
      }
    ]

    assert :ok =
             ShadowParity.compare(
               ShadowParity.summarize(:logs, logs),
               shadow_summary(:logs, logs)
             )

    assert :ok =
             ShadowParity.compare(
               ShadowParity.summarize(:events, events),
               shadow_summary(:events, events)
             )

    log_summary = ShadowParity.summarize(:logs, logs)
    assert log_summary["null_body"] == 1
    assert log_summary["severity_number_total"] == 9
  end

  test "overlap dedup keeps a stable identity and newest-first watermark" do
    already = MapSet.new(["flow-alpha-0001"])
    {kept, skipped} = Backfill.dedup_overlap(@flow_truth, already, :flows)
    assert skipped == 1
    assert Enum.map(kept, & &1.id) == ["flow-alpha-0002"]

    {batch, rest} = Backfill.bounded_batch(@flow_truth, 1)
    assert length(batch) == 1
    assert length(rest) == 1

    checkpoint = Backfill.next_checkpoint(%{"dataset" => "flows"}, @interval_end)
    assert checkpoint["direction"] == "newest_first"
    assert checkpoint["watermark"] == DateTime.to_iso8601(@interval_end)
  end

  defp shadow_summary(dataset, rows) do
    persist = fn _table, loaded, _opts ->
      send(self(), {:shadow_rows, loaded})
      {:ok, %{loaded: length(loaded)}}
    end

    assert {:ok, %{missing: []}} =
             Destination.persist_shadow(dataset, rows, completed: [:cnpg], persist: persist)

    assert_received {:shadow_rows, loaded}
    assert length(loaded) == length(rows)
    ShadowParity.summarize(dataset, loaded)
  end
end
