defmodule ServiceRadar.Inventory.SyncIngestorPassiveNetprobeIdentityTest do
  @moduledoc """
  Does a passive-netprobe fingerprint identify the HOST it describes, or the
  COLLECTOR that observed it?

  The agent sets `agent_id` to the COLLECTOR's id on every fingerprint update --
  both as a top-level field and inside metadata (`push_loop_mapper_netprobe.go`
  builds `%{"ip" => device.GetIp(), "agent_id" => agentID, ...}`, and
  `translator.go` `baseMetadata` adds `agent_id` again). `agent_id` is FIRST in
  `Ids.identifier_priority/0`, and `SourcePolicy.observer_agent_source?/1` --
  which is what demotes a collector's own id from an identifying attribute to a
  mere observation -- lists mapper, sweep, network_discovery, census, mDNS, armis
  and snmp, but NOT "passive-netprobe".

  If that means what it reads like, then every host this collector fingerprints
  resolves onto ONE device keyed by the collector's agent_id, each contributing
  its own `ip_alias:<host ip>`. That is device inventory collapsing to one row
  per collector instead of one row per host.

  The existing coverage cannot see this: `sync_ingestor_vendor_type_test.exs`
  hand-writes its passive-netprobe update with NO agent_id at all, top-level or
  in metadata -- a shape the real translator never emits.

  These tests use the REAL update shape. They are written to be honest either
  way: if the sources stay distinct, that is a genuine kill of the hypothesis.
  """
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceEnrichmentRules
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Repo

  require Ash.Query

  setup_all do
    test_rules_dir = Path.join(System.tmp_dir!(), "serviceradar-passive-identity-rules-empty")
    File.mkdir_p!(test_rules_dir)
    Application.put_env(:serviceradar_core, :device_enrichment_rules_dir, test_rules_dir)
    DeviceEnrichmentRules.reload()
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:sync_ingestor_passive_netprobe_identity_test)}
  end

  @tag :visibility
  test "two known hosts fingerprinted by ONE collector stay two devices", %{actor: actor} do
    collector_agent_id = "agent-collector-#{System.unique_integer([:positive])}"
    host_a = unique_ip()
    host_b = unique_ip()

    # Something else put these on the map first -- the census does this from
    # ARP/NDP. A fingerprint only ever describes a device that already exists.
    assert :ok =
             SyncIngestor.ingest_updates(
               [seed_device(host_a, "host-a"), seed_device(host_b, "host-b")],
               actor: actor
             )

    uids_before_a = uids_for_ip(actor, host_a)
    uids_before_b = uids_for_ip(actor, host_b)
    refute MapSet.size(uids_before_a) == 0, "seed for host A did not create a device"
    refute MapSet.size(uids_before_b) == 0, "seed for host B did not create a device"

    assert MapSet.disjoint?(uids_before_a, uids_before_b),
           "the two seeds already collapsed; test premise is broken"

    assert :ok =
             SyncIngestor.ingest_updates(
               [
                 passive_fingerprint_update(host_a, collector_agent_id, "linux"),
                 passive_fingerprint_update(host_b, collector_agent_id, "windows")
               ],
               actor: actor
             )

    uids_after_a = uids_for_ip(actor, host_a)
    uids_after_b = uids_for_ip(actor, host_b)

    assert MapSet.disjoint?(uids_after_a, uids_after_b),
           """
           OVER-MERGE: two hosts fingerprinted by one collector share a device uid.
             collector agent_id: #{collector_agent_id}
             host A (#{host_a}): #{inspect(MapSet.to_list(uids_after_a))}
             host B (#{host_b}): #{inspect(MapSet.to_list(uids_after_b))}
           """

    assert uids_after_a == uids_before_a,
           "host A changed identity when it was fingerprinted"

    assert uids_after_b == uids_before_b,
           "host B changed identity when it was fingerprinted"

    # And the enrichment actually landed -- otherwise this test would pass just
    # as well with the fingerprint silently discarded.
    device_a = Enum.find(devices_for_ip(actor, host_a), &(&1.uid in uids_after_a))
    metadata_a = device_a.metadata || %{}

    assert metadata_a["passive_fingerprint.tcp.os_family"] == "linux",
           """
           the fingerprint was dropped instead of enriching host A.
           An IP-only enrichment source has no strong identifier, so the enrichment
           gate must match it on its address.
             metadata keys: #{inspect(Map.keys(metadata_a))}
           """

    refute Map.has_key?(metadata_a, "ip_alias:#{host_b}"),
           "host A absorbed host B's address"
  end

  @tag :visibility
  test "a fingerprint for an unknown host creates no device", %{actor: actor} do
    collector_agent_id = "agent-collector-#{System.unique_integer([:positive])}"
    unknown_host = unique_ip()

    assert :ok =
             SyncIngestor.ingest_updates(
               [passive_fingerprint_update(unknown_host, collector_agent_id, "linux")],
               actor: actor
             )

    assert devices_for_ip(actor, unknown_host) == [],
           """
           a passive fingerprint minted a device for an address nothing else has seen.
           A SYN fingerprint says what something at an address looks like; only the
           census says something is there.
           """
  end

  @tag :visibility
  test "a fingerprint does not attach the host to the collector's own device", %{actor: actor} do
    collector_agent_id = "agent-collector-#{System.unique_integer([:positive])}"
    collector_ip = unique_ip()
    host_ip = unique_ip()

    # The collector's own device, as its self-report creates it: keyed by the
    # same agent_id the fingerprint updates will carry.
    assert :ok =
             SyncIngestor.ingest_updates(
               [
                 %{
                   "ip" => collector_ip,
                   "mac" => unique_mac(),
                   "hostname" => "collector-host",
                   "agent_id" => collector_agent_id,
                   "source" => "self-reported",
                   "metadata" => %{"agent_id" => collector_agent_id}
                 }
               ],
               actor: actor
             )

    collector_devices = devices_for_ip(actor, collector_ip)
    refute collector_devices == [], "collector device was not created; test premise is broken"
    collector_uids = MapSet.new(collector_devices, & &1.uid)

    # The host exists in its own right before it is fingerprinted. Without this
    # the assertions below pass vacuously: an enrichment-only update for an
    # unknown address is dropped, and an empty set is disjoint from anything.
    assert :ok =
             SyncIngestor.ingest_updates([seed_device(host_ip, "fingerprinted-host")],
               actor: actor
             )

    host_uids_before = uids_for_ip(actor, host_ip)
    refute MapSet.size(host_uids_before) == 0, "host seed did not create a device"

    assert MapSet.disjoint?(collector_uids, host_uids_before),
           "collector and host already share a uid before any fingerprint; premise is broken"

    assert :ok =
             SyncIngestor.ingest_updates(
               [passive_fingerprint_update(host_ip, collector_agent_id, "linux")],
               actor: actor
             )

    host_devices = devices_for_ip(actor, host_ip)
    host_uids = MapSet.new(host_devices, & &1.uid)
    refute MapSet.size(host_uids) == 0, "the host lost its device when it was fingerprinted"

    collector_now = devices_for_ip(actor, collector_ip)

    stole_the_alias =
      Enum.filter(collector_now, fn device ->
        Map.has_key?(device.metadata || %{}, "ip_alias:#{host_ip}")
      end)

    assert stole_the_alias == [],
           """
           OVER-MERGE REPRODUCED: the collector's own device absorbed the fingerprinted host.
             collector agent_id: #{collector_agent_id}
             collector ip: #{collector_ip}
             fingerprinted host ip: #{host_ip}
             collector device uids: #{inspect(Enum.map(stole_the_alias, & &1.uid))}
           """

    assert MapSet.disjoint?(collector_uids, host_uids),
           """
           OVER-MERGE REPRODUCED: the fingerprinted host resolved onto the collector's device uid.
             collector: #{inspect(MapSet.to_list(collector_uids))}
             host:      #{inspect(MapSet.to_list(host_uids))}
           """
  end

  # The real translator's output, reproduced key for key: top-level agent_id from
  # push_loop_mapper_netprobe.go, metadata agent_id + alias keys from
  # translator.go baseMetadata, evidence keys from addEvidenceMetadata.
  defp passive_fingerprint_update(ip, collector_agent_id, os_family) do
    observed_at = "2026-08-23T14:30:01.123456789Z"

    %{
      "ip" => ip,
      "agent_id" => collector_agent_id,
      "source" => "passive-netprobe",
      "timestamp" => observed_at,
      "metadata" => %{
        "discovery_source" => "passive-netprobe",
        "source" => "passive-netprobe",
        "agent_id" => collector_agent_id,
        "passive_fingerprint.source" => "passive-netprobe",
        "passive_fingerprint.interface" => "eth0",
        "passive_fingerprint.observed_at" => observed_at,
        "passive_fingerprint.protocol" => "tcp",
        "passive_fingerprint.tcp.signature" => "64240:64:1:60:M1460,S,T,N,W7",
        "passive_fingerprint.tcp.os_family" => os_family,
        "passive_fingerprint.tcp.confidence" => "0.920",
        "_alias_last_seen_ip" => ip,
        "_alias_last_seen_at" => observed_at,
        "ip_alias:#{ip}" => observed_at
      }
    }
  end

  defp uids_for_ip(actor, ip), do: actor |> devices_for_ip(ip) |> MapSet.new(& &1.uid)

  defp seed_device(ip, hostname) do
    integration_id = "seed-#{System.unique_integer([:positive])}"

    %{
      "ip" => ip,
      "mac" => unique_mac(),
      "hostname" => hostname,
      "source" => "armis",
      "metadata" => %{
        "integration_id" => integration_id,
        "integration_type" => "armis",
        "armis_device_id" => integration_id
      }
    }
  end

  defp devices_for_ip(actor, ip) do
    query = Ash.Query.filter(Device, ip == ^ip)
    assert {:ok, result} = Ash.read(query, actor: actor)

    case result do
      %Ash.Page.Keyset{results: rows} -> rows
      rows when is_list(rows) -> rows
    end
  end

  defp unique_ip do
    fn -> System.unique_integer([:positive, :monotonic]) end
    |> Stream.repeatedly()
    |> Enum.find_value(fn n ->
      ip = "10.#{rem(div(n, 65_025), 250) + 1}.#{rem(div(n, 255), 250) + 1}.#{rem(n, 250) + 1}"

      case Repo.query("SELECT 1 FROM platform.ocsf_devices WHERE ip = $1 LIMIT 1", [ip]) do
        {:ok, %{rows: []}} -> ip
        _ -> nil
      end
    end)
  end

  defp unique_mac do
    [:positive]
    |> System.unique_integer()
    |> Integer.to_string(16)
    |> String.pad_leading(10, "0")
    |> String.upcase()
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", &Enum.join/1)
    |> then(&("A8:" <> &1))
  end
end
