defmodule ServiceRadar.Inventory.SyncIngestorMdnsEnrichmentTest do
  @moduledoc """
  SyncIngestor must not mint a device from an update that cannot create one.

  The predicate this rests on is unit-tested in SourcePolicyCensusTest and
  LookupsEnrichmentTest. This file asserts the WIRING: that SyncIngestor
  actually consults `SourcePolicy.sufficient_to_create?/1` before the writes,
  which is the part a passing predicate cannot prove. The gate sits in
  `drop_unmatched_enrichment_updates/3`; delete that line and every unit test
  still passes while announcements and ARP probes start creating devices.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:sync_ingestor_mdns_enrichment_test)}
  end

  defp unique_mac do
    # 0xA8, not 0xAA. Bit 1 of the first octet must be CLEAR: a locally
    # administered MAC is refused as an anchor by
    # SourcePolicy.census_anchorable_mac?/1, so the census seed would register
    # no identifier at all and every assertion below would pass against an
    # empty result -- the file green while proving nothing. It failed exactly
    # that way first.
    suffix = [:positive] |> System.unique_integer() |> rem(0xFFFFFF)
    rest = suffix |> Integer.to_string(16) |> String.pad_leading(6, "0")

    "A8:BB:CC:" <> String.replace(rest, ~r/(..)(..)(..)/, "\\1:\\2:\\3")
  end

  defp normalized(mac), do: mac |> String.replace(":", "") |> String.upcase()

  defp mac_identifiers(mac, actor) do
    query =
      Ash.Query.for_read(DeviceIdentifier, :lookup, %{
        identifier_type: :mac,
        identifier_value: normalized(mac),
        partition: "default"
      })

    {:ok, identifiers} = Ash.read(query, actor: actor)

    identifiers
  end

  defp census_update(mac, ip) do
    %{
      "ip" => ip,
      "mac" => mac,
      "source" => "netprobe-census",
      "partition" => "default",
      "metadata" => %{
        "mac" => mac,
        "identity_source" => "netprobe_census",
        "agent_id" => "collector-1"
      }
    }
  end

  defp mdns_update(mac) do
    # No "ip" key: mDNS identifies, it does not locate.
    %{
      "mac" => mac,
      "source" => "netprobe-mdns",
      "partition" => "default",
      "metadata" => %{
        "mac" => mac,
        "identity_source" => "netprobe_mdns",
        "agent_id" => "collector-1",
        "mdns.service_types" => "_airplay._tcp",
        "mdns.model" => "B620AP"
      }
    }
  end

  describe "an announcement from a host nothing has sighted" do
    test "creates no device", %{actor: actor} do
      mac = unique_mac()

      assert :ok = SyncIngestor.ingest_updates([mdns_update(mac)], actor: actor)

      assert [] == mac_identifiers(mac, actor),
             "an mDNS announcement minted a device for a MAC no census ever saw"
    end
  end

  describe "an announcement from a host the census already found" do
    test "lands on the existing device instead of creating a second one", %{actor: actor} do
      mac = unique_mac()
      ip = "10.60.#{:rand.uniform(200)}.#{:rand.uniform(200)}"

      assert :ok = SyncIngestor.ingest_updates([census_update(mac, ip)], actor: actor)
      assert [seeded] = mac_identifiers(mac, actor)

      assert :ok = SyncIngestor.ingest_updates([mdns_update(mac)], actor: actor)

      assert [enriched] = mac_identifiers(mac, actor)

      assert enriched.device_id == seeded.device_id,
             "mDNS resolved to a different device than the census sighting it describes"
    end

    test "a batch mixing both is filtered per update, not wholesale", %{actor: actor} do
      # The gate rejects individual updates. A batch-level decision would
      # either drop the known device's enrichment along with the unknown one,
      # or admit the unknown one along with the known.
      known = unique_mac()
      unknown = unique_mac()
      ip = "10.61.#{:rand.uniform(200)}.#{:rand.uniform(200)}"

      assert :ok = SyncIngestor.ingest_updates([census_update(known, ip)], actor: actor)

      assert :ok =
               SyncIngestor.ingest_updates(
                 [mdns_update(known), mdns_update(unknown)],
                 actor: actor
               )

      assert [_] = mac_identifiers(known, actor)
      assert [] == mac_identifiers(unknown, actor)
    end
  end

  describe "an addressless census ARP probe" do
    test "creates no device", %{actor: actor} do
      mac = unique_mac()

      assert :ok = SyncIngestor.ingest_updates([census_update(mac, "")], actor: actor)

      assert [] == mac_identifiers(mac, actor),
             "an RFC 5227 ARP probe minted a device for an address nobody holds"
    end

    test "does not vacate the IP of a device the census already found", %{actor: actor} do
      mac = unique_mac()
      ip = "10.62.#{:rand.uniform(200)}.#{:rand.uniform(200)}"

      assert :ok = SyncIngestor.ingest_updates([census_update(mac, ip)], actor: actor)
      assert [seeded] = mac_identifiers(mac, actor)

      assert :ok = SyncIngestor.ingest_updates([census_update(mac, "")], actor: actor)
      assert [after_probe] = mac_identifiers(mac, actor)

      assert after_probe.device_id == seeded.device_id

      {:ok, [device]} =
        Device
        |> Ash.Query.filter(ip == ^ip)
        |> Ash.read(actor: actor)
        |> Page.unwrap()

      assert device.uid == seeded.device_id
    end
  end
end
