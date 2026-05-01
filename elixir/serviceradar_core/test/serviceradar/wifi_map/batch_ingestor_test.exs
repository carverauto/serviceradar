defmodule ServiceRadar.WifiMap.BatchIngestorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.WifiMap.BatchIngestor

  @source_id "11111111-1111-4111-8111-111111111111"
  @batch_id "22222222-2222-4222-8222-222222222222"

  test "ignores non WiFi-map plugin payloads" do
    parent = self()

    assert :ok =
             BatchIngestor.ingest(%{"status" => "OK", "metrics" => []}, %{},
               source_upsert: fn attrs, _context ->
                 send(parent, {:unexpected_source_upsert, attrs})
                 {:ok, @source_id}
               end,
               batch_upsert: fn attrs, _context ->
                 send(parent, {:unexpected_batch_upsert, attrs})
                 {:ok, @batch_id}
               end,
               bulk_upsert: fn rows, table, conflict_target, replace_fields, _context ->
                 send(
                   parent,
                   {:unexpected_bulk_upsert, rows, table, conflict_target, replace_fields}
                 )

                 :ok
               end,
               device_sync: fn updates, _context ->
                 send(parent, {:unexpected_device_sync, updates})
                 :ok
               end
             )

    refute_received {:unexpected_source_upsert, _}
    refute_received {:unexpected_batch_upsert, _}
    refute_received {:unexpected_bulk_upsert, _, _, _, _}
    refute_received {:unexpected_device_sync, _}
  end

  test "normalizes WiFi-map batch payload into table upserts" do
    parent = self()

    source_upsert = fn attrs, _context ->
      send(parent, {:source_upsert, attrs})
      {:ok, @source_id}
    end

    batch_upsert = fn attrs, _context ->
      send(parent, {:batch_upsert, attrs})
      {:ok, @batch_id}
    end

    bulk_upsert = fn rows, table, conflict_target, replace_fields, _context ->
      if rows != [] do
        send(parent, {:bulk_upsert, table, rows, conflict_target, replace_fields})
      end

      :ok
    end

    device_sync = fn updates, _context ->
      send(parent, {:device_sync, updates})
      :ok
    end

    payload = %{
      "schema" => "serviceradar.wifi_map.batch.v1",
      "collection_mode" => "csv_seed",
      "collection_timestamp" => "2026-04-30T12:34:56Z",
      "reference_hash" => "ref-sha",
      "source" => %{"name" => "customer-wifi-map", "source_kind" => "wifi_map_seed"},
      "site_references" => [
        %{
          "iata" => "iah",
          "name" => "George Bush Intercontinental Airport",
          "lat" => "29.9844",
          "lon" => "-95.3414",
          "site_type" => "airport",
          "region" => "AM-Central"
        }
      ],
      "sites" => [
        %{
          "iata" => "iah",
          "name" => "George Bush Intercontinental Airport",
          "lat" => "29.9844",
          "lon" => "-95.3414",
          "site_type" => "airport",
          "region" => "AM-Central",
          "ap_count" => "1411",
          "up_count" => "1251",
          "down_count" => "160",
          "models" => "635:439,325:282",
          "controllers" => "aruba-mm-central.ual.com",
          "wlc_count" => "7",
          "wlcs" => "7220:3,7030:2,9240:2",
          "aos_versions" => "8.10.0.21:7",
          "server_group" => "ual-aaa-tulng-group-6_11",
          "cluster" => "TUL",
          "all_server_groups" => "ual-aaa-iahap-group_6_11;ual-aaa-tulng-group-6_11",
          "aaa_profile" => "016airport-aaa-standard"
        }
      ],
      "search_index" => [
        %{
          "kind" => "ap",
          "iata" => "iah",
          "name" => "NIAHAP-MDF001-WAP001",
          "mac" => "B4:5D:50:C7:46:6C",
          "serial" => "CNC3HN77NW",
          "ip" => "10.12.3.249",
          "status" => "Up",
          "model" => "325"
        },
        %{
          "kind" => "wlc",
          "iata" => "iah",
          "name" => "NIAHAP-MDF001-WLC001",
          "base_mac" => "28:de:65:70:43:7e",
          "ip" => "10.12.3.10",
          "version" => "8.10.0.21",
          "model" => "7220"
        }
      ],
      "radius_groups" => [
        %{
          "airport_code" => "iah",
          "controller_alias" => "NIAHAP-MDF001-WLC001",
          "aaa_profile" => "016airport-aaa-standard",
          "dot1x_server_group" => "ual-aaa-tulng-group-6_11",
          "server_group_location" => "TUL",
          "status" => "OK"
        }
      ],
      "fleet_history" => [
        %{
          "build_date" => "2026-04-30",
          "ap_total" => "9966",
          "count_6xx" => "3938",
          "pct_6xx" => "39.51",
          "site_count" => "241"
        }
      ]
    }

    assert :ok =
             BatchIngestor.ingest(payload, %{service_name: "wifi-map-plugin"},
               source_upsert: source_upsert,
               batch_upsert: batch_upsert,
               bulk_upsert: bulk_upsert,
               device_sync: device_sync
             )

    assert_receive {:source_upsert, source_attrs}
    assert source_attrs.name == "customer-wifi-map"
    assert source_attrs.source_kind == "wifi_map_seed"
    assert source_attrs.latest_reference_hash == "ref-sha"

    assert_receive {:batch_upsert, batch_attrs}
    assert batch_attrs.source_id == @source_id
    assert batch_attrs.collection_mode == "csv_seed"
    assert batch_attrs.reference_hash == "ref-sha"
    assert batch_attrs.row_counts["sites"] == 1
    assert batch_attrs.row_counts["access_points"] == 1
    assert batch_attrs.row_counts["controllers"] == 1

    assert_receive {:bulk_upsert, :wifi_site_references, [reference], [:source_id, :site_code], _}
    assert reference.source_id == @source_id
    assert reference.site_code == "IAH"
    assert reference.latitude == 29.9844
    assert reference.longitude == -95.3414

    assert_receive {:bulk_upsert, :wifi_sites, [site], [:source_id, :site_code], _}
    assert site.site_code == "IAH"
    assert site.region == "AM-Central"

    assert_receive {:bulk_upsert, :wifi_site_snapshots, [snapshot],
                    [:source_id, :site_code, :collection_timestamp], _}

    assert snapshot.ap_count == 1411
    assert snapshot.down_count == 160
    assert snapshot.model_breakdown == %{"325" => 282, "635" => 439}
    assert snapshot.controller_names == ["aruba-mm-central.ual.com"]
    assert snapshot.all_server_groups == ["ual-aaa-iahap-group_6_11", "ual-aaa-tulng-group-6_11"]

    assert_receive {:bulk_upsert, :wifi_access_point_observations, [ap],
                    [:source_id, :collection_timestamp, :name], _}

    assert ap.site_code == "IAH"
    assert ap.mac == "b4:5d:50:c7:46:6c"
    assert String.starts_with?(ap.device_uid, "sr:")

    assert_receive {:bulk_upsert, :wifi_controller_observations, [controller],
                    [:source_id, :collection_timestamp, :name], _}

    assert controller.site_code == "IAH"
    assert String.starts_with?(controller.device_uid, "sr:")
    assert controller.base_mac == "28:de:65:70:43:7e"
    assert controller.aos_version == "8.10.0.21"

    assert_receive {:bulk_upsert, :wifi_radius_group_observations, [radius],
                    [
                      :source_id,
                      :site_code,
                      :controller_alias,
                      :aaa_profile,
                      :collection_timestamp
                    ], _}

    assert radius.server_group == "ual-aaa-tulng-group-6_11"
    assert radius.cluster == "TUL"

    assert_receive {:bulk_upsert, :wifi_fleet_history, [history], [:source_id, :build_date], _}
    assert history.build_date == ~D[2026-04-30]
    assert history.ap_total == 9966
    assert history.count_6xx == 3938
    assert history.pct_6xx == 39.51

    assert_receive {:device_sync, device_updates}
    assert length(device_updates) == 2

    ap_update =
      Enum.find(device_updates, &(&1["metadata"]["wifi_map_asset_kind"] == "access_point"))

    assert ap_update["source"] == "wifi_map"
    assert ap_update["metadata"]["integration_type"] == "wifi_map"
    assert ap_update["metadata"]["device_type"] == "access_point"
    assert ap_update["metadata"]["device_role"] == "ap_bridge"
    assert ap_update["metadata"]["site_code"] == "IAH"
    assert ap_update["metadata"]["serial_number"] == "CNC3HN77NW"
    assert String.starts_with?(ap_update["device_id"], "sr:")

    controller_update =
      Enum.find(device_updates, &(&1["metadata"]["wifi_map_asset_kind"] == "controller"))

    assert controller_update["metadata"]["device_type"] == "switch"
    assert controller_update["metadata"]["device_role"] == "switch_l2"
    assert controller_update["metadata"]["aos_version"] == "8.10.0.21"
    assert String.starts_with?(controller_update["device_id"], "sr:")
  end

  test "accepts raw collector CSV aliases for WLC and RADIUS rows" do
    parent = self()

    payload = %{
      "schema" => "serviceradar.wifi_map.batch.v1",
      "collection_timestamp" => "2026-04-30T12:34:56Z",
      "source" => %{"name" => "customer-wifi-map"},
      "sites" => [
        %{
          "iata" => "IAH",
          "name" => "George Bush Intercontinental Airport",
          "lat" => "29.9844",
          "lon" => "-95.3414"
        }
      ],
      "controllers" => [
        %{
          "location" => "NIAHAP",
          "expected_name" => "NIAHAP-MDF001-WLC001",
          "hostname" => "NIAHAP-MDF001-WLC001",
          "ip_address" => "10.12.3.10",
          "mac_address" => "28:de:65:70:43:7e",
          "hw_base_mac" => "28:de:65:70:43:7e",
          "chassis_serial" => "CW0002888",
          "model" => "7220",
          "version" => "8.10.0.21"
        }
      ],
      "radius_groups" => [
        %{
          "airport_code" => "IAH",
          "device_alias" => "NIAHAP-MDF001-WLC001",
          "aaa_profile" => "016airport-aaa-standard",
          "dot1x_server_group" => "ual-aaa-tulng-group-6_11",
          "server_group_location" => "TUL",
          "status" => "OK"
        }
      ]
    }

    assert :ok =
             BatchIngestor.ingest(payload, %{service_name: "wifi-map-plugin"},
               source_upsert: fn _attrs, _context -> {:ok, @source_id} end,
               batch_upsert: fn _attrs, _context -> {:ok, @batch_id} end,
               bulk_upsert: fn rows, table, _conflict_target, _replace_fields, _context ->
                 if rows != [] do
                   send(parent, {:bulk_upsert, table, rows})
                 end

                 :ok
               end,
               device_sync: fn updates, _context ->
                 send(parent, {:device_sync, updates})
                 :ok
               end
             )

    assert_receive {:bulk_upsert, :wifi_controller_observations, [controller]}
    assert controller.name == "NIAHAP-MDF001-WLC001"
    assert controller.site_code == "IAH"
    assert controller.mac == "28:de:65:70:43:7e"
    assert controller.base_mac == "28:de:65:70:43:7e"
    assert controller.serial == "CW0002888"
    assert controller.aos_version == "8.10.0.21"

    assert_receive {:bulk_upsert, :wifi_radius_group_observations, [radius]}
    assert radius.site_code == "IAH"
    assert radius.controller_alias == "NIAHAP-MDF001-WLC001"
    assert radius.server_group == "ual-aaa-tulng-group-6_11"
    assert radius.cluster == "TUL"

    assert_receive {:device_sync, [device_update]}
    assert device_update["metadata"]["serial_number"] == "CW0002888"
    assert device_update["mac"] == "28:de:65:70:43:7e"
  end

  test "derives site-level RADIUS rows from site seed data when raw rows are absent" do
    parent = self()

    payload = %{
      "schema" => "serviceradar.wifi_map.batch.v1",
      "collection_timestamp" => "2026-04-30T12:34:56Z",
      "source" => %{"name" => "customer-wifi-map"},
      "sites" => [
        %{
          "iata" => "IAH",
          "name" => "George Bush Intercontinental Airport",
          "lat" => "29.9844",
          "lon" => "-95.3414",
          "server_group" => "ual-aaa-tulng-group-6_11",
          "cluster" => "TUL",
          "all_server_groups" => "ual-aaa-iahap-group_6_11;ual-aaa-tulng-group-6_11",
          "aaa_profile" => "016airport-aaa-standard"
        }
      ]
    }

    assert :ok =
             BatchIngestor.ingest(payload, %{service_name: "wifi-map-plugin"},
               source_upsert: fn _attrs, _context -> {:ok, @source_id} end,
               batch_upsert: fn _attrs, _context -> {:ok, @batch_id} end,
               bulk_upsert: fn rows, table, _conflict_target, _replace_fields, _context ->
                 if table == :wifi_radius_group_observations do
                   send(parent, {:radius_rows, rows})
                 end

                 :ok
               end,
               device_sync: fn _updates, _context -> :ok end
             )

    assert_receive {:radius_rows, [radius]}
    assert radius.site_code == "IAH"
    assert radius.controller_alias == "site:IAH"
    assert radius.aaa_profile == "016airport-aaa-standard"
    assert radius.server_group == "ual-aaa-tulng-group-6_11"
    assert radius.cluster == "TUL"
    assert radius.all_server_groups == ["ual-aaa-iahap-group_6_11", "ual-aaa-tulng-group-6_11"]
    assert radius.metadata == %{"scope" => "site_summary"}
  end
end
