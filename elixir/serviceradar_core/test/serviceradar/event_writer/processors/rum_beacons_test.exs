defmodule ServiceRadar.EventWriter.Processors.RumBeaconsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.Analytics.StarRocks.Readers
  alias ServiceRadar.Analytics.StarRocks.Rows
  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.Pipeline
  alias ServiceRadar.EventWriter.Processors.RumBeacons
  alias Serviceradar.Rum.V1.RumBeaconV1

  @moduletag :db_free

  test "parse_message decodes RumBeaconV1 protobuf preserving optional 0.0 vs nil metrics" do
    proto = %RumBeaconV1{
      beacon_id: "01JRUMBEACON00000000000001",
      observed_at_unix_ms: 1_760_000_000_123,
      web_property_id: "01JWEBPROP0000000000000001",
      canonical_origin: "https://shop.example",
      environment: "production",
      url: "https://shop.example/checkout?lang=en",
      host: "shop.example",
      path: "/checkout",
      metric_path: "/checkout",
      referrer: "https://ref.example/",
      trace_id: "0123456789abcdef0123456789abcdef",
      span_id: "0123456789abcdef",
      lcp_ms: 1420.5,
      inp_ms: 0.0,
      cls: nil,
      cdn_provider: "akamai",
      cdn_cache_status: "HIT",
      cdn_edge_rtt_ms: 11.5,
      client_ip: "198.51.100.0/24",
      client_ip_anonymized: true,
      country: "US",
      asn: 64_512,
      as_org: "EXAMPLE-NET",
      prefix_tag: "lab-corp",
      attributes: %{"custom" => "value"}
    }

    payload = RumBeaconV1.encode(proto)
    row = RumBeacons.parse_message(%{data: payload, metadata: %{}})

    assert row.beacon_id == "01JRUMBEACON00000000000001"
    assert row.web_property_id == "01JWEBPROP0000000000000001"
    assert row.lcp_ms == 1420.5
    assert row.inp_ms == 0.0
    assert is_nil(row.cls)
    assert row.cdn_edge_rtt_ms == 11.5
    assert is_nil(row.cdn_origin_rtt_ms)
    assert row.prefix_tag == "lab-corp"
    assert row.attributes == %{"custom" => "value"}
  end

  test "rows fit PostgreSQL integer and text columns on protobuf and JSON payloads" do
    int_max = 2_147_483_647

    proto = %RumBeaconV1{
      beacon_id: "01JRUMBEACON\0000000000000009",
      observed_at_unix_ms: 1_760_000_002_000,
      web_property_id: "01JWEBPROP0000000000000001",
      url: "https://shop.example/a\0b",
      session_id: "sess\0ion",
      rage_clicks: 3_000_000_000,
      js_errors: 3_000_000_000,
      http_status: 3_000_000_000,
      asn: 4_200_000_000
    }

    json =
      Jason.encode!(%{
        "beacon_id" => "01JRUMBEACON\0000000000000010",
        "observed_at_unix_ms" => 1_760_000_003_000,
        "web_property_id" => "01JWEBPROP\0000000000000001",
        "user_agent" => "agent\0x",
        "rage_clicks" => 9_000_000_000,
        "js_errors" => 3,
        "http_status" => 200,
        "asn" => 9_000_000_000
      })

    proto_row = RumBeacons.parse_message(%{data: RumBeaconV1.encode(proto), metadata: %{}})
    json_row = RumBeacons.parse_message(%{data: json, metadata: %{}})

    assert proto_row.beacon_id == "01JRUMBEACON000000000000009"
    assert proto_row.url == "https://shop.example/ab"
    assert proto_row.session_id == "session"

    assert {proto_row.rage_clicks, proto_row.js_errors, proto_row.http_status} ==
             {int_max, int_max, int_max}

    assert is_nil(proto_row.asn)

    assert json_row.beacon_id == "01JRUMBEACON000000000000010"
    assert json_row.web_property_id == "01JWEBPROP000000000000001"
    assert json_row.user_agent == "agentx"
    assert {json_row.rage_clicks, json_row.js_errors, json_row.http_status} == {int_max, 3, 200}
    assert is_nil(json_row.asn)

    in_range =
      RumBeacons.parse_message(%{
        data: RumBeaconV1.encode(%{proto | asn: int_max, rage_clicks: 7}),
        metadata: %{}
      })

    assert in_range.asn == int_max
    assert in_range.rage_clicks == 7

    for row <- [proto_row, json_row], {_key, value} <- row, is_binary(value) do
      refute String.contains?(value, <<0>>)
    end
  end

  test "with StarRocks enabled a batch loads :rum_beacons only and never inserts CNPG" do
    parent = self()

    load = fn dataset, rows ->
      send(parent, {:load, dataset, rows})
      {:ok, %{loaded: length(rows)}}
    end

    proto = %RumBeaconV1{
      beacon_id: "01JRUMBEACON00000000000002",
      observed_at_unix_ms: 1_760_000_001_000,
      web_property_id: "01JWEBPROP0000000000000001",
      url: "https://shop.example/"
    }

    assert {:ok, 1} =
             RumBeacons.process_batch([%{data: RumBeaconV1.encode(proto), metadata: %{}}],
               starrocks_enabled: true,
               load: load
             )

    assert_received {:load, :rum_beacons, [row]}
    assert [encoded] = Rows.encode(:rum_beacons, [row])
    assert encoded["web_property_id"] == "01JWEBPROP0000000000000001"
    assert encoded["beacon_id"] == "01JRUMBEACON00000000000002"
  end

  test "undecodable payloads are dropped while warehouse failures bubble up for redelivery" do
    assert {:ok, 0} =
             RumBeacons.process_batch([%{data: "not-proto-or-json", metadata: %{}}],
               starrocks_enabled: true,
               load: fn _, _ -> flunk("must not load empty batch") end
             )

    valid = %{
      data:
        Jason.encode!(%{
          "web_property_id" => "01JWEBPROP0000000000000001",
          "beacon_id" => "01JRUMBEACON00000000000003",
          "observed_at" => "2026-10-01T12:00:00Z",
          "url" => "https://shop.example/"
        }),
      metadata: %{}
    }

    assert {:error, :warehouse_down} =
             RumBeacons.process_batch([valid],
               starrocks_enabled: true,
               load: fn _dataset, _rows -> {:error, :warehouse_down} end
             )
  end

  test "EventWriter config and pipeline register :rum_beacons on the shared events stream" do
    streams = Config.default_streams()
    rum_stream = Enum.find(streams, &(&1.name == "RUM_BEACONS"))
    assert rum_stream.stream_name == "events"
    assert rum_stream.subject == "rum.beacons.>"
    assert rum_stream.processor == RumBeacons

    assert Pipeline.telemetry_subject?("rum.beacons.01JWEBPROP0000000000000001")
    assert :rum_beacons in Pipeline.warehouse_batchers()
    assert Pipeline.processor_for_batcher(:rum_beacons) == RumBeacons
  end

  test "Destination.store routes :rum_beacons based on StarRocks enabled flag alone" do
    assert Destination.table_for(:rum_beacons) == "rum_beacons"
    assert Readers.dataset_for_entity("rum") == :rum
    assert Readers.dataset_for_entity("rum_beacons") == :rum
    assert Readers.dataset_for_entity("rum_beacon") == :rum
  end
end
