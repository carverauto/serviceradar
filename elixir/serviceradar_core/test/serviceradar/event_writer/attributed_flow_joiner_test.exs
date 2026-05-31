defmodule ServiceRadar.EventWriter.AttributedFlowJoinerTest do
  use ExUnit.Case, async: false

  alias Flowpb.AttributedFlowMessage
  alias Flowpb.FlowMessage
  alias Netprobepb.FlowAttributionEvent
  alias ServiceRadar.EventWriter.AttributedFlowJoiner

  @self_partition "prod-east"

  setup do
    # Ensure the named GenServer is fresh for each test. If it's already
    # running (e.g., from the EventWriter supervisor), stop it so we can boot
    # one with test-scoped opts (in particular, a stub publisher).
    if pid = Process.whereis(AttributedFlowJoiner) do
      GenServer.stop(pid, :normal, 1_000)
    end

    parent = self()

    publisher_fun = fn subject, payload ->
      send(parent, {:published, subject, payload})
      :ok
    end

    {:ok, _pid} =
      AttributedFlowJoiner.start_link(
        ttl_ms: 60_000,
        max_size: 25,
        self_partition_id: @self_partition,
        publisher: {__MODULE__, :stub_publish, [publisher_fun]}
      )

    on_exit(fn ->
      pid = Process.whereis(AttributedFlowJoiner)

      if is_pid(pid) and Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    :ok
  end

  # Adapter to bridge the publisher MFA contract (subject, payload, extra...)
  # to a captured anonymous function used by tests.
  def stub_publish(subject, payload, fun), do: fun.(subject, payload)

  describe "5-tuple join" do
    test "host_slice arrives first, then attribution -> publish on self partition" do
      flow = ipv4_flow(proto: 6, src: "10.0.0.1", sport: 5000, dst: "10.0.0.2", dport: 80)
      host_msg = host_slice_msg(flow, agent_id: "agent-a")

      event =
        attribution_event(local: {"10.0.0.1", 5000}, remote: {"10.0.0.2", 80}, transport: "TCP")

      assert :ok = AttributedFlowJoiner.put_host_slice(host_msg, "agent-a")

      assert {:published, 1} =
               AttributedFlowJoiner.put_attribution(event, "victim-partition",
                 agent_id: "agent-a"
               )

      assert_receive {:published, subject, payload}
      assert subject == "flow.attributed." <> @self_partition

      decoded = AttributedFlowMessage.decode(payload)

      assert %AttributedFlowMessage{event_type: "attributed_flow", partition: @self_partition} =
               decoded

      assert decoded.attribution.pid == event.pid
      assert decoded.attribution.comm == event.comm
      assert decoded.attribution.container_id == event.container_id
      assert decoded.agent_id == "agent-a"
    end

    test "attribution arrives first, then host_slice -> publish on self partition" do
      flow = ipv4_flow(proto: 6, src: "10.0.0.1", sport: 5000, dst: "10.0.0.2", dport: 80)
      host_msg = host_slice_msg(flow, agent_id: "agent-a")

      event =
        attribution_event(local: {"10.0.0.2", 80}, remote: {"10.0.0.1", 5000}, transport: "TCP")

      assert :ok =
               AttributedFlowJoiner.put_attribution(event, @self_partition, agent_id: "agent-a")

      assert {:published, 1} = AttributedFlowJoiner.put_host_slice(host_msg, "agent-a")

      assert_receive {:published, subject, _payload}
      assert subject == "flow.attributed." <> @self_partition
    end

    test "direction-independent canonicalization joins TCP reply flow" do
      # Host-slice records the forward direction; sidecar may see the reply.
      flow = ipv4_flow(proto: 6, src: "10.0.0.1", sport: 5000, dst: "10.0.0.2", dport: 80)
      host_msg = host_slice_msg(flow, agent_id: "agent-a")

      # Attribution swaps local/remote (reply direction)
      event =
        attribution_event(local: {"10.0.0.2", 80}, remote: {"10.0.0.1", 5000}, transport: "TCP")

      AttributedFlowJoiner.put_host_slice(host_msg, "agent-a")
      assert {:published, 1} = AttributedFlowJoiner.put_attribution(event, @self_partition)

      assert_receive {:published, _subject, _payload}
    end
  end

  describe "TTL eviction" do
    test "expired host_slice entry is swept and emits orphan_timeout_drops" do
      attach_telemetry([[:serviceradar, :event_writer, :attributed_flow, :orphan_timeout_drops]])

      flow = ipv4_flow(proto: 6, src: "10.0.0.5", sport: 1000, dst: "10.0.0.6", dport: 22)
      host_msg = host_slice_msg(flow, agent_id: "agent-a")

      # Insert with negative TTL so it is immediately expired.
      assert :ok = AttributedFlowJoiner.put_host_slice(host_msg, "agent-a", ttl_ms: -1)

      send(Process.whereis(AttributedFlowJoiner), :cleanup)
      Process.sleep(50)

      assert_receive {:telemetry,
                      [:serviceradar, :event_writer, :attributed_flow, :orphan_timeout_drops],
                      %{count: 1}, %{kind: :host_slice}}
    end

    test "expired attribution entry is swept" do
      attach_telemetry([[:serviceradar, :event_writer, :attributed_flow, :orphan_timeout_drops]])

      event =
        attribution_event(local: {"10.0.0.7", 1000}, remote: {"10.0.0.8", 22}, transport: "TCP")

      assert :ok = AttributedFlowJoiner.put_attribution(event, @self_partition, ttl_ms: -1)

      send(Process.whereis(AttributedFlowJoiner), :cleanup)
      Process.sleep(50)

      assert_receive {:telemetry,
                      [:serviceradar, :event_writer, :attributed_flow, :orphan_timeout_drops],
                      %{count: 1}, %{kind: :attribution}}
    end
  end

  describe "partition security boundary (B-4)" do
    test "published subject uses self_partition_id, never the agent-claimed partition" do
      flow = ipv4_flow(proto: 6, src: "10.1.0.1", sport: 9000, dst: "10.1.0.2", dport: 443)
      host_msg = host_slice_msg(flow, agent_id: "agent-x", partition_claim: "tenant-evil")

      event =
        attribution_event(local: {"10.1.0.1", 9000}, remote: {"10.1.0.2", 443}, transport: "TCP")

      AttributedFlowJoiner.put_host_slice(host_msg, "agent-x")

      # Agent-claimed partition_id ("tenant-evil") is deliberately wrong; the
      # server's self_partition_id must override.
      assert {:published, 1} =
               AttributedFlowJoiner.put_attribution(event, "tenant-evil", agent_id: "agent-x")

      assert_receive {:published, subject, payload}
      assert subject == "flow.attributed.prod-east"

      decoded = AttributedFlowMessage.decode(payload)
      assert decoded.partition == "prod-east"
      refute decoded.partition == "tenant-evil"
    end
  end

  # Helpers

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
      packets: 7
    }
  end

  defp host_slice_msg(%FlowMessage{} = flow, opts) do
    %AttributedFlowMessage{
      event_type: "attributed_flow",
      flow: flow,
      attribution: nil,
      agent_id: Keyword.get(opts, :agent_id, ""),
      partition: Keyword.get(opts, :partition_claim, "")
    }
  end

  defp attribution_event(opts) do
    {local_ip, local_port} = Keyword.fetch!(opts, :local)
    {remote_ip, remote_port} = Keyword.fetch!(opts, :remote)

    %FlowAttributionEvent{
      local_ip: local_ip,
      local_port: local_port,
      remote_ip: remote_ip,
      remote_port: remote_port,
      transport_protocol: Keyword.get(opts, :transport, "TCP"),
      pid: 12_345,
      uid: 1000,
      comm: "curl",
      redacted_cmdline: ["curl", "https://example.com"],
      container_id: "containerd://abc123",
      observed_at_unix_nano: 1_700_000_000_000_000_000
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

    :telemetry.attach_many(
      "joiner-test-#{inspect(ref)}",
      events,
      fn name, measurements, metadata, _config ->
        send(parent, {:telemetry, name, measurements, metadata})
      end,
      nil
    )

    on_exit_event_handler("joiner-test-#{inspect(ref)}")
  end

  defp on_exit_event_handler(handler_id) do
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
