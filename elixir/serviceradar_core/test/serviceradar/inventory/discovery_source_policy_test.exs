defmodule ServiceRadar.Inventory.DiscoverySourcePolicyTest do
  @moduledoc """
  Which netprobe discovery payloads may bring a device into existence?

  Exactly one: the census. ARP/NDP is the device answering for its own address,
  which is the only unforgeable presence evidence netprobe has. Everything else
  netprobe emits -- mDNS, TCP/TLS/HTTP fingerprints, DPI, process attribution --
  DESCRIBES something, and a description with no sighting behind it must not
  mint a record. A single spoofed mDNS announcement would otherwise produce a
  device with a name, a model and a type and nothing anchoring any of them.

  `SourcePolicy` states that rule and unit tests cover the predicates. This file
  covers the OUTCOME, which is a different code path: the enrichment gate, the
  resolver and the upsert all sit between the predicate and the row. The
  fingerprint payload's version of these assertions lives in
  `sync_ingestor_passive_netprobe_identity_test.exs`, which reproduced the
  collector over-merge; this file covers the payloads that moved onto the
  generic add-on contract alongside it and had no DB-backed coverage at all.
  """
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceEnrichmentRules
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Repo

  require Ash.Query

  setup_all do
    rules_dir = Path.join(System.tmp_dir!(), "serviceradar-discovery-policy-rules")
    File.mkdir_p!(rules_dir)
    Application.put_env(:serviceradar_core, :device_enrichment_rules_dir, rules_dir)
    DeviceEnrichmentRules.reload()
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:discovery_source_policy_test)}
  end

  describe "the census may create" do
    @tag :visibility
    test "an ARP sighting of an unknown device creates one", %{actor: actor} do
      ip = unique_ip()
      mac = unique_mac()

      assert :ok = SyncIngestor.ingest_updates([census_update(ip, mac)], actor: actor)

      assert [device] = devices_for_ip(actor, ip),
             """
             the census did not create a device. If this fails while the
             enrichment-only tests below still pass, the rule has become
             "netprobe may never create" rather than "only the census may".
             """

      assert device.mac == mac
    end
  end

  describe "enrichment-only payloads may not create" do
    @tag :visibility
    test "an mDNS announcement about an unknown device creates nothing", %{actor: actor} do
      update = mdns_update(unique_mac())

      assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

      assert device_count_for_mac(update["mac"]) == 0,
             "a spoofable multicast announcement minted a device"
    end

    @tag :visibility
    test "a DPI observation of an unknown address creates nothing", %{actor: actor} do
      ip = unique_ip()

      assert :ok = SyncIngestor.ingest_updates([dpi_update(ip)], actor: actor)

      # A DPI event's subject is a CHOICE between two endpoints. Letting that
      # choice create devices mints one per arbitrary internet peer.
      assert devices_for_ip(actor, ip) == []
    end

    @tag :visibility
    test "a process attribution for an unknown address creates nothing", %{actor: actor} do
      ip = unique_ip()

      assert :ok = SyncIngestor.ingest_updates([process_update(ip)], actor: actor)

      assert devices_for_ip(actor, ip) == []
    end
  end

  describe "enrichment-only payloads still enrich what the census established" do
    @tag :visibility
    test "mDNS lands on the census device rather than a second one", %{actor: actor} do
      ip = unique_ip()
      mac = unique_mac()

      assert :ok = SyncIngestor.ingest_updates([census_update(ip, mac)], actor: actor)
      assert [seeded] = devices_for_ip(actor, ip)

      assert :ok = SyncIngestor.ingest_updates([mdns_update(mac)], actor: actor)

      assert [enriched] = devices_for_ip(actor, ip)
      assert enriched.uid == seeded.uid

      # Without this the create-nothing tests above would pass just as well with
      # the payload silently discarded in every case.
      assert enriched.metadata["mdns.services"] == "_ssh._tcp",
             "the announcement was dropped rather than applied: #{inspect(Map.keys(enriched.metadata || %{}))}"
    end

    @tag :visibility
    test "DPI lands on the census device rather than a second one", %{actor: actor} do
      ip = unique_ip()

      assert :ok = SyncIngestor.ingest_updates([census_update(ip, unique_mac())], actor: actor)
      assert [seeded] = devices_for_ip(actor, ip)

      assert :ok = SyncIngestor.ingest_updates([dpi_update(ip)], actor: actor)

      assert [enriched] = devices_for_ip(actor, ip)

      assert enriched.uid == seeded.uid,
             "DPI created a second device for an address the census already owns"

      # The gate matches an address-only enrichment source on its ADDRESS: it has
      # no strong identifier to match on, and before that was true every such
      # payload was discarded with only a debug line.
      assert enriched.metadata["dpi.protocol"] == "dns",
             "the DPI observation was dropped rather than applied: #{inspect(Map.keys(enriched.metadata || %{}))}"
    end
  end

  defp census_update(ip, mac) do
    observed_at = "2026-08-23T14:30:01.123456789Z"

    %{
      "ip" => ip,
      "mac" => mac,
      "source" => "netprobe-census",
      "timestamp" => observed_at,
      "metadata" => %{
        "identity_source" => "netprobe_census",
        "discovery_source" => "netprobe-census",
        "source" => "netprobe-census",
        # Duplicated from the top-level field on purpose, exactly as
        # Decoders.Census does: SourcePolicy.census_anchorable_mac?/1 reads
        # metadata["mac"], so a census update carrying its MAC only at the top
        # level registers no mac identifier and nothing can ever enrich it.
        "mac" => mac,
        "device_census.interface" => "eth0",
        "device_census.protocol" => "arp",
        "device_census.observed_at" => observed_at,
        "_alias_last_seen_ip" => ip,
        "_alias_last_seen_at" => observed_at,
        "ip_alias:#{ip}" => observed_at
      }
    }
  end

  defp mdns_update(mac) do
    %{
      "mac" => mac,
      "source" => "netprobe-mdns",
      "metadata" => %{
        "identity_source" => "netprobe_mdns",
        "discovery_source" => "netprobe-mdns",
        "source" => "netprobe-mdns",
        "mdns.services" => "_ssh._tcp"
      }
    }
  end

  defp dpi_update(ip) do
    observed_at = "2026-08-23T14:30:02.123456789Z"

    %{
      "ip" => ip,
      "source" => "passive-netprobe",
      "timestamp" => observed_at,
      "metadata" => %{
        "identity_source" => "netprobe_dpi",
        "discovery_source" => "passive-netprobe",
        "source" => "passive-netprobe",
        "dpi.source" => "passive-netprobe",
        "dpi.protocol" => "dns",
        "dpi.observed_at" => observed_at,
        "_alias_last_seen_ip" => ip,
        "_alias_last_seen_at" => observed_at,
        "ip_alias:#{ip}" => observed_at
      }
    }
  end

  defp process_update(ip) do
    observed_at = "2026-08-23T14:30:03.123456789Z"

    %{
      "ip" => ip,
      "source" => "passive-netprobe",
      "timestamp" => observed_at,
      "metadata" => %{
        "identity_source" => "netprobe_process",
        "discovery_source" => "passive-netprobe",
        "source" => "passive-netprobe",
        "process.name" => "sshd",
        "process.observed_at" => observed_at,
        "_alias_last_seen_ip" => ip,
        "_alias_last_seen_at" => observed_at
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

  defp device_count_for_mac(mac) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM platform.ocsf_devices WHERE mac = $1", [mac])

    count
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
