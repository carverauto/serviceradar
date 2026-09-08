defmodule ServiceRadar.Inventory.Remediation.LinkLocalAliasArchiveTest do
  @moduledoc """
  Existing link-local identity aliases must be archived, not marked stale.

  `:stale` is revivable: MapperResultsIngestor.maybe_reactivate_alias/2 and
  confirm_from_sweep both promote it back to :confirmed. Alias debris in this
  system self-revives (GitHub #3971/#3976/#3979). GitHub #4022.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Inventory.Remediation.DireRemediation
  alias ServiceRadar.Inventory.Remediation.LinkLocalAliasArchive
  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: ServiceRadar.Actors.SystemActor.system(:link_local_alias_archive_test)}
  end

  test "dry_run reports live and stale link-local rows and changes nothing", %{actor: actor} do
    seeded = seed_pathology()

    report = LinkLocalAliasArchive.run(:dry_run, [], nil, actor)

    assert report.would_archive >= length(seeded.archive_ids)
    refute Map.has_key?(report, :archived_alias_states)

    assert alias_state(seeded.device_id, seeded.link_local) == "confirmed"
    assert alias_state(seeded.device_id, seeded.stale_link_local) == "stale"
    assert alias_state(seeded.device_id, seeded.interface_ip) == "confirmed"
    assert alias_state(seeded.device_id, seeded.routable) == "confirmed"
    assert metadata_has_ip_alias?(seeded.device_id, seeded.link_local)
  end

  test "execute archives link-local :ip and :interface_ip without marking stale", %{
    actor: actor
  } do
    seeded = seed_pathology()
    manifest = Manifest.open(seeded.manifest_path, %{test: "link_local_alias_archive"})
    report = LinkLocalAliasArchive.run(:execute, [], manifest, actor)
    Manifest.close(manifest)

    assert report.archived_alias_states >= length(seeded.archive_ids)

    Enum.each(seeded.archive_ids, fn id ->
      refute candidate?(id)
    end)

    assert alias_state(seeded.device_id, seeded.link_local) == "archived"
    assert alias_state(seeded.device_id, seeded.stale_link_local) == "archived"
    assert alias_state(seeded.device_id, seeded.interface_ip) == "archived"
    refute alias_state(seeded.device_id, seeded.link_local) == "stale"
    assert alias_state(seeded.device_id, seeded.routable) == "confirmed"
    refute metadata_has_ip_alias?(seeded.device_id, seeded.link_local)
    assert metadata_has_ip_alias?(seeded.device_id, seeded.routable)

    body = File.read!(seeded.manifest_path)
    assert body =~ "link-local-alias-archive"
    assert body =~ "archive_alias_states"
    assert body =~ "strip_ip_alias_metadata"
  end

  test "re-running after execute is a no-op for the seeded rows", %{actor: actor} do
    seeded = seed_pathology()

    manifest = Manifest.open(seeded.manifest_path, %{test: "link_local_alias_archive_idempotent"})
    first = LinkLocalAliasArchive.run(:execute, [], manifest, actor)
    Manifest.close(manifest)

    assert first.archived_alias_states >= length(seeded.archive_ids)

    Enum.each(seeded.archive_ids, fn id ->
      refute candidate?(id)
    end)

    second = LinkLocalAliasArchive.run(:dry_run, [], nil, actor)
    assert second.would_archive >= 0

    Enum.each(seeded.archive_ids, fn id ->
      refute candidate?(id)
    end)
  end

  test "the step is in the default DIRE run order" do
    assert "link-local-alias-archive" in DireRemediation.steps()
  end

  defp seed_pathology do
    suffix = System.unique_integer([:positive])
    device_id = "sr:test-ll-alias-#{suffix}"
    hex = Integer.to_string(rem(suffix, 0xFFFF), 16)
    link_local = "fe80::1:#{hex}"
    stale_link_local = "fe80::2:#{hex}"
    interface_ip = "fe80::3:#{hex}"
    routable = "100.81.#{rem(suffix, 200) + 1}.#{rem(div(suffix, 200), 200) + 1}"

    insert_device(device_id, routable, link_local)

    link_local_id = insert_alias_state(device_id, link_local, "confirmed", "ip")
    stale_id = insert_alias_state(device_id, stale_link_local, "stale", "ip")
    interface_ip_id = insert_alias_state(device_id, interface_ip, "confirmed", "interface_ip")
    _routable_id = insert_alias_state(device_id, routable, "confirmed", "ip")

    %{
      device_id: device_id,
      link_local: link_local,
      stale_link_local: stale_link_local,
      interface_ip: interface_ip,
      routable: routable,
      archive_ids: [link_local_id, stale_id, interface_ip_id],
      manifest_path:
        Path.join(
          System.tmp_dir!(),
          "link-local-alias-archive-#{suffix}-#{:erlang.unique_integer([:positive])}.ndjson"
        )
    }
  end

  defp insert_device(uid, ip, link_local) do
    Repo.query!(
      """
      INSERT INTO platform.ocsf_devices
        (uid, ip, metadata, discovery_sources, first_seen_time, last_seen_time, modified_time)
      VALUES ($1, $2, $3, ARRAY['sweep'], timezone('utc', now()), timezone('utc', now()), timezone('utc', now()))
      ON CONFLICT (uid) DO NOTHING
      """,
      [
        uid,
        ip,
        %{
          "ip_alias:#{link_local}" => "2026-08-25T00:00:00Z",
          "ip_alias:#{ip}" => "2026-08-25T00:00:00Z"
        }
      ]
    )
  end

  defp insert_alias_state(device_id, value, state, alias_type) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO platform.device_alias_states
          (id, device_id, partition, alias_type, alias_value, state, first_seen_at, last_seen_at,
           sighting_count, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, 'default', $4, $2, $3, timezone('utc', now()),
                timezone('utc', now()), 1, timezone('utc', now()), timezone('utc', now()))
        RETURNING id::text
        """,
        [device_id, value, state, alias_type]
      )

    id
  end

  defp alias_state(device_id, value) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT state FROM platform.device_alias_states
        WHERE device_id = $1 AND alias_value = $2
        """,
        [device_id, value]
      )

    case rows do
      [[state]] -> state
      [] -> nil
    end
  end

  defp candidate?(id) do
    %{rows: [[exists]]} =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1
          FROM platform.device_alias_states
          WHERE id::text = $1
            AND alias_type IN ('ip', 'interface_ip')
            AND state <> 'archived'
            AND platform.sr_address_rank(alias_value) = 20
        )
        """,
        [id]
      )

    exists
  end

  defp metadata_has_ip_alias?(device_id, ip) do
    %{rows: [[exists]]} =
      Repo.query!(
        """
        SELECT COALESCE(metadata ? $2, false)
        FROM platform.ocsf_devices
        WHERE uid = $1
        """,
        [device_id, "ip_alias:" <> ip]
      )

    exists
  end
end
