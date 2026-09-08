defmodule ServiceRadar.Inventory.Discovery.DecodersTest do
  @moduledoc """
  The census and mDNS decoders, ported from the agent-side Go translators.

  Payloads are built by ENCODING the real protobuf messages, so these exercise
  the actual decode path rather than a hand-made map.

  The cases mirror the golden fixture corpus: every skip rule, every flag, every
  tri-state. Ordinary devices pin almost nothing -- the branches are where a
  port goes wrong.
  """
  use ExUnit.Case, async: true

  alias Serviceradar.Agent.Netprobe.V1.DeviceCensusObservation
  alias Serviceradar.Agent.Netprobe.V1.DeviceCensusSnapshot
  alias Serviceradar.Agent.Netprobe.V1.MdnsDevice
  alias Serviceradar.Agent.Netprobe.V1.MdnsSnapshot
  alias Serviceradar.Agent.Netprobe.V1.MdnsTxtPair
  alias ServiceRadar.Inventory.Discovery.Decoders

  @first_seen 1_700_000_000_000_000_000
  @last_seen 1_700_000_060_000_000_000

  defp census_payload(observations, overrides \\ []) do
    DeviceCensusSnapshot.encode(%DeviceCensusSnapshot{
      observations: observations,
      snapshot_id: "ens18-1700000000-1",
      interface_name: "ens18",
      generated_at_unix_nano: @last_seen,
      complete: Keyword.get(overrides, :complete, true),
      chunk_count: 1
    })
  end

  defp observation(fields) do
    struct!(
      %DeviceCensusObservation{
        mac: "a8:bb:cc:00:00:01",
        ip: "192.168.1.10",
        interface_index: 2,
        kind: :DEVICE_CENSUS_KIND_ARP_REPLY,
        first_seen_unix_nano: @first_seen,
        last_seen_unix_nano: @last_seen
      },
      fields
    )
  end

  defp mdns_payload(devices, overrides \\ []) do
    MdnsSnapshot.encode(%MdnsSnapshot{
      devices: devices,
      snapshot_id: "ens18-1700000000-7",
      interface_name: "ens18",
      generated_at_unix_nano: @last_seen,
      complete: Keyword.get(overrides, :complete, true),
      chunk_count: 1
    })
  end

  defp mdns_device(fields) do
    struct!(
      %MdnsDevice{
        mac: "a8:bb:cc:00:01:01",
        interface_index: 2,
        first_seen_unix_nano: @first_seen,
        last_seen_unix_nano: @last_seen
      },
      fields
    )
  end

  describe "census decoder" do
    test "an ordinary ARP reply produces one observation with census metadata" do
      assert {:ok, [row], stats} = Decoders.Census.decode(census_payload([observation([])]))

      assert row["ip"] == "192.168.1.10"
      assert row["mac"] == "a8:bb:cc:00:00:01"
      assert row["metadata"]["mac"] == "a8:bb:cc:00:00:01"
      assert row["metadata"]["device_census.kind"] == "arp_reply"
      assert row["metadata"]["device_census.interface"] == "ens18"
      assert row["metadata"]["device_census.randomized_mac"] == "false"
      assert row["metadata"]["_alias_last_seen_ip"] == "192.168.1.10"
      assert stats.devices == 1
      assert stats.observations == 1
    end

    test "the decoder never stamps identity" do
      # THE rule for every decoder. agent_id, gateway_id, partition and source
      # come from gateway-attested metadata and the schema registry. A decoder
      # that read them from the payload would let an add-on claim to be a
      # different agent, or to be a source with a weaker guardrail.
      assert {:ok, [row], _stats} = Decoders.Census.decode(census_payload([observation([])]))

      for forbidden <- ["agent_id", "gateway_id", "partition", "source", "identity_source"] do
        refute Map.has_key?(row["metadata"], forbidden),
               "decoder set #{forbidden}, which only the ingestor may stamp"
      end
    end

    test "an addressless ARP probe is kept but invents no alias" do
      # RFC 5227: a probe has a MAC and no address yet. An empty alias would
      # record a binding the device never claimed.
      payload =
        census_payload([observation(ip: "", kind: :DEVICE_CENSUS_KIND_ARP_REQUEST)])

      assert {:ok, [row], stats} = Decoders.Census.decode(payload)

      assert row["ip"] == ""
      assert row["metadata"]["device_census.kind"] == "arp_request"
      refute Map.has_key?(row["metadata"], "_alias_last_seen_ip")
      refute Enum.any?(Map.keys(row["metadata"]), &String.starts_with?(&1, "ip_alias:"))
      assert stats.addressless == 1
      assert stats.devices == 1
    end

    test "an off-segment sighting is skipped" do
      # It carries the ROUTER's MAC. Emitting it would bind a remote address to
      # the gateway's hardware and collapse distinct hosts onto one device.
      payload = census_payload([observation(ip: "203.0.113.7", off_segment: true)])

      assert {:ok, [], stats} = Decoders.Census.decode(payload)
      assert stats.skipped_off_segment == 1
      assert stats.devices == 0
    end

    test "an observation with no MAC is skipped" do
      assert {:ok, [], stats} = Decoders.Census.decode(census_payload([observation(mac: "   ")]))
      assert stats.skipped_no_mac == 1
    end

    test "a randomized MAC is emitted and flagged, not dropped" do
      # It is real presence evidence. Core refuses to let it ANCHOR a device;
      # that is a different decision from discarding the sighting.
      payload = census_payload([observation(mac: "aa:bb:cc:00:00:04", randomized_mac: true)])

      assert {:ok, [row], stats} = Decoders.Census.decode(payload)
      assert row["metadata"]["device_census.randomized_mac"] == "true"
      assert stats.randomized_mac == 1
      assert stats.devices == 1
    end

    test "an incomplete snapshot is refused outright" do
      # Applying a fragment would read as "every device in the missing parts
      # has left the segment".
      payload = census_payload([observation([])], complete: false)

      assert {:error, :incomplete_snapshot} = Decoders.Census.decode(payload)
    end

    test "an unknown kind degrades to unspecified rather than failing" do
      # netprobe may ship a kind before core knows it. Losing a whole snapshot
      # over one unrecognised label would be a worse outcome than an imprecise
      # one.
      payload = census_payload([observation(kind: 99)])

      assert {:ok, [row], _stats} = Decoders.Census.decode(payload)
      assert row["metadata"]["device_census.kind"] == "unspecified"
    end

    test "a corrupt payload is an error, not a crash" do
      assert {:error, _reason} = Decoders.Census.decode(<<0xFF, 0xFF, 0xFF, 0xFF>>)
      assert {:error, :invalid_payload} = Decoders.Census.decode(nil)
    end
  end

  describe "mdns decoder" do
    test "a single model is asserted" do
      payload =
        mdns_payload([
          mdns_device(service_types: ["_airplay._tcp"], models: ["SyntheticTV1,1"])
        ])

      assert {:ok, [row], stats} = Decoders.Mdns.decode(payload)
      assert row["metadata"]["mdns.model"] == "SyntheticTV1,1"
      assert row["metadata"]["mdns.ambiguous_model"] == "false"
      assert stats.emitted == 1
    end

    test "an ambiguous MAC asserts no model but keeps the evidence" do
      # The case the whole mDNS design turns on. Emitting either model would let
      # core type the device from whichever sorted first -- a wrong answer that
      # looks exactly like a right one.
      payload =
        mdns_payload([
          mdns_device(
            service_types: ["_airplay._tcp"],
            models: ["SyntheticSpeaker5,1", "SyntheticTV6,2"],
            ambiguous_model: true
          )
        ])

      assert {:ok, [row], stats} = Decoders.Mdns.decode(payload)
      refute Map.has_key?(row["metadata"], "mdns.model")
      assert row["metadata"]["mdns.models"] == "SyntheticSpeaker5,1,SyntheticTV6,2"
      assert row["metadata"]["mdns.ambiguous_model"] == "true"
      assert stats.ambiguous == 1
    end

    test "an announced address is dropped" do
      # mDNS identifies; it does not locate. There must be no "ip" key at all --
      # an empty string would read as a claim rather than an absence.
      payload =
        mdns_payload([
          mdns_device(ip: "192.168.1.55", service_types: ["_googlecast._tcp"])
        ])

      assert {:ok, [row], _stats} = Decoders.Mdns.decode(payload)
      refute Map.has_key?(row, "ip")
      refute Map.has_key?(row["metadata"], "ip")
    end

    test "TXT keeps all three RFC 6763 states apart" do
      payload =
        mdns_payload([
          mdns_device(
            service_types: ["_ipp._tcp"],
            txt: [
              %MdnsTxtPair{key: "md", value: "", has_value: false},
              %MdnsTxtPair{key: "am", value: "", has_value: true},
              %MdnsTxtPair{key: "ty", value: "synthetic printer", has_value: true}
            ]
          )
        ])

      assert {:ok, [row], _stats} = Decoders.Mdns.decode(payload)
      assert row["metadata"]["mdns.txt.md"] == "true"
      assert row["metadata"]["mdns.txt.am"] == ""
      assert Map.has_key?(row["metadata"], "mdns.txt.am")
      assert row["metadata"]["mdns.txt.ty"] == "synthetic printer"
    end

    test "a device that announced nothing identifying is skipped" do
      assert {:ok, [], stats} = Decoders.Mdns.decode(mdns_payload([mdns_device([])]))
      assert stats.skipped_no_evidence == 1
      assert stats.emitted == 0
    end

    test "a device with no MAC is skipped" do
      payload = mdns_payload([mdns_device(mac: "  ", service_types: ["_airplay._tcp"])])

      assert {:ok, [], stats} = Decoders.Mdns.decode(payload)
      assert stats.skipped_no_mac == 1
    end

    test "truncation is counted without discarding what parsed" do
      payload =
        mdns_payload([mdns_device(service_types: ["_ipp._tcp"], truncated: true)])

      assert {:ok, [row], stats} = Decoders.Mdns.decode(payload)
      assert row["metadata"]["mdns.truncated"] == "true"
      assert stats.truncated == 1
      assert stats.emitted == 1
    end

    test "the decoder never stamps identity" do
      payload = mdns_payload([mdns_device(service_types: ["_airplay._tcp"])])

      assert {:ok, [row], _stats} = Decoders.Mdns.decode(payload)

      for forbidden <- ["agent_id", "gateway_id", "partition", "source", "identity_source"] do
        refute Map.has_key?(row["metadata"], forbidden)
      end
    end

    test "an incomplete snapshot is refused outright" do
      payload = mdns_payload([mdns_device(service_types: ["_ipp._tcp"])], complete: false)

      assert {:error, :incomplete_snapshot} = Decoders.Mdns.decode(payload)
    end
  end
end
