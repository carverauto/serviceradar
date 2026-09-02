defmodule ServiceRadar.Inventory.Discovery.EnrichmentParityTest do
  @moduledoc """
  The fingerprint/DPI/process decoders must produce what the Go translators
  produce.

  The fixtures in `go/pkg/agent/netprobe/testdata/enrichment_golden/` were
  captured from the REAL Go translators before any of this existed, so that after
  the Go code is deleted there is still something to compare against.

  ## What is compared, and what is not

  Every metadata key except the ones core stamps itself: `agent_id`,
  `gateway_id`, `partition`, `source`, `discovery_source` and `identity_source`
  come from gateway-attested status metadata and the schema registry, never from
  a payload. Expecting a decoder to invent "agent-synthetic-1" would be asserting
  the wrong thing -- and a decoder that COULD would let an add-on claim to be a
  different agent.

  `_alias_collector_ip` is excluded for a different reason, and it is a
  deliberate behaviour change rather than a stamping detail: the Go translator
  wrote it from its own options, and core has no attested collector address to
  put there. It only ever produced a `:collector_ip` alias row, a non-identity
  type no identity reader consults, and the attested `agent_id` identifies the
  collector more precisely than an address that can change.
  """
  use ExUnit.Case, async: true

  alias Serviceradar.Agent.Netprobe.V1.DpiEvent
  alias Serviceradar.Agent.Netprobe.V1.DpiEventBatch
  alias Serviceradar.Agent.Netprobe.V1.FingerprintEvent
  alias Serviceradar.Agent.Netprobe.V1.FingerprintEventBatch
  alias Serviceradar.Agent.Netprobe.V1.HttpFingerprint
  alias Serviceradar.Agent.Netprobe.V1.LicenseCleanFingerprint
  alias Serviceradar.Agent.Netprobe.V1.OsMatch
  alias Serviceradar.Agent.Netprobe.V1.ProcessSnapshot
  alias Serviceradar.Agent.Netprobe.V1.ProcessSnapshotBatch
  alias Serviceradar.Agent.Netprobe.V1.ProcessSnapshotEntry
  alias Serviceradar.Agent.Netprobe.V1.RecogFingerprintMatch
  alias Serviceradar.Agent.Netprobe.V1.TcpFingerprint
  alias Serviceradar.Agent.Netprobe.V1.TlsFingerprint
  alias ServiceRadar.Inventory.Discovery.Decoders

  @stamped_by_core ~w(agent_id gateway_id partition source identity_source discovery_source)
  @not_reproducible ~w(_alias_collector_ip)
  @observed_at 1_787_500_000_000_000_000

  defp golden!(name) do
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
      "enrichment_golden",
      name <> ".json"
    ]
    |> Path.join()
    |> Path.expand()
    |> File.read!()
    |> Jason.decode!()
  end

  defp comparable(metadata) do
    Map.drop(metadata, @stamped_by_core ++ @not_reproducible)
  end

  defp assert_parity(name, observation) do
    golden = golden!(name)

    assert observation["ip"] == golden["ip"], "subject address diverged for #{name}"

    assert comparable(observation["metadata"]) == comparable(golden["metadata"]),
           "metadata diverged from the Go translator for #{name}"
  end

  defp decode_fingerprint!(event) do
    payload = FingerprintEventBatch.encode(%FingerprintEventBatch{events: [event]})
    assert {:ok, [observation], _stats} = Decoders.Fingerprint.decode(payload)
    observation
  end

  defp decode_dpi!(event) do
    assert {:ok, [observation], _stats} = decode_dpi_batch([event], [])
    observation
  end

  defp decode_dpi_batch(events, subject_ips) do
    Decoders.Dpi.decode(
      DpiEventBatch.encode(%DpiEventBatch{events: events, subject_ips: subject_ips})
    )
  end

  describe "fingerprint" do
    test "tcp passive, every evidence key present" do
      event = %FingerprintEvent{
        ip: "10.20.30.41",
        profile_id: "linux-hosts",
        interface_name: "eth0",
        observed_at_unix_nano: @observed_at,
        evidence:
          {:tcp,
           %TcpFingerprint{
             signature: "64240:64:1:60:M1460,S,T,N,W7",
             os_family: "linux",
             os_name: "Linux 5.x",
             confidence: 0.86,
             ttl: 64,
             mss: 1460,
             window_size: "64240",
             window_scale: 7,
             ip_version: "4",
             payload_class: "syn",
             options_layout: ["mss", "sok", "ts"],
             quirks: ["df"]
           }}
      }

      assert_parity("fingerprint_tcp_passive_full", decode_fingerprint!(event))
    end

    test "sweep-active switches source AND prefix, and suppresses the sentinel profile_id" do
      event = %FingerprintEvent{
        ip: "10.20.30.42",
        profile_id: "sweep_active",
        observed_at_unix_nano: @observed_at,
        evidence: {:tcp, %TcpFingerprint{signature: "s", os_family: "linux", confidence: 0.5}}
      }

      observation = decode_fingerprint!(event)
      assert_parity("fingerprint_tcp_sweep_active", observation)

      assert observation["metadata"]["active_fingerprint.source"] == "sweep_active"
      refute Map.has_key?(observation["metadata"], "active_fingerprint.profile_id")
    end

    test "zero observed_at drops the timestamp keys and empties ip_alias" do
      event = %FingerprintEvent{
        ip: "10.20.30.43",
        evidence: {:tcp, %TcpFingerprint{signature: "s"}}
      }

      observation = decode_fingerprint!(event)
      assert_parity("fingerprint_tcp_no_observed_at", observation)
      assert observation["metadata"]["ip_alias:10.20.30.43"] == ""
    end

    test "tls never emits a real SNI" do
      event = %FingerprintEvent{
        ip: "10.20.30.44",
        observed_at_unix_nano: @observed_at,
        evidence:
          {:tls,
           %TlsFingerprint{
             ja4: "t13d1516h2_synthetic",
             ja4s: "t130200_synthetic",
             sni_redacted: "not-a-real-host"
           }}
      }

      observation = decode_fingerprint!(event)
      assert_parity("fingerprint_tls_sni_redaction", observation)
      assert observation["metadata"]["passive_fingerprint.tls.sni_redacted"] == "<present>"
    end

    test "http" do
      event = %FingerprintEvent{
        ip: "10.20.30.45",
        observed_at_unix_nano: @observed_at,
        evidence:
          {:http,
           %HttpFingerprint{
             user_agent: "synthetic-agent/1.0",
             server: "synthetic-server/2.0",
             accept_language: "en"
           }}
      }

      assert_parity("fingerprint_http_headers", decode_fingerprint!(event))
    end

    test "license_clean with os match and recog products" do
      event = %FingerprintEvent{
        ip: "10.20.30.46",
        observed_at_unix_nano: @observed_at,
        evidence:
          {:license_clean,
           %LicenseCleanFingerprint{
             os_match: %OsMatch{
               name: "Synthetic OS",
               version_range: "1.x",
               os_family: "synthetic",
               confidence: 0.75
             },
             recog_http: %RecogFingerprintMatch{
               product: "synthetic-httpd",
               version: "1.2",
               os_family: "synthetic"
             },
             recog_ssh: %RecogFingerprintMatch{product: "synthetic-sshd", version: "9.9"}
           }}
      }

      assert_parity("fingerprint_license_clean_with_os_and_recog", decode_fingerprint!(event))
    end

    test "an evidence-free license_clean still observes, with the protocol key and no detail" do
      # This is the shape an evidence-free arm takes ON THE WIRE. Go's in-memory
      # nil inner pointer cannot be encoded -- it round-trips back as an empty
      # message -- so the fixture pins the empty one, which is what a decoder
      # will actually meet.
      event = %FingerprintEvent{
        ip: "10.20.30.47",
        observed_at_unix_nano: @observed_at,
        evidence: {:license_clean, %LicenseCleanFingerprint{}}
      }

      observation = decode_fingerprint!(event)
      assert_parity("fingerprint_license_clean_empty_inner", observation)

      assert observation["metadata"]["passive_fingerprint.protocol"] == "license_clean"

      refute Enum.any?(Map.keys(observation["metadata"]), &String.contains?(&1, ".recog.")),
             "an empty license_clean must not invent recog keys"
    end

    test "the skip rules survived the port" do
      no_ip =
        FingerprintEventBatch.encode(%FingerprintEventBatch{
          events: [%FingerprintEvent{ip: "  "}]
        })

      assert {:ok, [], stats} = Decoders.Fingerprint.decode(no_ip)
      assert stats.skipped_no_ip == 1

      no_evidence =
        FingerprintEventBatch.encode(%FingerprintEventBatch{
          events: [%FingerprintEvent{ip: "10.20.30.48"}]
        })

      assert {:ok, [], stats} = Decoders.Fingerprint.decode(no_evidence)
      assert stats.skipped_no_evidence == 1
    end
  end

  describe "dpi" do
    test "source endpoint wins when the collector is not involved" do
      event = %DpiEvent{
        protocol: "tls",
        source_ip: "10.20.30.61",
        destination_ip: "10.20.30.62",
        observed_at_unix_nano: @observed_at
      }

      assert_parity("dpi_collector_is_neither_source_wins", decode_dpi!(event))
    end

    test "destination wins when there is no source" do
      event = %DpiEvent{
        protocol: "http",
        destination_ip: "10.20.30.63",
        observed_at_unix_nano: @observed_at
      }

      assert_parity("dpi_no_source_destination_wins", decode_dpi!(event))
    end

    test "collector-as-source agrees with Go because source is preferred anyway" do
      event = %DpiEvent{
        protocol: "dns",
        source_ip: "10.20.30.40",
        destination_ip: "10.20.30.60",
        interface_name: "eth0",
        observed_at_unix_nano: @observed_at
      }

      assert_parity("dpi_collector_is_endpoint", decode_dpi!(event))
    end

    test "the subject netprobe chose wins over core's source-first fallback" do
      # Go prefers the collector when it is EITHER endpoint. Core cannot: it has
      # no attested collector address and can only prefer source. So netprobe
      # makes the choice and sends it in `subject_ips`, and this asserts core
      # honours it -- including the destination case, which is the whole reason
      # the choice moved to the producer.
      event = %DpiEvent{
        protocol: "tls",
        source_ip: "10.20.30.65",
        destination_ip: "10.20.30.40",
        observed_at_unix_nano: @observed_at
      }

      payload =
        DpiEventBatch.encode(%DpiEventBatch{events: [event], subject_ips: ["10.20.30.40"]})

      assert {:ok, [observation], _stats} = Decoders.Dpi.decode(payload)

      golden = golden!("dpi_collector_is_destination")
      assert observation["ip"] == golden["ip"], "core must land on the endpoint Go chose"
      assert_parity("dpi_collector_is_destination", observation)
    end

    test "an absent subject falls back to source, which is wrong when the collector was destination" do
      # The fallback exists for a producer too old to send a subject. It is
      # asserted so the cost of that path is visible rather than assumed benign:
      # it picks the peer, not the collector.
      event = %DpiEvent{
        protocol: "tls",
        source_ip: "10.20.30.65",
        destination_ip: "10.20.30.40",
        observed_at_unix_nano: @observed_at
      }

      assert {:ok, [observation], _stats} = decode_dpi_batch([event], [])

      assert observation["ip"] == "10.20.30.65",
             "without a producer-chosen subject core can only prefer source"
    end

    test "the skip rules survived the port" do
      no_protocol =
        DpiEventBatch.encode(%DpiEventBatch{events: [%DpiEvent{source_ip: "10.20.30.64"}]})

      assert {:ok, [], stats} = Decoders.Dpi.decode(no_protocol)
      assert stats.skipped_no_protocol == 1

      no_ip = DpiEventBatch.encode(%DpiEventBatch{events: [%DpiEvent{protocol: "dns"}]})
      assert {:ok, [], stats} = Decoders.Dpi.decode(no_ip)
      assert stats.skipped_no_ip == 1
    end
  end

  describe "process snapshot" do
    test "summary scalars match the Go translator" do
      snapshot = %ProcessSnapshot{
        fingerprint: "synthetic-fingerprint-1",
        observed_at_unix_nano: @observed_at,
        entries: [
          %ProcessSnapshotEntry{
            local_ip: "0.0.0.0",
            local_port: 8080,
            transport_protocol: "tcp",
            pid: 101,
            comm: "synthetic-a"
          },
          %ProcessSnapshotEntry{
            local_ip: "::",
            local_port: 9090,
            transport_protocol: "tcp",
            pid: 102,
            comm: "synthetic-b",
            container_id: "ctr-synthetic-1"
          },
          %ProcessSnapshotEntry{
            local_ip: "0.0.0.0",
            local_port: 53,
            transport_protocol: "udp",
            pid: 103,
            comm: "synthetic-c"
          }
        ]
      }

      payload =
        ProcessSnapshotBatch.encode(%ProcessSnapshotBatch{
          snapshot: snapshot,
          subject_ip: "10.20.30.40"
        })

      assert {:ok, [observation], _stats} = Decoders.Process.decode(payload)

      assert_parity("process_snapshot", observation)
    end

    test "no subject address is a drop, not a guess" do
      # The subject travels IN the payload. It used to be a second argument, which
      # DiscoveryIngestor never passes -- so every snapshot was skipped. This
      # asserts the drop happens only when the payload genuinely carries no
      # subject, not because of how the decoder is called.
      payload =
        ProcessSnapshotBatch.encode(%ProcessSnapshotBatch{
          snapshot: %ProcessSnapshot{fingerprint: "f", observed_at_unix_nano: @observed_at}
        })

      assert {:ok, [], stats} = Decoders.Process.decode(payload)
      assert stats.skipped_no_subject == 1
    end

    test "the decoder the ingestor actually calls is decode/1" do
      # decode_and_enqueue/4 calls entry.decoder.decode(part) with ONE argument.
      # A decoder exporting only decode/2 would raise or, with a default, silently
      # skip everything it was handed.
      # ensure_loaded! first: function_exported?/3 answers false for a module that
      # has not been loaded yet, which makes this pass or fail on test ordering
      # rather than on the thing it is checking.
      Code.ensure_loaded!(Decoders.Process)
      assert function_exported?(Decoders.Process, :decode, 1)
    end
  end
end
