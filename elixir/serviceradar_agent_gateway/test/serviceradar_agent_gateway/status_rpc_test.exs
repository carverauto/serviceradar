defmodule ServiceRadarAgentGateway.StatusRpcTest do
  @moduledoc """
  PushStatus and StreamStatus after the edge-record cutover: ephemeral summaries are forwarded
  to core, statuses from retired durable-data sources are refused and counted, and neither
  outcome fails the RPC.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Observability.MetricEnvelope
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadarAgentGateway.AgentGatewayServer
  alias ServiceRadarAgentGateway.AgentRegistryProxy
  alias ServiceRadarAgentGateway.CertificateTestHelpers
  alias ServiceRadarAgentGateway.CertIssuer
  alias ServiceRadarAgentGateway.Config
  alias ServiceRadarAgentGateway.RuntimeMetrics
  alias ServiceRadarAgentGateway.StatusBuffer
  alias ServiceRadarAgentGateway.StatusHandlerTestHelpers

  @refused_event [:serviceradar, :agent_gateway, :status, :retired_source_refused]

  defmodule PeerCertAdapter do
    @moduledoc false

    def get_cert({:cert, cert_der}), do: cert_der
    def get_peer(_payload), do: {{192, 0, 2, 10}, 50_051}
  end

  setup_all do
    parent_dir = CertificateTestHelpers.unique_tmp_dir!("status-rpc-test")
    on_exit(fn -> File.rm_rf(parent_dir) end)

    ca_cert = Path.join(parent_dir, "root.pem")
    ca_key = Path.join(parent_dir, "root-key.pem")
    CertificateTestHelpers.generate_ca_bundle!(ca_cert, ca_key)

    %{parent_dir: parent_dir, ca_cert: ca_cert, ca_key: ca_key}
  end

  setup do
    StatusHandlerTestHelpers.legacy_core_transport!()

    previous_config =
      try do
        {:ok, Config.get()}
      rescue
        ArgumentError -> :missing
      end

    {:ok, _apps} = Application.ensure_all_started(:horde)
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    if !Process.whereis(ServiceRadar.PubSub) do
      start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    end

    if !Process.whereis(ProcessRegistry.registry_name()) do
      Enum.each(ProcessRegistry.child_specs(), &start_supervised!/1)
    end

    # The agent tracker holds the per-agent refusal counts the readiness report reads.
    if !Process.whereis(ServiceRadar.AgentTracker) do
      start_supervised!(ServiceRadar.AgentTracker)
    end

    if !Process.whereis(AgentRegistryProxy) do
      start_supervised!(AgentRegistryProxy)
    end

    CertificateTestHelpers.ensure_revocation_store!()
    Config.setup(gateway_id: "gateway-1", domain: "test", capabilities: [])
    on_exit(fn -> restore_config(previous_config) end)

    existing = Process.whereis(ServiceRadar.StatusHandler)

    if is_pid(existing) do
      StatusHandlerTestHelpers.unregister_quietly(ServiceRadar.StatusHandler)
    end

    on_exit(fn -> StatusHandlerTestHelpers.restore(ServiceRadar.StatusHandler, existing) end)

    if !Process.whereis(StatusBuffer) do
      start_supervised!(StatusBuffer)
    end

    handler_id = {__MODULE__, make_ref()}
    parent = self()

    :ok = :telemetry.attach(handler_id, @refused_event, &__MODULE__.forward_refused/4, parent)
    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "PushStatus forwards summaries and refuses durable-data sources without failing the RPC", context do
    agent_id = "push-#{System.unique_integer([:positive])}"
    _handler = start_recording_status_handler(self())
    stream = cert_stream(issue_cert_der!(agent_id, context))

    mixed =
      push_request(agent_id, [
        summary("agent"),
        retired("sysmon", "sysmon-metrics"),
        retired("sweep", "results"),
        retired("netprobe", "addon:netprobe")
      ])

    log =
      capture_log(fn ->
        assert %Monitoring.GatewayStatusResponse{received: true} = AgentGatewayServer.push_status(mixed, stream)
      end)

    assert log =~ "sent statuses the status path refuses"
    assert_receive {:forwarded, "agent"}, 1_000
    assert_receive {:refused, "sysmon-metrics", 1}
    assert_receive {:refused, "results", 1}
    assert_receive {:refused, "addon", 1}

    # Durable data alone is answered as not received, still without an RPC error, and the
    # repeat is counted but not logged again.
    durable_only = push_request(agent_id, [retired("flow", "flow-attribution"), retired("flow2", "flow-attribution")])

    log =
      capture_log(fn ->
        assert %Monitoring.GatewayStatusResponse{received: false} =
                 AgentGatewayServer.push_status(durable_only, stream)
      end)

    refute log =~ "status path refuses"
    assert_receive {:refused, "flow-attribution", 2}
    refute_receive {:forwarded, _service_name}, 200
  end

  test "StreamStatus applies the same rule across chunks and keeps chunk order", context do
    agent_id = "stream-#{System.unique_integer([:positive])}"
    _handler = start_recording_status_handler(self())

    chunks = [
      status_chunk(agent_id, 0, 2, [summary("first")]),
      status_chunk(agent_id, 1, 2, [retired("results", "results"), summary("second")], true)
    ]

    capture_log(fn ->
      assert %Monitoring.GatewayStatusResponse{received: true} =
               AgentGatewayServer.stream_status(chunks, cert_stream(issue_cert_der!(agent_id, context)))
    end)

    assert_receive {:forwarded, "first"}, 1_000
    assert_receive {:forwarded, "second"}, 1_000
    assert_receive {:refused, "results", 1}
  end

  test "an oversized summary is refused whole and counted, never cut", context do
    agent_id = "oversized-#{System.unique_integer([:positive])}"
    _handler = start_recording_status_handler(self(), :message)

    oversized = %{summary("oversized") | message: :binary.copy("x", 4_097)}
    fitting = %{summary("fitting") | message: :binary.copy("y", 4_096)}

    capture_log(fn ->
      assert %Monitoring.GatewayStatusResponse{received: true} =
               AgentGatewayServer.push_status(
                 push_request(agent_id, [oversized, fitting]),
                 cert_stream(issue_cert_der!(agent_id, context))
               )
    end)

    assert_receive {:refused, "oversized_summary", 1}
    assert_receive {:forwarded, message}, 1_000
    assert message == fitting.message
    refute_receive {:forwarded, _message}, 200
  end

  test "a push or stream of only an oversized summary is answered as not received, not as an RPC error",
       context do
    agent_id = "oversized-only-#{System.unique_integer([:positive])}"
    _handler = start_recording_status_handler(self())
    stream = cert_stream(issue_cert_der!(agent_id, context))
    oversized = %{summary("agent") | message: :binary.copy("x", 4_097)}

    capture_log(fn ->
      assert %Monitoring.GatewayStatusResponse{received: false} =
               AgentGatewayServer.push_status(push_request(agent_id, [oversized]), stream)

      assert %Monitoring.GatewayStatusResponse{received: false} =
               AgentGatewayServer.stream_status([status_chunk(agent_id, 0, 1, [oversized], true)], stream)
    end)

    assert_receive {:refused, "oversized_summary", 1}
    assert_receive {:refused, "oversized_summary", 1}
    refute_receive {:forwarded, _service_name}, 200
  end

  test "the capability-status push carries the endpoint inventory directive core reports", context do
    agent_id = "directive-#{System.unique_integer([:positive])}"
    _handler = start_recording_status_handler(self())
    start_core_peer!()
    stream = cert_stream(issue_cert_der!(agent_id, context))

    assert %Monitoring.GatewayStatusResponse{received: true, directives: [directive]} =
             AgentGatewayServer.push_status(push_request(agent_id, [summary("agent")]), stream)

    assert_receive {:core_rpc, :status_directives, [^agent_id]}
    assert directive.directive_type == "endpoint_inventory.reconcile_floor"
    assert directive.service_name == "endpoint_inventory"
    assert %{"reconcile_floor" => true, "upload_reason" => "changed"} = Jason.decode!(directive.payload_json)

    # Core is asked once per status interval, on the push that carries the capability status.
    assert %Monitoring.GatewayStatusResponse{received: true, directives: []} =
             AgentGatewayServer.push_status(push_request(agent_id, [summary("sweep")]), stream)

    refute_receive {:core_rpc, :status_directives, _args}, 200
  end

  test "stream RPC rejects an excessive declared chunk count before consuming its tail", context do
    agent_id = "chunk-count-#{System.unique_integer([:positive])}"
    parent = self()

    tail =
      Stream.map([:sentinel], fn :sentinel ->
        send(parent, :excessive_chunk_tail_consumed)
        status_chunk(agent_id, 1, 5_001, [])
      end)

    assert_raise GRPC.RPCError, ~r/exceeds 5000 chunks/, fn ->
      AgentGatewayServer.stream_status(
        Stream.concat([status_chunk(agent_id, 0, 5_001, [])], tail),
        cert_stream(issue_cert_der!(agent_id, context))
      )
    end

    refute_receive :excessive_chunk_tail_consumed
  end

  test "stream RPC rejects a chunk after final before forwarding", context do
    agent_id = "trailing-final-#{System.unique_integer([:positive])}"
    _handler = start_recording_status_handler(self())

    final = status_chunk(agent_id, 0, 1, [summary("final")], true)
    trailing = %{final | services: [], is_final: false}

    assert_raise GRPC.RPCError, ~r/after the final chunk/, fn ->
      AgentGatewayServer.stream_status([final, trailing], cert_stream(issue_cert_der!(agent_id, context)))
    end

    refute_receive {:forwarded, _service_name}, 200
  end

  test "PushStatus returns before core accepts and forwards once core recovers", context do
    agent_id = "buffered-#{System.unique_integer([:positive])}"
    install_runtime_metric_publisher!(self())

    # No core status handler is registered, so a push that waited on core could not answer.

    assert %Monitoring.GatewayStatusResponse{received: true} =
             AgentGatewayServer.push_status(
               push_request(agent_id, [summary("later")]),
               cert_stream(issue_cert_der!(agent_id, context))
             )

    assert StatusBuffer.size() >= 1

    _handler = start_recording_status_handler(self())
    StatusBuffer.request_flush()

    assert_receive {:forwarded, "later"}, 1_000
    refute_receive {:forwarded, "later"}, 100

    depth = await_runtime_metric("agent_gateway_status_buffer_depth", fn row -> row.value >= 1 end)
    assert depth.value >= 1
  end

  test "a core-call sample reported while the metrics process is busy is still published" do
    metrics = install_runtime_metric_publisher!(self())
    :ok = :sys.suspend(metrics)

    # Reporting must not block the status path, and it must not drop the sample when the
    # metrics process cannot answer right away.
    {elapsed_us, :ok} = :timer.tc(fn -> RuntimeMetrics.report_core_call(7, :failed, %{source: "status"}) end)

    assert elapsed_us < 50_000
    :ok = :sys.resume(metrics)

    duration =
      await_runtime_metric("agent_gateway_core_call_duration_ms", fn row ->
        row.tags["result"] == "failed"
      end)

    assert duration.value == 7
    assert duration.tags["source"] == "status"
  end

  def forward_refused(_event, measurements, metadata, parent),
    do: send(parent, {:refused, metadata.source, measurements.count})

  defp summary(name) do
    %Monitoring.GatewayServiceStatus{
      service_name: name,
      service_type: "agent",
      source: "status",
      available: true,
      message: ~s({"status":"ok"})
    }
  end

  defp retired(name, source) do
    %Monitoring.GatewayServiceStatus{
      service_name: name,
      service_type: "metrics",
      source: source,
      available: true,
      message: "invented-durable-payload"
    }
  end

  defp push_request(agent_id, services) do
    %Monitoring.GatewayStatusRequest{agent_id: agent_id, services: services, timestamp: System.os_time(:second)}
  end

  defp status_chunk(agent_id, chunk_index, total_chunks, services, is_final \\ false) do
    %Monitoring.GatewayStatusChunk{
      agent_id: agent_id,
      services: services,
      chunk_index: chunk_index,
      total_chunks: total_chunks,
      is_final: is_final
    }
  end

  defp start_recording_status_handler(parent, field \\ :service_name) do
    pid = spawn(fn -> recording_status_handler_loop(parent, field) end)
    Process.register(pid, ServiceRadar.StatusHandler)
    on_exit(fn -> StatusHandlerTestHelpers.kill_and_await(pid) end)
    pid
  end

  defp recording_status_handler_loop(parent, field) do
    receive do
      {:"$gen_cast", {:status_update, status}} ->
        send(parent, {:forwarded, Map.fetch!(status, field)})
        recording_status_handler_loop(parent, field)

      :stop ->
        :ok
    end
  end

  defp install_runtime_metric_publisher!(parent) do
    previous = Application.get_env(:serviceradar_agent_gateway, :runtime_metrics_publish)

    Application.put_env(:serviceradar_agent_gateway, :runtime_metrics_publish, fn subject, body ->
      send(parent, {:jetstream, subject, body})
      :ok
    end)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:serviceradar_agent_gateway, :runtime_metrics_publish, previous),
        else: Application.delete_env(:serviceradar_agent_gateway, :runtime_metrics_publish)
    end)

    if Process.whereis(RuntimeMetrics), do: RuntimeMetrics, else: start_supervised!(RuntimeMetrics)
  end

  defp await_runtime_metric(metric_name, predicate, attempts \\ 20) do
    assert_receive {:jetstream, subject, body}, 2_000
    assert subject == RuntimeMetrics.subject()
    assert {:ok, rows} = MetricEnvelope.decode_rows(body)

    case Enum.find(rows, fn row -> row.metric_name == metric_name and predicate.(row) end) do
      nil when attempts > 1 -> await_runtime_metric(metric_name, predicate, attempts - 1)
      nil -> flunk("metric #{metric_name} was not published")
      row -> row
    end
  end

  # A connected node under the core basename whose AgentGatewaySync answers the gateway's RPCs.
  defp start_core_peer! do
    if !Node.alive?() do
      {_, 0} = System.cmd("epmd", ["-daemon"])
      {:ok, _} = :net_kernel.start([:status_rpc_test, :shortnames])
      on_exit(fn -> :net_kernel.stop() end)
    end

    basename = "status_rpc_core_#{System.unique_integer([:positive])}"
    previous = Application.get_env(:serviceradar_agent_gateway, :cluster_core_node_basename)
    Application.put_env(:serviceradar_agent_gateway, :cluster_core_node_basename, basename)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:serviceradar_agent_gateway, :cluster_core_node_basename, previous),
        else: Application.delete_env(:serviceradar_agent_gateway, :cluster_core_node_basename)
    end)

    peer =
      start_supervised!(%{
        id: :status_rpc_core_peer,
        start:
          {:peer, :start_link,
           [
             %{
               name: String.to_atom(basename),
               connection: :standard_io,
               args: [~c"+S", ~c"2", ~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
             }
           ]},
        restart: :temporary
      })

    core_node = :peer.call(peer, :erlang, :node, [])
    :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:elixir])

    :peer.call(peer, Code, :compile_string, [
      """
      defmodule ServiceRadar.Edge.AgentGatewaySync do
        def heartbeat_agent(_agent_id, _attrs), do: :ok
        def reconcile_agent_release(_agent_id), do: :ok

        def status_directives(agent_id) do
          send(:persistent_term.get(:status_rpc_test_owner), {:core_rpc, :status_directives, [agent_id]})

          {:ok,
           %{
             "endpoint_inventory" => %{
               "reconcile_floor" => true,
               "upload_reason" => "changed",
               "message" => "server reconcile floor reached"
             }
           }}
        end
      end
      """
    ])

    :ok = :peer.call(peer, :persistent_term, :put, [:status_rpc_test_owner, self()])
    assert Node.connect(core_node)
  end

  defp cert_stream(cert_der) do
    %GRPC.Server.Stream{adapter: PeerCertAdapter, payload: {:cert, cert_der}}
  end

  defp issue_cert_der!(component_id, context) do
    {:ok, bundle} =
      CertIssuer.issue_agent_bundle(
        component_id,
        "default",
        :agent,
        ca_cert_file: context.ca_cert,
        ca_key_file: context.ca_key,
        temp_parent_dir: context.parent_dir
      )

    CertificateTestHelpers.certificate_der!(bundle.certificate_pem)
  end

  defp restore_config({:ok, config}) do
    Config.setup(gateway_id: config.gateway_id, domain: config.domain, capabilities: config.capabilities)
  end

  defp restore_config(:missing), do: :persistent_term.erase(Config)
end
