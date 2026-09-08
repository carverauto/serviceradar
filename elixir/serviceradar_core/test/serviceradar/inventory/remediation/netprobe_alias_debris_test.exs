defmodule ServiceRadar.Inventory.Remediation.NetprobeAliasDebrisTest do
  @moduledoc """
  DB-backed coverage for the `netprobe-alias-debris` step.

  The pathology seeded here is the one measured on a live deployment: a collector
  device carrying `ip_alias:` keys and `device_alias_states` rows for addresses
  belonging to hosts it merely fingerprinted, where those hosts each have a device
  of their own.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Inventory.Remediation.NetprobeAliasDebris
  alias ServiceRadar.Repo

  @moduletag :integration

  setup do
    {:ok, actor: ServiceRadar.Actors.SystemActor.system(:netprobe_alias_debris_test)}
  end

  test "dry_run reports the debris and changes nothing", %{actor: actor} do
    %{collector: collector, absorbed: absorbed} = seed_pathology()

    report = NetprobeAliasDebris.run(:dry_run, [], nil, actor)

    assert report.affected_devices >= 1
    assert report.absorbed_addresses >= 2
    assert {^collector, addresses} = Enum.find(report.would_purge, &(elem(&1, 0) == collector))
    assert Enum.sort(addresses) == Enum.sort(absorbed)

    # Nothing moved.
    assert collector |> alias_keys() |> Enum.sort() == Enum.sort(absorbed)
    assert collector |> alias_state_values("stale") |> Enum.sort() == Enum.sort(absorbed)
  end

  test "execute releases the absorbed addresses and archives their alias rows", %{actor: actor} do
    %{collector: collector, absorbed: absorbed, manifest_path: path} = seed_pathology()

    manifest = Manifest.open(path, %{test: "netprobe_alias_debris"})
    report = NetprobeAliasDebris.run(:execute, [], manifest, actor)
    Manifest.close(manifest)

    assert report.purged_metadata_keys >= 2
    assert report.archived_alias_states >= 2

    assert alias_keys(collector) == [], "the collector still claims an address it only observed"

    # Archived, NOT stale: MapperResultsIngestor.find_device_uid_by_alias rejects
    # only :replaced and :archived, and reactivates a :stale row it matches. A
    # cleanup that left them stale would be undone by the next discovery.
    assert alias_state_values(collector, "stale") == []
    assert collector |> alias_state_values("archived") |> Enum.sort() == Enum.sort(absorbed)

    # The hosts themselves are untouched -- this releases an address, it does not
    # delete the device that owns it.
    for ip <- absorbed do
      assert device_count_for_ip(ip) == 1
    end

    manifest_body = File.read!(path)
    assert manifest_body =~ "netprobe-alias-debris"
    assert manifest_body =~ "archive_alias_states"
  end

  test "re-running after an execute is a no-op", %{actor: actor} do
    %{manifest_path: path} = seed_pathology()

    manifest = Manifest.open(path, %{test: "netprobe_alias_debris_idempotent"})
    first = NetprobeAliasDebris.run(:execute, [], manifest, actor)
    Manifest.close(manifest)

    assert first.affected_devices >= 1

    second = NetprobeAliasDebris.run(:dry_run, [], nil, actor)
    assert second.would_purge == []
  end

  test "a router-role collector is skipped and reported", %{actor: actor} do
    %{collector: collector, absorbed: absorbed} = seed_pathology(role: "router")

    report = NetprobeAliasDebris.run(:dry_run, [], nil, actor)

    refute Enum.any?(report.would_purge, &(elem(&1, 0) == collector))
    assert report.skipped[:router_role] >= 1

    # Still there, deliberately: for a router the mapper writes the device's own
    # interface addresses as ip_alias and nowhere else.
    assert collector |> alias_keys() |> Enum.sort() == Enum.sort(absorbed)
  end

  # A collector at .11 carrying two neighbours' addresses, each of which has its
  # own device row, plus stale :ip alias rows naming the collector.
  defp seed_pathology(opts \\ []) do
    suffix = System.unique_integer([:positive])
    octet = rem(suffix, 200) + 20
    collector_ip = "10.99.#{octet}.11"
    absorbed = ["10.99.#{octet}.8", "10.99.#{octet}.12"]
    collector = "sr:test-collector-#{suffix}"

    metadata =
      %{
        "agent_id" => "agent-collector-#{suffix}",
        "ip_alias:#{collector_ip}" => "2026-08-23T14:30:01Z"
      }
      |> Map.merge(Map.new(absorbed, &{"ip_alias:#{&1}", "2026-08-23T14:30:01Z"}))
      |> then(fn m ->
        case Keyword.get(opts, :role) do
          nil -> m
          role -> Map.put(m, "device_role", role)
        end
      end)

    insert_device(collector, collector_ip, metadata, [
      "passive-netprobe",
      "sysmon",
      "agent",
      "sweep"
    ])

    for ip <- absorbed do
      insert_device("sr:test-host-#{ip}-#{suffix}", ip, %{}, ["sweep"])
      insert_alias_state(collector, ip, "stale")
    end

    %{
      collector: collector,
      collector_ip: collector_ip,
      absorbed: absorbed,
      manifest_path:
        Path.join(
          System.tmp_dir!(),
          "netprobe-alias-debris-#{suffix}-#{:erlang.unique_integer([:positive])}.ndjson"
        )
    }
  end

  defp insert_device(uid, ip, metadata, sources) do
    Repo.query!(
      """
      INSERT INTO platform.ocsf_devices (uid, ip, metadata, discovery_sources, first_seen_time, last_seen_time, modified_time)
      VALUES ($1, $2, $3::jsonb, $4, timezone('utc', now()), timezone('utc', now()), timezone('utc', now()))
      ON CONFLICT (uid) DO NOTHING
      """,
      [uid, ip, metadata, sources]
    )
  end

  defp insert_alias_state(device_id, value, state) do
    Repo.query!(
      """
      INSERT INTO platform.device_alias_states
        (id, device_id, partition, alias_type, alias_value, state, first_seen_at, last_seen_at, sighting_count, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, 'default', 'ip', $2, $3, timezone('utc', now()), timezone('utc', now()), 1, timezone('utc', now()), timezone('utc', now()))
      ON CONFLICT DO NOTHING
      """,
      [device_id, value, state]
    )
  end

  defp alias_keys(uid) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT substring(k from 10)
        FROM platform.ocsf_devices d, jsonb_object_keys(d.metadata) k
        WHERE d.uid = $1 AND k LIKE 'ip_alias:%' AND substring(k from 10) IS DISTINCT FROM d.ip
        """,
        [uid]
      )

    List.flatten(rows)
  end

  defp alias_state_values(device_id, state) do
    %{rows: rows} =
      Repo.query!(
        "SELECT alias_value FROM platform.device_alias_states WHERE device_id = $1 AND state = $2",
        [device_id, state]
      )

    List.flatten(rows)
  end

  defp device_count_for_ip(ip) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM platform.ocsf_devices WHERE ip = $1", [ip])

    count
  end
end
