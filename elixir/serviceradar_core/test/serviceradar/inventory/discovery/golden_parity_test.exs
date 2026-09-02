defmodule ServiceRadar.Inventory.Discovery.GoldenParityTest do
  @moduledoc """
  The Elixir decoders must produce what the Go translators produce.

  This is the test the whole port rests on. The fixtures in
  `go/pkg/agent/netprobe/testdata/discovery_golden/` were captured from the REAL
  Go translators before any of this existed, precisely so that after the Go code
  is deleted there is still something to compare against.

  It already earned its keep once: it caught that the obvious Elixir spelling of
  a Go RFC3339Nano timestamp produces "2023-11-14T22:14:20.000000Z" where Go
  produces "2023-11-14T22:14:20Z", and that DateTime silently truncates real
  nanosecond timestamps to microseconds. Those strings land in
  `_alias_last_seen_at` and `ip_alias:<ip>`, which device alias resolution
  reads, so the mismatch would have quietly stopped aliases resolving after the
  cutover with nothing erroring.

  ## What is compared, and what is not

  Every metadata key EXCEPT the identity fields. `agent_id`, `gateway_id`,
  `partition`, `source` and `discovery_source` are written by the Go translator
  from its TranslationOptions; in core they come from gateway-attested status
  metadata and the schema registry instead. Expecting a decoder to invent
  "agent-1" would be asserting the wrong thing.

  `identity_source` is also excluded for the same reason -- it is stamped from
  the registry, and `discovery_schema_registry_test.exs` is what holds it to the
  right value.
  """
  use ExUnit.Case, async: true

  alias Serviceradar.Agent.Netprobe.V1.DeviceCensusObservation
  alias Serviceradar.Agent.Netprobe.V1.DeviceCensusSnapshot
  alias Serviceradar.Agent.Netprobe.V1.MdnsDevice
  alias Serviceradar.Agent.Netprobe.V1.MdnsSnapshot
  alias Serviceradar.Agent.Netprobe.V1.MdnsTxtPair
  alias ServiceRadar.Inventory.Discovery.Decoders

  # Written by the ingestor from attested metadata and the registry, never by a
  # decoder. decoders_test.exs asserts the decoders do not set them at all.
  @stamped_by_core ~w(agent_id gateway_id partition source identity_source discovery_source)

  @first_seen 1_700_000_000_000_000_000
  @last_seen 1_700_000_060_000_000_000
  @census_snapshot_id "ens18-1700000000-1"
  @mdns_snapshot_id "ens18-1700000000-7"

  defp golden_path(name) do
    [
      __DIR__,
      "..",
      "..",
      "..",
      "..",
      "..",
      "..",
      "go",
      "pkg",
      "agent",
      "netprobe",
      "testdata",
      "discovery_golden",
      name <> ".json"
    ]
    |> Path.join()
    |> Path.expand()
  end

  defp golden!(name) do
    path = golden_path(name)

    case File.read(path) do
      {:ok, contents} ->
        Jason.decode!(contents)

      {:error, reason} ->
        flunk("""
        could not read the golden fixture #{name} (#{inspect(reason)}) at
        #{path}

        These are produced by the Go translators:
          UPDATE_DISCOVERY_GOLDEN=1 go test ./go/pkg/agent/netprobe/ -run TestDiscoveryGolden
        """)
    end
  end

  defp assert_parity(name, decoded) do
    golden = golden!(name)
    {:ok, rows, stats} = decoded

    expected_devices = golden["devices"] || []

    assert length(rows) == length(expected_devices),
           "#{name}: Go emitted #{length(expected_devices)} device(s), Elixir emitted #{length(rows)}"

    expected_devices
    |> Enum.zip(rows)
    |> Enum.with_index()
    |> Enum.each(fn {{want_device, got_row}, index} ->
      want = Map.drop(want_device["metadata"] || %{}, @stamped_by_core)
      got = got_row["metadata"]

      assert want |> Map.keys() |> Enum.sort() == got |> Map.keys() |> Enum.sort(),
             """
             #{name} device #{index}: metadata KEYS differ.
               only in Go     : #{inspect(Map.keys(want) -- Map.keys(got))}
               only in Elixir : #{inspect(Map.keys(got) -- Map.keys(want))}
             """

      for {key, want_value} <- want do
        assert got[key] == want_value,
               "#{name} device #{index}: #{key} = #{inspect(got[key])}, Go produced #{inspect(want_value)}"
      end

      # The census carries an IP; mDNS deliberately does not carry the key at
      # all, and the Go fixture records that as an empty string on the device.
      if Map.has_key?(got_row, "ip") do
        assert got_row["ip"] == want_device["ip"],
               "#{name} device #{index}: ip = #{inspect(got_row["ip"])}, Go produced #{inspect(want_device["ip"])}"
      end

      assert got_row["mac"] == want_device["mac"]
    end)

    for {key, want_count} <- golden["stats"] || %{} do
      stat_key = String.to_existing_atom(key)

      if Map.has_key?(stats, stat_key) do
        assert stats[stat_key] == want_count,
               "#{name}: stat #{key} = #{stats[stat_key]}, Go counted #{want_count}"
      end
    end
  end

  defp census(observations) do
    %DeviceCensusSnapshot{
      observations: observations,
      snapshot_id: @census_snapshot_id,
      interface_name: "ens18",
      generated_at_unix_nano: @last_seen,
      complete: true,
      chunk_count: 1
    }
    |> DeviceCensusSnapshot.encode()
    |> Decoders.Census.decode()
  end

  defp obs(fields) do
    struct!(
      %DeviceCensusObservation{
        interface_index: 2,
        first_seen_unix_nano: @first_seen,
        last_seen_unix_nano: @last_seen
      },
      fields
    )
  end

  defp mdns(devices) do
    %MdnsSnapshot{
      devices: devices,
      snapshot_id: @mdns_snapshot_id,
      interface_name: "ens18",
      generated_at_unix_nano: @last_seen,
      complete: true,
      chunk_count: 1
    }
    |> MdnsSnapshot.encode()
    |> Decoders.Mdns.decode()
  end

  defp device(fields) do
    struct!(
      %MdnsDevice{
        interface_index: 2,
        first_seen_unix_nano: @first_seen,
        last_seen_unix_nano: @last_seen
      },
      fields
    )
  end

  describe "census parity with the Go translator" do
    test "arp_reply_ipv4" do
      assert_parity(
        "census_arp_reply_ipv4",
        census([
          obs(
            mac: "a8:bb:cc:00:00:01",
            ip: "192.168.1.10",
            kind: :DEVICE_CENSUS_KIND_ARP_REPLY
          )
        ])
      )
    end

    test "ipv6_ndp_link_local_and_global" do
      assert_parity(
        "census_ipv6_ndp_link_local_and_global",
        census([
          obs(
            mac: "a8:bb:cc:00:00:02",
            ip: "fe80::aabb:ccff:fe00:0002",
            kind: :DEVICE_CENSUS_KIND_IPV6_NDP
          ),
          obs(
            mac: "a8:bb:cc:00:00:02",
            ip: "2001:db8:85a3::8a2e:370:7334",
            kind: :DEVICE_CENSUS_KIND_IPV6_NDP
          )
        ])
      )
    end

    test "arp_probe_addressless" do
      assert_parity(
        "census_arp_probe_addressless",
        census([
          obs(mac: "a8:bb:cc:00:00:03", ip: "", kind: :DEVICE_CENSUS_KIND_ARP_REQUEST)
        ])
      )
    end

    test "randomized_mac" do
      assert_parity(
        "census_randomized_mac",
        census([
          obs(
            mac: "aa:bb:cc:00:00:04",
            ip: "192.168.1.11",
            kind: :DEVICE_CENSUS_KIND_ARP_REPLY,
            randomized_mac: true
          )
        ])
      )
    end

    test "randomized_flag_not_derived_from_mac" do
      assert_parity(
        "census_randomized_flag_not_derived_from_mac",
        census([
          obs(mac: "aa:bb:cc:00:00:06", ip: "192.168.1.13", kind: :DEVICE_CENSUS_KIND_ARP_REPLY)
        ])
      )
    end

    test "off_segment" do
      assert_parity(
        "census_off_segment",
        census([
          obs(
            mac: "a8:bb:cc:00:00:05",
            ip: "203.0.113.7",
            kind: :DEVICE_CENSUS_KIND_ARP_REPLY,
            off_segment: true
          )
        ])
      )
    end

    test "no_mac" do
      assert_parity(
        "census_no_mac",
        census([obs(mac: "   ", ip: "192.168.1.12", kind: :DEVICE_CENSUS_KIND_ARP_REPLY)])
      )
    end
  end

  describe "mdns parity with the Go translator" do
    test "single_model" do
      assert_parity(
        "mdns_single_model",
        mdns([
          device(
            mac: "a8:bb:cc:00:01:01",
            service_types: ["_airplay._tcp", "_raop._tcp"],
            models: ["SyntheticTV1,1"]
          )
        ])
      )
    end

    test "ambiguous_model" do
      assert_parity(
        "mdns_ambiguous_model",
        mdns([
          device(
            mac: "a8:bb:cc:00:01:02",
            service_types: ["_airplay._tcp"],
            models: ["SyntheticSpeaker5,1", "SyntheticTV6,2"],
            ambiguous_model: true
          )
        ])
      )
    end

    test "txt_tristate" do
      assert_parity(
        "mdns_txt_tristate",
        mdns([
          device(
            mac: "a8:bb:cc:00:01:03",
            service_types: ["_ipp._tcp"],
            txt: [
              %MdnsTxtPair{key: "md", value: "", has_value: false},
              %MdnsTxtPair{key: "am", value: "", has_value: true},
              %MdnsTxtPair{key: "ty", value: "synthetic printer", has_value: true}
            ]
          )
        ])
      )
    end

    test "no_evidence" do
      assert_parity("mdns_no_evidence", mdns([device(mac: "a8:bb:cc:00:01:04")]))
    end

    test "truncated" do
      assert_parity(
        "mdns_truncated",
        mdns([
          device(
            mac: "a8:bb:cc:00:01:05",
            service_types: ["_ipp._tcp", "_matter._tcp"],
            truncated: true
          )
        ])
      )
    end

    test "no_mac" do
      assert_parity(
        "mdns_no_mac",
        mdns([
          device(
            mac: "  ",
            service_types: ["_airplay._tcp"],
            first_seen_unix_nano: 0,
            last_seen_unix_nano: 0
          )
        ])
      )
    end

    test "announced_ip_is_not_carried" do
      assert_parity(
        "mdns_announced_ip_is_not_carried",
        mdns([
          device(
            mac: "a8:bb:cc:00:01:06",
            ip: "192.168.1.55",
            service_types: ["_googlecast._tcp"]
          )
        ])
      )
    end
  end
end
