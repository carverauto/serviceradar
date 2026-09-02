defmodule ServiceRadarAgentGateway.AddonPartitionStampingTest do
  @moduledoc """
  Native add-on telemetry becomes durable inventory and OCSF events, so the
  partition it lands under must come from the mTLS-authenticated view rather
  than from a value the add-on supplied.

  The second test here is the one that matters. Forcing the partition looks like
  it belongs in `@strict_delivery_sources`, but that list does a SECOND,
  unrelated thing: a strict-delivery status bypasses the lenient rescue in
  `process_push_service/3`, so any exception raised while handling it aborts the
  whole chunk instead of being dropped and logged. Adding `addon:` there would
  change failure semantics for otel-collector, powerdns, anomaly-addon and
  bumblebee all at once.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadarAgentGateway.AgentGatewayServer
  alias ServiceRadarAgentGateway.StatusHandlerTestHelpers

  setup do
    existing = Process.whereis(ServiceRadar.StatusHandler)

    if is_pid(existing) do
      StatusHandlerTestHelpers.unregister_quietly(ServiceRadar.StatusHandler)
    end

    on_exit(fn ->
      StatusHandlerTestHelpers.restore(ServiceRadar.StatusHandler, existing)
    end)

    :ok
  end

  # The stub LOOPS and is killed on exit, rather than handling one message and
  # dying.
  #
  # A handle-one-then-exit stub leaves any second forward from the same call
  # undelivered, and `GenServer.cast/2` resolves the registered name at send
  # time -- so a late forward can land in the NEXT test file's stub and fail an
  # unrelated `refute_receive`. That is exactly what this file did to
  # StatusProcessorTest before the loop was added: 161 tests green became 164
  # tests with one failure in another file, reproducible on a fixed seed.
  defp capture_forwarded_status do
    parent = self()

    handler_pid =
      spawn(fn ->
        loop = fn loop ->
          receive do
            {:"$gen_call", from, {:status_update, status}} ->
              send(parent, {:forwarded, status})
              GenServer.reply(from, :ok)
              loop.(loop)

            {:"$gen_cast", {:status_update, status}} ->
              send(parent, {:forwarded, status})
              loop.(loop)

            _other ->
              loop.(loop)
          end
        end

        loop.(loop)
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    on_exit(fn ->
      StatusHandlerTestHelpers.kill_and_await(handler_pid)
    end)

    handler_pid
  end

  defp addon_service(overrides \\ []) do
    struct!(
      %Monitoring.GatewayServiceStatus{
        service_name: "addon-telemetry",
        service_type: "native-addon",
        source: "addon:powerdns",
        partition: "payload-spoofed-partition",
        available: true,
        message: <<>>
      },
      overrides
    )
  end

  defp metadata do
    %{
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "cert-partition",
      authenticated_partition: "cert-partition",
      source_ip: "192.0.2.10",
      kv_store_id: nil,
      timestamp: System.os_time(:second),
      agent_timestamp: 0,
      chunk_index: 0,
      total_chunks: 1,
      is_final: true,
      delivery_capabilities: []
    }
  end

  test "an add-on's own partition claim is overridden by the certificate's" do
    capture_forwarded_status()

    capture_log(fn ->
      AgentGatewayServer.process_chunk_services([addon_service()], metadata())
    end)

    assert_receive {:forwarded, status}

    assert status.partition == "cert-partition",
           "an add-on supplied its own partition and the gateway believed it"
  end

  test "results carry the certificate partition separately from payload routing" do
    capture_forwarded_status()

    service =
      addon_service(
        source: "results",
        service_type: "sweep",
        service_name: "network-sweep"
      )

    capture_log(fn ->
      AgentGatewayServer.process_chunk_services([service], metadata())
    end)

    assert_receive {:forwarded, status}
    assert status.partition == "payload-spoofed-partition"
    assert status.authenticated_partition == "cert-partition"
  end

  test "results do not synthesize default authority from a missing certificate partition" do
    capture_forwarded_status()

    service =
      addon_service(
        source: "results",
        service_type: "sweep",
        service_name: "network-sweep"
      )

    for invalid_partition <- [nil, "", " padded-partition "] do
      metadata = %{
        metadata()
        | authenticated_partition: invalid_partition,
          partition: "default"
      }

      capture_log(fn ->
        AgentGatewayServer.process_chunk_services([service], metadata)
      end)

      assert_receive {:forwarded, status}
      assert status.partition == "payload-spoofed-partition"
      assert is_nil(status.authenticated_partition)
    end
  end

  test "a non-add-on source still uses the partition the payload carries" do
    # The change is scoped, not a blanket "always use the certificate". Ordinary
    # service statuses keep their existing behavior.
    capture_forwarded_status()

    service =
      addon_service(
        source: "sweep",
        service_type: "sweep",
        service_name: "network-sweep"
      )

    capture_log(fn ->
      AgentGatewayServer.process_chunk_services([service], metadata())
    end)

    assert_receive {:forwarded, status}
    assert status.partition == "payload-spoofed-partition"
  end

  test "addon: sources are NOT strict-delivery, so a failure does not abort the chunk" do
    # The guard against fixing partition stamping by widening
    # @strict_delivery_sources. An oversized payload raises inside
    # process_service_status/2; for a non-strict source that raise is rescued and
    # the chunk continues. If `addon:` were added to @strict_delivery_sources,
    # this would raise out of process_chunk_services/2 instead -- and so would
    # every other failure from otel-collector, powerdns, anomaly-addon and
    # bumblebee.
    service = addon_service(message: :binary.copy("x", 15 * 1024 * 1024 + 1))

    log =
      capture_log(fn ->
        assert AgentGatewayServer.process_chunk_services([service], metadata()) == []
      end)

    assert log =~ "payload exceeds max size"
  end
end
