defmodule ServiceRadar.Inventory.DiscoveryIngestorTest do
  @moduledoc """
  The point where an add-on's observations become inventory.

  The hostile cases are the reason this file exists. Everything upstream of here
  treats the payload as opaque bytes, so this is the only place that can refuse
  an add-on's claim about who it is or what source it speaks for.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Serviceradar.Agent.Discovery.V1.DiscoveryEnvelope
  alias Serviceradar.Agent.Netprobe.V1.DeviceCensusObservation
  alias Serviceradar.Agent.Netprobe.V1.DeviceCensusSnapshot
  alias ServiceRadar.Inventory.Discovery.Buffer
  alias ServiceRadar.Inventory.DiscoveryIngestor
  alias ServiceRadar.Inventory.SyncIngestorQueue

  @census_schema "serviceradar.netprobe.census.v1"
  @last_seen 1_700_000_060_000_000_000

  setup do
    # A fresh buffer per test. Watermarks persist by design, so a shared one
    # would let an earlier test's snapshot supersede a later test's -- which is
    # correct behavior and a broken fixture.
    #
    # Both branches are load-bearing, because this file runs in two very
    # different worlds. In the database-free unit tier (the Bazel
    # //elixir/serviceradar_core:unit_tests_* shards) the application is never
    # started -- test_helper.exs says so explicitly -- so nothing owns the
    # default name and the test must start the Buffer itself. In a DB-backed run
    # the application supervisor already owns that name (application.ex), and
    # start_supervised! there dies with {:already_started, ...}, which is what
    # every test in this file did locally.
    #
    # Starting one under a test-local name would fix neither world:
    # DiscoveryIngestor calls Buffer.offer/1 with the DEFAULT name, so the test's
    # instance would never be consulted.
    case Process.whereis(Buffer) do
      nil -> start_supervised!(Buffer)
      _pid -> Buffer.reset()
    end

    parent = self()

    queue =
      spawn(fn ->
        loop = fn loop ->
          receive do
            {:"$gen_cast", {:enqueue, message}} ->
              send(parent, {:enqueued, message})
              loop.(loop)

            _other ->
              loop.(loop)
          end
        end

        loop.(loop)
      end)

    previous = Process.whereis(SyncIngestorQueue)
    if previous, do: Process.unregister(SyncIngestorQueue)
    Process.register(queue, SyncIngestorQueue)

    on_exit(fn ->
      if Process.whereis(SyncIngestorQueue),
        do: Process.unregister(SyncIngestorQueue)

      if previous, do: Process.register(previous, SyncIngestorQueue)
      if Process.alive?(queue), do: Process.exit(queue, :kill)
    end)

    :ok
  end

  defp attested do
    %{
      producer_type: "native-addon",
      producer_id: "netprobe",
      agent_id: "attested-agent",
      gateway_id: "attested-gateway",
      partition_id: "attested-partition"
    }
  end

  defp census_payload(observations) do
    DeviceCensusSnapshot.encode(%DeviceCensusSnapshot{
      observations: observations,
      snapshot_id: "ens18-1700000000-1",
      interface_name: "ens18",
      generated_at_unix_nano: @last_seen,
      complete: true,
      chunk_count: 1
    })
  end

  defp envelope(fields) do
    %DiscoveryEnvelope{
      schema: @census_schema,
      producer_id: "netprobe",
      observation_scope: "ens18",
      snapshot_id: "ens18-1700000000-1",
      part_index: 0,
      part_count: 1,
      complete: true,
      generated_at_unix_nano: @last_seen,
      payload: census_payload([observation()])
    }
    |> struct!(fields)
    |> DiscoveryEnvelope.encode()
  end

  defp observation(fields \\ []) do
    struct!(
      %DeviceCensusObservation{
        mac: "a8:bb:cc:00:00:01",
        ip: "192.168.1.10",
        interface_index: 2,
        kind: :DEVICE_CENSUS_KIND_ARP_REPLY,
        first_seen_unix_nano: 1_700_000_000_000_000_000,
        last_seen_unix_nano: @last_seen
      },
      fields
    )
  end

  defp enqueued! do
    assert_receive {:enqueued, json}, 1_000
    Jason.decode!(json)
  end

  describe "identity is stamped, never taken from the add-on" do
    test "a census snapshot becomes an update carrying the attested identity" do
      assert :ok = DiscoveryIngestor.ingest(envelope([]), attested())

      assert [update] = enqueued!()
      assert update["agent_id"] == "attested-agent"
      assert update["gateway_id"] == "attested-gateway"
      assert update["partition"] == "attested-partition"
      assert update["source"] == "netprobe-census"
      assert update["metadata"]["source"] == "netprobe-census"
      assert update["metadata"]["identity_source"] == "netprobe_census"
      assert update["mac"] == "a8:bb:cc:00:00:01"
    end

    test "an add-on cannot claim a different source" do
      # SourcePolicy keys on `source` to decide whether a MAC may anchor a
      # device and whether the source may create one. An add-on that could pick
      # its own source could pick a weaker guardrail.
      payload =
        DeviceCensusSnapshot.encode(%DeviceCensusSnapshot{
          observations: [observation()],
          snapshot_id: "x",
          interface_name: "ens18",
          complete: true,
          chunk_count: 1
        })

      assert :ok = DiscoveryIngestor.ingest(envelope(payload: payload), attested())

      assert [update] = enqueued!()
      assert update["source"] == "netprobe-census"
      assert update["metadata"]["identity_source"] == "netprobe_census"
    end

    test "an add-on cannot claim a different agent" do
      # producer_id in the envelope is for display and telemetry. It is not an
      # identity claim, and must not become one.
      assert :ok =
               DiscoveryIngestor.ingest(envelope(producer_id: "definitely-not-me"), attested())

      assert [update] = enqueued!()
      assert update["agent_id"] == "attested-agent"
      assert update["metadata"]["agent_id"] == "attested-agent"
    end
  end

  describe "unregistered and malformed payloads" do
    test "an unregistered schema is dropped loudly" do
      log =
        capture_log(fn ->
          assert :ok =
                   DiscoveryIngestor.ingest(
                     envelope(schema: "serviceradar.netprobe.lldp.v1"),
                     attested()
                   )
        end)

      assert log =~ "unregistered schema"
      refute_receive {:enqueued, _}, 200
    end

    test "an undecodable envelope does not raise" do
      assert :ok = DiscoveryIngestor.ingest(<<0xFF, 0xFF, 0xFF, 0xFF>>, attested())
      refute_receive {:enqueued, _}, 200
    end

    test "a decoder rejection is logged and dropped, not enqueued" do
      assert :ok = DiscoveryIngestor.ingest(envelope(payload: <<0xFF, 0xFF>>), attested())
      refute_receive {:enqueued, _}, 200
    end

    test "a snapshot that translated to nothing enqueues nothing" do
      # Every observation skipped: off-segment. Distinguishable in telemetry
      # from a quiet segment, but nothing is written.
      payload = census_payload([observation(off_segment: true)])

      assert :ok = DiscoveryIngestor.ingest(envelope(payload: payload), attested())
      refute_receive {:enqueued, _}, 200
    end
  end

  describe "supersession" do
    test "an older snapshot arriving late does not undo a newer one" do
      # A snapshot REPLACES its scope, so applying an older one after a newer
      # one resurrects devices that have since aged out. Nothing between the
      # producer and here guarantees ordering.
      assert :ok = DiscoveryIngestor.ingest(envelope(generated_at_unix_nano: 200), attested())
      assert [_] = enqueued!()

      assert :ok = DiscoveryIngestor.ingest(envelope(generated_at_unix_nano: 100), attested())
      refute_receive {:enqueued, _}, 200
    end

    test "a different scope is not superseded by another scope's snapshot" do
      assert :ok =
               DiscoveryIngestor.ingest(
                 envelope(observation_scope: "eth0", generated_at_unix_nano: 200),
                 attested()
               )

      assert [_] = enqueued!()

      assert :ok =
               DiscoveryIngestor.ingest(
                 envelope(observation_scope: "eth1", generated_at_unix_nano: 100),
                 attested()
               )

      assert [_] = enqueued!()
    end
  end

  describe "multi-part snapshots" do
    test "parts are held until the set is complete, then ingested together" do
      first =
        envelope(
          part_index: 0,
          part_count: 2,
          complete: false,
          payload: census_payload([observation(mac: "a8:bb:cc:00:00:01")])
        )

      second =
        envelope(
          part_index: 1,
          part_count: 2,
          complete: true,
          payload: census_payload([observation(mac: "a8:bb:cc:00:00:02")])
        )

      assert :ok = DiscoveryIngestor.ingest(first, attested())
      refute_receive {:enqueued, _}, 200

      assert :ok = DiscoveryIngestor.ingest(second, attested())

      updates = enqueued!()
      assert length(updates) == 2
      assert Enum.map(updates, & &1["mac"]) == ["a8:bb:cc:00:00:01", "a8:bb:cc:00:00:02"]
    end

    test "a set whose final part never arrives is never ingested" do
      # Counting parts alone would accept a set that received a duplicate
      # instead of its last part.
      first = envelope(part_index: 0, part_count: 2, complete: false)

      assert :ok = DiscoveryIngestor.ingest(first, attested())
      assert :ok = DiscoveryIngestor.ingest(first, attested())

      refute_receive {:enqueued, _}, 200
    end
  end
end
