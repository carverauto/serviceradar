defmodule ServiceRadar.Inventory.DeviceDiscoveryIngestorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.DeviceDiscoveryIngestor

  test "translates plugin device discovery envelopes into inventory updates" do
    parent = self()

    payload = %{
      "status" => "OK",
      "summary" => "discovered wireless inventory",
      "device_discovery" => [
        %{
          "schema" => "serviceradar.device_discovery.v1",
          "source" => "ual-network-map",
          "collection_id" => "csv-seed-2026-05-01",
          "reference_hash" => "ref-sha",
          "devices" => [
            %{
              "hostname" => "NIAHAP-MDF001-WAP001",
              "ip" => "10.12.3.249",
              "mac" => "b4:5d:50:c7:46:6c",
              "serial" => "CNC3HN77NW",
              "vendor_name" => "Aruba",
              "model" => "325",
              "type" => "access_point",
              "role" => "ap_bridge",
              "status" => "Up",
              "is_available" => true,
              "location" => %{
                "site_code" => "IAH",
                "site_name" => "George Bush Intercontinental Airport",
                "latitude" => 29.9844,
                "longitude" => -95.3414
              }
            }
          ]
        }
      ]
    }

    assert :ok =
             DeviceDiscoveryIngestor.ingest(payload, %{partition: "local"},
               actor: :actor,
               device_sync: fn updates, context ->
                 send(parent, {:device_sync, updates, context})
                 :ok
               end
             )

    assert_receive {:device_sync, [update], %{actor: :actor}}
    assert update["source"] == "ual-network-map"
    assert update["partition"] == "local"
    assert update["hostname"] == "NIAHAP-MDF001-WAP001"
    assert update["metadata"]["integration_type"] == "plugin_device_discovery"
    assert update["metadata"]["integration_id"] == "ual-network-map:access_point:CNC3HN77NW"
    assert update["metadata"]["device_type"] == "access_point"
    assert update["metadata"]["device_role"] == "ap_bridge"
    assert update["metadata"]["site_code"] == "IAH"
    assert update["metadata"]["latitude"] == 29.9844
  end

  test "ignores plugin results without device discovery envelopes" do
    parent = self()

    assert :ok =
             DeviceDiscoveryIngestor.ingest(%{"status" => "OK"}, %{},
               actor: :actor,
               device_sync: fn updates, context ->
                 send(parent, {:unexpected_device_sync, updates, context})
                 :ok
               end
             )

    refute_received {:unexpected_device_sync, _, _}
  end

  test "advertises support only for device discovery payloads" do
    discovery = %{
      "device_discovery" => [
        %{"schema" => "serviceradar.device_discovery.v1", "devices" => []}
      ]
    }

    assert DeviceDiscoveryIngestor.supports?(discovery, %{})
    assert DeviceDiscoveryIngestor.supports?([%{"summary" => "ignored"}, discovery], %{})
    refute DeviceDiscoveryIngestor.supports?(%{"events" => [%{"kind" => "camera"}]}, %{})
    refute DeviceDiscoveryIngestor.supports?("not a payload", %{})
  end
end
