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
    %{
      device_id: device_id,
      link_local: link_local,
      stale_link_local: stale_link_local,
      routable: routable
    } = seed_pathology()

    report = LinkLocalAliasArchive.run(:dry_run, [], nil, actor)

    assert report.would_archive >= 2
    refute Map.has_key?(report, :archived_alias_states)

    assert alias_state(device_id, link_local) == "confirmed"
    assert alias_state(device_id, stale_link_local) == "stale"
    assert alias_state(device_id, routable) == "confirmed"
  end

  test "execute archives link-local rows from live and stale without marking stale", %{
    actor: actor
  } do
    %{
      device_id: device_id,
      link_local: link_local,
      routable: routable,
      stale_link_local: stale_link_local,
      manifest_path: path
    } = seed_pathology()

    manifest = Manifest.open(path, %{test: "link_local_alias_archive"})
    report = LinkLocalAliasArchive.run(:execute, [], manifest, actor)
    Manifest.close(manifest)

    assert report.archived_alias_states >= 2

    assert alias_state(device_id, link_local) == "archived"
    assert alias_state(device_id, stale_link_local) == "archived"
    refute alias_state(device_id, link_local) == "stale"
    assert alias_state(device_id, routable) == "confirmed"

    body = File.read!(path)
    assert body =~ "link-local-alias-archive"
    assert body =~ "archive_alias_states"
  end

  test "re-running after execute is a no-op", %{actor: actor} do
    %{manifest_path: path} = seed_pathology()

    manifest = Manifest.open(path, %{test: "link_local_alias_archive_idempotent"})
    first = LinkLocalAliasArchive.run(:execute, [], manifest, actor)
    Manifest.close(manifest)

    assert first.archived_alias_states >= 2

    second = LinkLocalAliasArchive.run(:dry_run, [], nil, actor)
    assert second.would_archive == 0
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
    routable = "100.81.#{rem(suffix, 200) + 1}.#{rem(div(suffix, 200), 200) + 1}"

    insert_device(device_id, routable)

    insert_alias_state(device_id, link_local, "confirmed")
    insert_alias_state(device_id, stale_link_local, "stale")
    insert_alias_state(device_id, routable, "confirmed")

    %{
      device_id: device_id,
      link_local: link_local,
      stale_link_local: stale_link_local,
      routable: routable,
      manifest_path:
        Path.join(
          System.tmp_dir!(),
          "link-local-alias-archive-#{suffix}-#{:erlang.unique_integer([:positive])}.ndjson"
        )
    }
  end

  defp insert_device(uid, ip) do
    Repo.query!(
      """
      INSERT INTO platform.ocsf_devices
        (uid, ip, metadata, discovery_sources, first_seen_time, last_seen_time, modified_time)
      VALUES ($1, $2, '{}'::jsonb, ARRAY['sweep'], timezone('utc', now()), timezone('utc', now()), timezone('utc', now()))
      ON CONFLICT (uid) DO NOTHING
      """,
      [uid, ip]
    )
  end

  defp insert_alias_state(device_id, value, state) do
    Repo.query!(
      """
      INSERT INTO platform.device_alias_states
        (id, device_id, partition, alias_type, alias_value, state, first_seen_at, last_seen_at,
         sighting_count, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, 'default', 'ip', $2, $3, timezone('utc', now()),
              timezone('utc', now()), 1, timezone('utc', now()), timezone('utc', now()))
      ON CONFLICT DO NOTHING
      """,
      [device_id, value, state]
    )
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
end
