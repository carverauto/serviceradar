defmodule ServiceRadarWebNGWeb.DashboardLive.NetflowMapGeoTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadarWebNGWeb.DashboardLive.Data
  alias ServiceRadarWebNGWeb.DashboardLive.Window

  @moduletag :web_ng_shared_fixture_db

  defmodule MapSliceStub do
    @moduledoc false

    def query(query, %{scope: scope}) do
      with :ok <- ServiceRadarWebNG.SRQL.EntityAccess.authorize(query, scope) do
        rows =
          if String.contains?(query, " by src_endpoint_ip,dst_endpoint_ip") do
            [
              %{
                "src_endpoint_ip" => "192.0.2.10",
                "dst_endpoint_ip" => "198.51.100.20",
                "bytes_total" => 1200,
                "packets_total" => 15,
                "flow_count" => 7
              }
            ]
          else
            [%{"bytes_total" => 1200, "packets_total" => 15, "flow_count" => 7}]
          end

        {:ok, %{"results" => rows}}
      end
    end
  end

  setup do
    prev_starrocks = Application.get_env(:serviceradar_core, StarRocks, [])
    prev_srql = Application.get_env(:serviceradar_web_ng, :srql_module)

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev_starrocks, :cutover_datasets, [:flows])
    )

    Application.put_env(:serviceradar_web_ng, :srql_module, MapSliceStub)

    on_exit(fn ->
      Application.put_env(:serviceradar_core, StarRocks, prev_starrocks)

      if is_nil(prev_srql) do
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      else
        Application.put_env(:serviceradar_web_ng, :srql_module, prev_srql)
      end
    end)

    :ok
  end

  defp seed_geo!(ip, latitude, longitude, city, country) do
    now = DateTime.utc_now()

    ServiceRadarWebNG.Repo.query!(
      """
      INSERT INTO platform.ip_geo_enrichment_cache
        (ip, city, country_iso2, latitude, longitude, is_private, looked_up_at, expires_at,
         error_count, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, false, $6, $7, 0, $6, $6)
      ON CONFLICT (ip) DO UPDATE
        SET city = EXCLUDED.city,
            country_iso2 = EXCLUDED.country_iso2,
            latitude = EXCLUDED.latitude,
            longitude = EXCLUDED.longitude
      """,
      [ip, city, country, latitude, longitude, now, DateTime.add(now, 3600, :second)]
    )
  end

  test "flows served from the warehouse draw geographic arcs from CNPG enrichment" do
    seed_geo!("192.0.2.10", 47.6062, -122.3321, "Example City", "US")
    seed_geo!("198.51.100.20", 35.6762, 139.6503, "Sample City", "JP")

    scope = %{permissions: MapSet.new(["observability.netflow.view"])}
    window = Window.resolve("last_1h", "netflow")

    slice = Data.load_netflow_map(scope, window: window)

    assert [link] = slice.traffic_links

    # The map hook drops every netflow link that lacks either endpoint, so these
    # two points are what makes an arc render at all.
    assert link.geo_from == [-122.3321, 47.6062]
    assert link.geo_to == [139.6503, 35.6762]
    assert link.geo_mapped == true
    assert link.source_geo_label == "Example City, US, 192.0.2.10"
    assert link.target_geo_label == "Sample City, JP, 198.51.100.20"
    assert link.source_label == "192.0.2.10"
    assert link.target_label == "198.51.100.20"
    assert link.bytes == 1200
    assert link.flow_count == 7

    refute slice.map_empty_title == "Flows are not mapped yet"
  end
end
