defmodule ServiceRadar.Analytics.StarRocks.ExposureCatalogTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "catalog flattens dimensions and excludes deleted and tombstoned devices" do
    live = device!("live")
    deleted = device!("deleted")
    tombstoned = device!("tombstoned")

    Repo.query!("UPDATE platform.ocsf_devices SET deleted_at = now() WHERE uid = $1", [deleted])

    Repo.query!("UPDATE platform.device_fleet_ordinals SET tombstoned = true WHERE uid = $1", [
      tombstoned
    ])

    for _ <- 1..2 do
      Repo.query!("INSERT INTO platform.ocsf_agents(uid, device_uid) VALUES ($1, $2)", [
        "exposure-agent-#{System.unique_integer([:positive])}",
        live
      ])
    end

    assert %{
             rows: [
               [
                 ordinal,
                 ^live,
                 "host01.example.com",
                 "Server",
                 "Example Vendor",
                 "default",
                 "example-vlan",
                 "Example Team",
                 "example-site",
                 true,
                 true
               ]
             ]
           } =
             Repo.query!(
               "SELECT * FROM platform.exposure_device_catalog WHERE device_uid = ANY($1)",
               [[live, deleted, tombstoned]]
             )

    assert %{rows: [[^ordinal, "site", "example-site"], [^ordinal, "tier", "3"]]} =
             Repo.query!(
               "SELECT * FROM platform.exposure_device_tags_catalog WHERE device_ord IN " <>
                 "(SELECT ordinal FROM platform.device_fleet_ordinals WHERE uid = ANY($1)) " <>
                 "ORDER BY tag_key",
               [[live, deleted, tombstoned]]
             )
  end

  test "an inventory agent hint is not agent management and empty tags produce no rows" do
    uid = device!("unmanaged")

    Repo.query!(
      "UPDATE platform.ocsf_devices SET agent_id = 'example-agent-hint', owner = '{}', tags = '{}' WHERE uid = $1",
      [uid]
    )

    assert %{rows: [[ordinal, false, nil, nil]]} =
             Repo.query!(
               "SELECT device_ord, agent_managed, owner_name, tag_site FROM platform.exposure_device_catalog WHERE device_uid = $1",
               [uid]
             )

    assert %{rows: []} =
             Repo.query!(
               "SELECT * FROM platform.exposure_device_tags_catalog WHERE device_ord = $1",
               [ordinal]
             )
  end

  defp device!(suffix) do
    uid = "sr:exposure-#{suffix}-#{System.unique_integer([:positive])}"

    Repo.query!(
      """
      INSERT INTO platform.ocsf_devices
        (uid, hostname, type, vendor_name, vlan_uid, owner, tags, is_available)
      VALUES ($1, 'host01.example.com', 'Server', 'Example Vendor', 'example-vlan',
        '{"name":"Example Team"}', '{"site":"example-site","tier":3}', true)
      """,
      [uid]
    )

    uid
  end
end
