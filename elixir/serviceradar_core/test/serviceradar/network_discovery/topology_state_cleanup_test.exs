defmodule ServiceRadar.NetworkDiscovery.TopologyStateCleanupTest do
  use ServiceRadar.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias ServiceRadar.NetworkDiscovery.TopologyStateCleanup
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "canonicalization keeps newer existing evidence when a stale uid collides" do
    suffix = unique_suffix()
    local_uid = "sr:cleanup-local-#{suffix}"
    stale_uid = "sr:cleanup-stale-#{suffix}"
    canonical_uid = "sr:cleanup-canonical-#{suffix}"
    ip = "192.0.2.10"

    insert_device(stale_uid, ip, deleted?: true)
    insert_device(canonical_uid, ip)

    stale_id =
      insert_link(
        local_uid,
        stale_uid,
        ~N[2026-07-01 01:00:00],
        %{"winner" => "stale"}
      )

    canonical_id =
      insert_link(
        local_uid,
        canonical_uid,
        ~N[2026-07-02 01:00:00],
        %{"winner" => "canonical"}
      )

    assert {:ok, stats} = TopologyStateCleanup.canonicalize_deleted_device_links()
    assert stats.neighbor_device_id_updates == 1

    assert [row] = links_for(local_uid)
    assert row.id == canonical_id
    assert row.neighbor_device_id == canonical_uid
    assert row.metadata == %{"winner" => "canonical"}
    refute row.id == stale_id
  end

  test "canonicalization keeps newer stale evidence while replacing its endpoint uid" do
    suffix = unique_suffix()
    local_uid = "sr:cleanup-local-#{suffix}"
    stale_uid = "sr:cleanup-stale-#{suffix}"
    canonical_uid = "sr:cleanup-canonical-#{suffix}"
    ip = "192.0.2.11"

    insert_device(stale_uid, ip, deleted?: true)
    insert_device(canonical_uid, ip)

    canonical_id =
      insert_link(
        local_uid,
        canonical_uid,
        ~N[2026-07-01 01:00:00],
        %{"winner" => "canonical"}
      )

    stale_id =
      insert_link(
        local_uid,
        stale_uid,
        ~N[2026-07-02 01:00:00],
        %{"winner" => "stale"}
      )

    assert {:ok, stats} = TopologyStateCleanup.canonicalize_deleted_device_links()
    assert stats.neighbor_device_id_updates == 2

    assert [row] = links_for(local_uid)
    assert row.id == stale_id
    assert row.neighbor_device_id == canonical_uid
    assert row.metadata == %{"winner" => "stale"}
    refute row.id == canonical_id
  end

  test "a later remap failure rolls back an earlier collision merge" do
    suffix = unique_suffix()
    stale_local_uid = "sr:cleanup-stale-local-#{suffix}"
    canonical_local_uid = "sr:cleanup-canonical-local-#{suffix}"
    stale_neighbor_uid = "sr:cleanup-stale-neighbor-#{suffix}"
    canonical_neighbor_uid = "sr:cleanup-canonical-neighbor-#{suffix}"
    shared_neighbor_uid = "sr:cleanup-shared-neighbor-#{suffix}"
    other_local_uid = "sr:cleanup-other-local-#{suffix}"

    insert_device(stale_local_uid, "192.0.2.12", deleted?: true)
    insert_device(canonical_local_uid, "192.0.2.12")
    insert_device(stale_neighbor_uid, "192.0.2.13", deleted?: true)
    insert_device(canonical_neighbor_uid, "192.0.2.13")

    stale_local_link_id =
      insert_link(
        stale_local_uid,
        shared_neighbor_uid,
        ~N[2026-07-01 01:00:00],
        %{"row" => "stale-local"}
      )

    canonical_local_link_id =
      insert_link(
        canonical_local_uid,
        shared_neighbor_uid,
        ~N[2026-07-02 01:00:00],
        %{"row" => "canonical-local"}
      )

    neighbor_link_id =
      insert_link(
        other_local_uid,
        stale_neighbor_uid,
        ~N[2026-07-03 01:00:00],
        %{"row" => "stale-neighbor"}
      )

    install_rejecting_neighbor_trigger(stale_neighbor_uid, suffix)

    assert {:error, %Postgrex.Error{postgres: %{code: :raise_exception}}} =
             TopologyStateCleanup.canonicalize_deleted_device_links()

    assert Enum.sort(link_ids_for_endpoint(stale_local_uid, shared_neighbor_uid)) ==
             Enum.sort([stale_local_link_id])

    assert Enum.sort(link_ids_for_endpoint(canonical_local_uid, shared_neighbor_uid)) ==
             Enum.sort([canonical_local_link_id])

    assert [row] = links_for(other_local_uid)
    assert row.id == neighbor_link_id
    assert row.neighbor_device_id == stale_neighbor_uid
  end

  defp insert_device(uid, ip, opts \\ []) do
    deleted_at = if Keyword.get(opts, :deleted?, false), do: ~N[2026-06-01 00:00:00]

    SQL.query!(
      Repo,
      "INSERT INTO platform.ocsf_devices (uid, ip, deleted_at) VALUES ($1, $2, $3)",
      [uid, ip, deleted_at]
    )
  end

  defp insert_link(local_uid, neighbor_uid, observed_at, metadata) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO platform.mapper_topology_links (
        id,
        timestamp,
        created_at,
        local_device_id,
        neighbor_device_id,
        local_if_index,
        neighbor_port_id,
        protocol,
        neighbor_chassis_id,
        metadata
      )
      VALUES (($1::text)::uuid, $2, $2, $3, $4, 1, '', 'SNMP-L2', 'aa:bb:cc:dd:ee:ff', $5)
      """,
      [id, observed_at, local_uid, neighbor_uid, metadata]
    )

    id
  end

  defp links_for(local_uid) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT id::text, neighbor_device_id, metadata
        FROM platform.mapper_topology_links
        WHERE local_device_id = $1
        ORDER BY id
        """,
        [local_uid]
      )

    Enum.map(rows, fn [id, neighbor_device_id, metadata] ->
      %{id: id, neighbor_device_id: neighbor_device_id, metadata: metadata}
    end)
  end

  defp link_ids_for_endpoint(local_uid, neighbor_uid) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT id::text
        FROM platform.mapper_topology_links
        WHERE local_device_id = $1
          AND neighbor_device_id = $2
        """,
        [local_uid, neighbor_uid]
      )

    Enum.map(rows, fn [id] -> id end)
  end

  defp install_rejecting_neighbor_trigger(stale_neighbor_uid, suffix) do
    function_name = "reject_topology_cleanup_#{suffix}"
    trigger_name = "reject_topology_cleanup_#{suffix}"

    SQL.query!(
      Repo,
      """
      CREATE FUNCTION pg_temp.#{function_name}()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        RAISE EXCEPTION 'forced topology cleanup failure';
      END
      $$
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TRIGGER #{trigger_name}
      BEFORE UPDATE OF neighbor_device_id ON platform.mapper_topology_links
      FOR EACH ROW
      WHEN (OLD.neighbor_device_id = '#{stale_neighbor_uid}')
      EXECUTE FUNCTION pg_temp.#{function_name}()
      """,
      []
    )
  end

  defp unique_suffix do
    System.unique_integer([:positive, :monotonic])
  end
end
