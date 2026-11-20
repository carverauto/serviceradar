defmodule ServiceRadar.EventWriter.Processors.RumBeaconsDBTest do
  @moduledoc """
  When StarRocks is disabled, RumBeacons inserts into platform.rum_beacons
  with idempotent conflict handling on (web_property_id, beacon_id, observed_at).
  """
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.EventWriter.Processors.RumBeacons
  alias ServiceRadar.Repo
  alias Serviceradar.Rum.V1.RumBeaconV1

  @moduletag :integration

  @prop_id "01JWEBPROP0000000000000099"

  test "redelivered RUM beacons are stored once in CNPG when StarRocks is disabled" do
    b1 = %RumBeaconV1{
      beacon_id: "01JRUMBEACON00000000000091",
      observed_at_unix_ms: 1_760_000_000_000,
      web_property_id: @prop_id,
      url: "https://shop.example/home",
      metric_path: "/home",
      lcp_ms: 950.0,
      inp_ms: 0.0,
      client_ip: "198.51.100.0/24",
      client_ip_anonymized: true,
      prefix_tag: "lab-corp"
    }

    b2 = %{b1 | beacon_id: "01JRUMBEACON00000000000092", path: "/pricing"}

    assert {:ok, 1} =
             RumBeacons.process_batch([%{data: RumBeaconV1.encode(b1), metadata: %{}}],
               starrocks_enabled: false
             )

    assert {:ok, 1} =
             RumBeacons.process_batch(
               [
                 %{data: RumBeaconV1.encode(b1), metadata: %{}},
                 %{data: RumBeaconV1.encode(b2), metadata: %{}}
               ],
               starrocks_enabled: false
             )

    %{rows: rows} =
      Repo.query!(
        """
        SELECT beacon_id, lcp_ms, inp_ms, cls, prefix_tag, client_ip
        FROM platform.rum_beacons
        WHERE web_property_id = $1
        ORDER BY beacon_id
        """,
        [@prop_id]
      )

    assert [
             ["01JRUMBEACON00000000000091", 950.0, +0.0, nil, "lab-corp", "198.51.100.0/24"],
             ["01JRUMBEACON00000000000092", 950.0, +0.0, nil, "lab-corp", "198.51.100.0/24"]
           ] = rows
  end
end
