defmodule ServiceRadar.Integration.FlowAttributionJoinIntegrationTest do
  @moduledoc """
  End-to-end integration coverage for the Option-A FlowAttributionEvent
  join pipeline.

  This test verifies the full producer-to-publisher chain inside core-elx:

      Agent ─► GatewayServiceStatus{source: "flow-attribution",
                                    message: FlowAttributionEventBatch}
              │
              ▼
        ServiceRadar.StatusHandler ──► AttributedFlowJoiner.put_attribution
              │
              ▼
        host_slice FlowMessage ────► AttributedFlowJoiner.put_host_slice
              │
              ▼
        Fake NATS publisher captures `flow.attributed.<P>`
                                     ▲
                                     │
                          P = CORE's self_partition_id (cert-derived,
                                     never the agent claim)

  Scope:

    * Boots `ServiceRadar.EventWriter.AttributedFlowJoiner` (the real ETS
      cache) with an injected publisher MFA that captures published
      messages instead of touching NATS.
    * Drives `ServiceRadar.StatusHandler` through its public GenServer
      cast API — exactly the path `agent_gateway` uses on receive — with
      a real `FlowAttributionEventBatch` carried inside a
      `Monitoring.GatewayServiceStatus` envelope.
    * Asserts the *published* `flow.attributed.<P>` subject keys off
      the core's `self_partition_id`, **never** off any partition value
      sourced from the agent payload (the B-4 spoof defeater).
    * Tagged `:integration` per existing conventions
      (`netflow_ingestion_integration_test.exs`).

  This test does NOT modify production code; it only exercises modules
  that already exist (`AttributedFlowJoiner`, `StatusHandler`,
  `FlowAttributionEventBatch`, `AttributedFlowMessage`).
  """

  use ExUnit.Case, async: false

  alias Flowpb.AttributedFlowMessage
  alias Flowpb.FlowMessage
  alias Netprobepb.FlowAttributionEvent
  alias Netprobepb.FlowAttributionEventBatch
  alias ServiceRadar.EventWriter.AttributedFlowJoiner
  alias ServiceRadar.StatusHandler

  @moduletag :integration
  @moduletag timeout: 60_000

  @self_partition "prod-east-core"
  @agent_id "agent-host-01"

  # --- shared setup -----------------------------------------------------

  setup context do
    parent = self()

    # Stop any pre-existing joiner so we can boot one with our injected
    # publisher and test-scoped self_partition_id.
    if pid = Process.whereis(AttributedFlowJoiner) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end

    {:ok, _joiner} =
      AttributedFlowJoiner.start_link(
        ttl_ms: 60_000,
        max_size: 1_000,
        self_partition_id: @self_partition,
        publisher: {__MODULE__, :capture_publish, [parent]}
      )

    # Boot the real StatusHandler too if it's not already up — the test
    # exercises its public cast API just like the agent-gateway does.
    case Process.whereis(StatusHandler) do
      nil ->
        {:ok, _} = StatusHandler.start_link([])

      _pid ->
        :ok
    end

    on_exit(fn ->
      stop_named(AttributedFlowJoiner)

      # Only stop a StatusHandler we started. We leave any pre-existing
      # StatusHandler (e.g., booted by the application supervisor) alone.
      if context[:owns_status_handler] do
        stop_named(StatusHandler)
      end
    end)

    :ok
  end

  # Captures published `flow.attributed.*` messages onto the test process
  # mailbox. The MFA contract is `apply(mod, fun, [subject, payload | extra])`
  # so the parent pid arrives as the third positional argument.
  def capture_publish(subject, payload, parent_pid) do
    send(parent_pid, {:nats_published, subject, payload})
    :ok
  end

  # --- main scenarios ---------------------------------------------------

  describe "end-to-end join via StatusHandler (Option A)" do
    test "host-slice + FlowAttributionEventBatch publishes on CORE's self_partition_id" do
      # 1. The host-slice flow record (what NATS subject
      #    `flow.host-slice.<agent_id>` would carry — the agent's
      #    flow-collector publishes these).
      flow = ipv4_flow(proto: 6, src: "10.0.0.1", sport: 5000, dst: "10.0.0.2", dport: 80)
      host_msg = host_slice_attributed_message(flow, agent_id: @agent_id)

      # 2. Insert the host_slice side into the joiner first — simulates
      #    the typical race where flow arrives before attribution.
      assert :ok = AttributedFlowJoiner.put_host_slice(host_msg, @agent_id)

      # 3. The agent's FlowAttributionEvent batch arrives via the
      #    StatusHandler cast API (the production receive path used by
      #    serviceradar_agent_gateway/status_processor.ex).
      event =
        flow_attribution_event(
          local: {"10.0.0.1", 5000},
          remote: {"10.0.0.2", 80},
          transport: "TCP",
          pid: 4242,
          comm: "curl",
          container_id: "containerd://abc123"
        )

      status = build_flow_attribution_status([event], @self_partition, @agent_id)

      assert :ok = GenServer.cast(StatusHandler, {:status_update, status})

      # 4. Assert the merged AttributedFlowMessage is published on the
      #    *core*'s partition subject.
      assert_receive {:nats_published, subject, payload}, 1_000

      assert subject == "flow.attributed." <> @self_partition,
             "expected publish on core's self_partition_id, got #{inspect(subject)}"

      decoded = AttributedFlowMessage.decode(payload)
      assert %AttributedFlowMessage{} = decoded
      assert decoded.event_type == "attributed_flow"
      assert decoded.partition == @self_partition
      assert decoded.agent_id == @agent_id
      assert decoded.flow.src_port == 5000
      assert decoded.flow.dst_port == 80
      assert decoded.attribution.pid == 4242
      assert decoded.attribution.comm == "curl"
      assert decoded.attribution.container_id == "containerd://abc123"
    end

    test "batch with empty events emits telemetry without publishing" do
      attach_telemetry([
        [:serviceradar, :event_writer, :attributed_flow, :batch_received]
      ])

      status = build_flow_attribution_status([], @self_partition, @agent_id)
      assert :ok = GenServer.cast(StatusHandler, {:status_update, status})

      assert_receive {:telemetry,
                      [:serviceradar, :event_writer, :attributed_flow, :batch_received],
                      %{count: 1, event_count: 0}, _meta},
                     1_000

      refute_receive {:nats_published, _subject, _payload}, 200
    end

    test "malformed FlowAttributionEventBatch is dropped without crashing" do
      attach_telemetry([
        [:serviceradar, :event_writer, :attributed_flow, :batch_decode_failed]
      ])

      bad_status = %{
        service_name: "flow-attribution",
        service_type: "passive-netprobe",
        source: "flow-attribution",
        agent_id: @agent_id,
        partition: @self_partition,
        message: <<0xFF, 0xFF, 0xFF, 0xFF>>
      }

      assert :ok = GenServer.cast(StatusHandler, {:status_update, bad_status})

      # decode_failed telemetry fires; no publish.
      assert_receive {:telemetry,
                      [:serviceradar, :event_writer, :attributed_flow, :batch_decode_failed],
                      %{count: 1}, _meta},
                     1_000

      refute_receive {:nats_published, _subject, _payload}, 200

      # StatusHandler stays alive
      assert Process.alive?(Process.whereis(StatusHandler))
    end
  end

  describe "B-4 spoof defeater" do
    test "agent-claimed partition_id is dropped: publish uses self_partition_id" do
      # A compromised agent sends a FlowAttributionEvent batch claiming
      # its records belong to partition "victim-tenant". The StatusHandler
      # would forward `status[:partition]` to put_attribution as
      # `partition_id`. Crucially, the published `flow.attributed.<P>`
      # subject is keyed off the joiner's `self_partition_id`, not off
      # `partition_id` — see attributed_flow_joiner.ex merge_and_publish.
      flow = ipv4_flow(proto: 6, src: "10.1.0.1", sport: 9000, dst: "10.1.0.2", dport: 443)
      host_msg = host_slice_attributed_message(flow, agent_id: "compromised-agent")

      assert :ok = AttributedFlowJoiner.put_host_slice(host_msg, "compromised-agent")

      event =
        flow_attribution_event(
          local: {"10.1.0.1", 9000},
          remote: {"10.1.0.2", 443},
          transport: "TCP",
          pid: 7777,
          comm: "evil",
          container_id: "containerd://evil0"
        )

      # The agent claims a different partition.
      claimed_partition = "victim-tenant"
      status = build_flow_attribution_status([event], claimed_partition, "compromised-agent")

      assert :ok = GenServer.cast(StatusHandler, {:status_update, status})

      assert_receive {:nats_published, subject, payload}, 1_000

      # The published subject MUST be the core's self_partition_id, not
      # the agent's claim. This is the B-4 boundary.
      assert subject == "flow.attributed." <> @self_partition,
             "B-4 defeater failed: published #{inspect(subject)}, expected suffix #{@self_partition}"

      refute subject =~ claimed_partition,
             "B-4 defeater failed: subject contains agent-claimed partition #{inspect(claimed_partition)}"

      decoded = AttributedFlowMessage.decode(payload)
      assert decoded.partition == @self_partition

      refute decoded.partition == claimed_partition,
             "B-4 defeater failed: published partition #{inspect(decoded.partition)} matches the agent claim"
    end

    test "host_slice partition_claim does not leak into the published subject" do
      # A complementary path: an attacker who can publish to
      # flow.host-slice.<agent_id> stamps a malicious `partition` field
      # onto the AttributedFlowMessage envelope itself. The joiner must
      # ignore that value and use its self_partition_id at publish time.
      flow = ipv4_flow(proto: 6, src: "172.16.0.1", sport: 12_345, dst: "172.16.0.2", dport: 8080)

      poisoned_host =
        host_slice_attributed_message(flow,
          agent_id: "attacker-agent",
          partition_claim: "exfil-tenant"
        )

      assert :ok = AttributedFlowJoiner.put_host_slice(poisoned_host, "attacker-agent")

      event =
        flow_attribution_event(
          local: {"172.16.0.1", 12_345},
          remote: {"172.16.0.2", 8080},
          transport: "TCP",
          pid: 8888,
          comm: "bash"
        )

      status = build_flow_attribution_status([event], "exfil-tenant", "attacker-agent")
      assert :ok = GenServer.cast(StatusHandler, {:status_update, status})

      assert_receive {:nats_published, subject, payload}, 1_000

      assert subject == "flow.attributed." <> @self_partition
      refute subject =~ "exfil-tenant"

      decoded = AttributedFlowMessage.decode(payload)
      assert decoded.partition == @self_partition
      refute decoded.partition == "exfil-tenant"
    end
  end

  describe "batch fan-out semantics" do
    test "multi-event batch joins each event independently" do
      # Three host-slice flows, three attribution events. Each pair must
      # produce its own published message on self_partition_id.
      pairs = [
        {ipv4_flow(proto: 6, src: "10.0.0.1", sport: 5001, dst: "8.8.8.8", dport: 443),
         flow_attribution_event(
           local: {"10.0.0.1", 5001},
           remote: {"8.8.8.8", 443},
           transport: "TCP",
           pid: 1001
         )},
        {ipv4_flow(proto: 6, src: "10.0.0.1", sport: 5002, dst: "1.1.1.1", dport: 53),
         flow_attribution_event(
           local: {"10.0.0.1", 5002},
           remote: {"1.1.1.1", 53},
           transport: "TCP",
           pid: 1002
         )},
        {ipv4_flow(proto: 6, src: "10.0.0.1", sport: 5003, dst: "192.0.2.10", dport: 80),
         flow_attribution_event(
           local: {"10.0.0.1", 5003},
           remote: {"192.0.2.10", 80},
           transport: "TCP",
           pid: 1003
         )}
      ]

      # Seed all host-slice records first.
      Enum.each(pairs, fn {flow, _event} ->
        host_msg = host_slice_attributed_message(flow, agent_id: @agent_id)
        assert :ok = AttributedFlowJoiner.put_host_slice(host_msg, @agent_id)
      end)

      # Now ship a single batch containing all three attribution events.
      events = Enum.map(pairs, fn {_flow, event} -> event end)
      status = build_flow_attribution_status(events, @self_partition, @agent_id)
      assert :ok = GenServer.cast(StatusHandler, {:status_update, status})

      # We should see three publishes, all on self_partition.
      pids_published =
        for _ <- 1..length(pairs) do
          assert_receive {:nats_published, subject, payload}, 1_000
          assert subject == "flow.attributed." <> @self_partition
          AttributedFlowMessage.decode(payload).attribution.pid
        end

      assert Enum.sort(pids_published) == [1001, 1002, 1003]
    end
  end

  # --- helpers ----------------------------------------------------------

  defp build_flow_attribution_status(events, partition, agent_id) do
    batch = %FlowAttributionEventBatch{
      events: events,
      batch_start_unix_nano: System.system_time(:nanosecond) - 1_000_000_000,
      batch_end_unix_nano: System.system_time(:nanosecond),
      dropped_since_last: 0
    }

    %{
      service_name: "flow-attribution",
      service_type: "passive-netprobe",
      source: "flow-attribution",
      agent_id: agent_id,
      partition: partition,
      message: FlowAttributionEventBatch.encode(batch)
    }
  end

  defp ipv4_flow(opts) do
    [a1, a2, a3, a4] = ip_octets(Keyword.fetch!(opts, :src))
    [b1, b2, b3, b4] = ip_octets(Keyword.fetch!(opts, :dst))

    %FlowMessage{
      proto: Keyword.fetch!(opts, :proto),
      src_addr: <<a1, a2, a3, a4>>,
      dst_addr: <<b1, b2, b3, b4>>,
      src_port: Keyword.fetch!(opts, :sport),
      dst_port: Keyword.fetch!(opts, :dport),
      bytes: 1234,
      packets: 7,
      time_received_ns: System.system_time(:nanosecond)
    }
  end

  defp host_slice_attributed_message(%FlowMessage{} = flow, opts) do
    %AttributedFlowMessage{
      event_type: "host_slice_flow",
      flow: flow,
      attribution: nil,
      agent_id: Keyword.get(opts, :agent_id, ""),
      partition: Keyword.get(opts, :partition_claim, "")
    }
  end

  defp flow_attribution_event(opts) do
    {local_ip, local_port} = Keyword.fetch!(opts, :local)
    {remote_ip, remote_port} = Keyword.fetch!(opts, :remote)

    %FlowAttributionEvent{
      local_ip: local_ip,
      local_port: local_port,
      remote_ip: remote_ip,
      remote_port: remote_port,
      transport_protocol: Keyword.get(opts, :transport, "TCP"),
      pid: Keyword.get(opts, :pid, 1234),
      tgid: Keyword.get(opts, :pid, 1234),
      uid: 1000,
      gid: 1000,
      comm: Keyword.get(opts, :comm, "test-proc"),
      redacted_cmdline: ["test-proc", "[REDACTED]"],
      container_id: Keyword.get(opts, :container_id, ""),
      observed_at_unix_nano: System.system_time(:nanosecond),
      event_kind: 1,
      source: "ebpf"
    }
  end

  defp ip_octets(ip) when is_binary(ip) do
    ip
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
  end

  defp attach_telemetry(events) do
    parent = self()
    ref = make_ref()
    handler_id = "flow-attr-integration-#{inspect(ref)}"

    :telemetry.attach_many(
      handler_id,
      events,
      fn name, measurements, metadata, _config ->
        send(parent, {:telemetry, name, measurements, metadata})
      end,
      nil
    )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp stop_named(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end

      _ ->
        :ok
    end
  end
end
