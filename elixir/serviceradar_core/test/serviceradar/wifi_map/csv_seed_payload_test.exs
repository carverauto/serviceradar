defmodule ServiceRadar.WifiMap.CSVSeedPayloadTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.WifiMap.CSVSeedPayload

  test "builds a normalized payload from generated POC CSV files" do
    dir = tmp_dir()

    write!(dir, "sites.csv", """
    iata,name,lat,lon,site_type,region,ap_count,up_count,down_count,models,controllers,wlc_count,wlcs,aos_versions,server_group,cluster,all_server_groups,aaa_profile
    ZZA,"Example Regional Airport, Example City",10.0000,-20.0000,airport,REGION-1,2,1,1,"635:1,325:1",wlc-manager-01.example.com,1,7220:1,8.10.0.21:1,aaa-site02-group-1_0,ZZB,aaa-site02-group-1_0,example-aaa-standard
    """)

    write!(dir, "search_index.csv", """
    kind,iata,name,mac,serial,ip,status,model
    ap,ZZA,SITE01-MDF001-WAP001,00:00:5e:00:53:01,SN0000000001,192.0.2.249,Up,325
    wlc,ZZA,SITE01-MDF001-WLC001,00:00:5e:00:53:02,SN0000000002,192.0.2.10,,7220
    """)

    write!(dir, "history.csv", """
    build_date,ap_total,count_2xx,count_3xx,count_4xx,count_5xx,count_6xx,count_7xx,count_other,count_ap325,pct_6xx,pct_legacy,site_count
    2026-04-30,2,0,1,0,0,1,0,0,1,50.0,50.0,1
    """)

    write!(dir, "overrides.csv", """
    iata,name,lat,lon,type
    NDC,Network Data Center,41.1,-88.2,datacenter
    """)

    write!(dir, "meta.json", ~s({"collection_timestamp":"2026-04-30T12:34:56Z"}))

    assert {:ok, payload, summary} =
             CSVSeedPayload.build(dir,
               source_id: "11111111-1111-4111-8111-111111111111",
               source_name: "customer-wifi-map"
             )

    assert payload["schema"] == "serviceradar.wifi_map.batch.v1"
    assert payload["kind"] == "wifi_map"
    assert payload["collection_mode"] == "csv_seed"
    assert payload["collection_timestamp"] == "2026-04-30T12:34:56Z"
    assert payload["source"]["source_id"] == "11111111-1111-4111-8111-111111111111"
    assert payload["source"]["name"] == "customer-wifi-map"
    assert payload["row_counts"]["sites"] == 1
    assert payload["row_counts"]["search_index_access_points"] == 1
    assert payload["row_counts"]["search_index_controllers"] == 1
    assert payload["row_counts"]["fleet_history"] == 1
    assert payload["row_counts"]["overrides"] == 1

    assert [%{"iata" => "ZZA", "name" => "Example Regional Airport, Example City"}] =
             payload["sites"]

    assert summary.reference_hash == payload["reference_hash"]
    assert summary.source_files["sites.csv"]["rows"] == 1
    assert byte_size(summary.source_files["sites.csv"]["sha256"]) == 64
  end

  test "includes raw collector CSVs when they are shipped with the seed package" do
    dir = tmp_dir()

    write!(dir, "sites.csv", """
    iata,name,lat,lon,site_type,region,ap_count,up_count,down_count,models,controllers,wlc_count,wlcs,aos_versions,server_group,cluster,all_server_groups,aaa_profile
    ZZA,Example Regional Airport,10.0000,-20.0000,airport,REGION-1,1,1,0,635:1,wlc-manager-01.example.com,1,7220:1,8.10.0.21:1,aaa-site02-group-1_0,ZZB,aaa-site02-group-1_0,example-aaa-standard
    """)

    write!(dir, "ap-database-current.csv", """
    collection_timestamp,mm,region,location,ap_name,group,ip_address,status,uptime,flags,switch_ip,standby_ip,model,wired_mac,serial
    2026-04-30 12:34:56,wlc-manager-01.example.com,REGION-1,ZZA,SITE01-MDF001-WAP001,default,192.0.2.249,Up,1d,,192.0.2.10,,635,00:00:5e:00:53:01,SN0000000001
    """)

    write!(dir, "switchinfo-current.csv", """
    collection_timestamp,mm,region,location,expected_name,hostname,ip_address,mac_address,model,version,uptime,reboot_cause,chassis_serial,hw_base_mac,mfg_date,psu1_status,psu2_status
    2026-04-30 12:34:56,wlc-manager-01.example.com,REGION-1,SITE01,SITE01-MDF001-WLC001,SITE01-MDF001-WLC001,192.0.2.10,00:00:5e:00:53:02,7220,8.10.0.21,1 year,Power Cycle,SN0000000002,00:00:5e:00:53:02,07/16/16,OK,OK
    """)

    write!(dir, "radius-groups-current.csv", """
    collection_timestamp,mm,region,site,site_path,device_alias,device_mac,device_mac_path,airport_code,aaa_profile,dot1x_server_group,server_group_location,status,available_profiles
    2026-04-30 12:34:56,wlc-manager-01.example.com,REGION-1,SITE01AP,/md/ORG/REGION-1/SITE01AP,SITE01-MDF001-WLC001,00:00:5e:00:53:02,/md/ORG/REGION-1/SITE01AP/00:00:5e:00:53:02,ZZA,example-aaa-standard,aaa-site02-group-1_0,ZZB,OK,
    """)

    assert {:ok, payload, summary} =
             CSVSeedPayload.build(dir, collection_timestamp: "2026-04-30T12:34:56Z")

    assert payload["row_counts"]["access_points"] == 1
    assert payload["row_counts"]["controllers"] == 1
    assert payload["row_counts"]["radius_groups"] == 1
    assert [%{"ap_name" => "SITE01-MDF001-WAP001"}] = payload["access_points"]

    assert [%{"hostname" => "SITE01-MDF001-WLC001", "chassis_serial" => "SN0000000002"}] =
             payload["controllers"]

    assert [%{"device_alias" => "SITE01-MDF001-WLC001"}] = payload["radius_groups"]
    assert summary.source_files["ap-database-current.csv"]["rows"] == 1
  end

  defp tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "serviceradar-wifi-map-seed-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end

  defp write!(dir, name, content) do
    File.write!(Path.join(dir, name), content)
  end
end
