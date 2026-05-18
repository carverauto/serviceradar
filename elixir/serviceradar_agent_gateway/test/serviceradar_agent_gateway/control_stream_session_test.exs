defmodule ServiceRadarAgentGateway.ControlStreamSessionTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.ProxmoxConsolePubSub
  alias ServiceRadar.Edge.RemoteAccessPubSub
  alias ServiceRadarAgentGateway.ControlStreamSession

  test "registered agent console frames are broadcast with authenticated stream ownership" do
    ensure_pubsub!()

    session_id = "session-#{System.unique_integer([:positive])}"
    identity_context = identity_context("agent-owned", "partition-a")

    :ok = ProxmoxConsolePubSub.subscribe(session_id)
    :ok = RemoteAccessPubSub.subscribe(session_id)

    pid = start_supervised!({ControlStreamSession, stream: nil})

    :sys.replace_state(pid, fn state ->
      %{
        state
        | agent_id: "agent-owned",
          partition_id: "partition-a",
          registered_identity: identity_context
      }
    end)

    ControlStreamSession.handle_message(
      pid,
      %Monitoring.ControlStreamRequest{
        payload:
          {:console_frame,
           %Monitoring.ConsoleFrame{
             session_id: session_id,
             frame_type: "data",
             data: "hello",
             timestamp: 123
           }}
      },
      identity_context
    )

    assert_receive {:proxmox_console_frame,
                    %{
                      session_id: ^session_id,
                      frame_type: "data",
                      data: "hello",
                      agent_id: "agent-owned",
                      partition_id: "partition-a"
                    }}

    assert_receive {:remote_access_frame,
                    %{
                      session_id: ^session_id,
                      frame_type: "data",
                      data: "hello",
                      agent_id: "agent-owned",
                      partition_id: "partition-a"
                    }}
  end

  test "unregistered control streams do not broadcast console frames" do
    ensure_pubsub!()

    session_id = "session-#{System.unique_integer([:positive])}"

    :ok = ProxmoxConsolePubSub.subscribe(session_id)
    :ok = RemoteAccessPubSub.subscribe(session_id)

    pid = start_supervised!({ControlStreamSession, stream: nil})

    ControlStreamSession.handle_message(pid, %Monitoring.ControlStreamRequest{
      payload:
        {:console_frame,
         %Monitoring.ConsoleFrame{
           session_id: session_id,
           frame_type: "data",
           data: "hello",
           timestamp: 123
         }}
    })

    refute_receive {:proxmox_console_frame, _frame}, 50
    refute_receive {:remote_access_frame, _frame}, 50
  end

  test "registered control streams reject messages with mismatched authenticated identity" do
    ensure_pubsub!()

    session_id = "session-#{System.unique_integer([:positive])}"
    identity_context = identity_context("agent-owned", "partition-a")
    mismatched_identity = identity_context("agent-owned", "partition-b")
    handler_id = {__MODULE__, self(), :control_stream_message_rejected}

    :ok = ProxmoxConsolePubSub.subscribe(session_id)
    :ok = RemoteAccessPubSub.subscribe(session_id)

    :telemetry.attach(
      handler_id,
      [:serviceradar, :control_stream, :message, :rejected],
      fn event, measurements, metadata, test_pid ->
        send(test_pid, {:control_stream_message_rejected, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    pid = start_supervised!({ControlStreamSession, stream: nil})
    monitor_ref = Process.monitor(pid)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | agent_id: "agent-owned",
          partition_id: "partition-a",
          registered_identity: identity_context
      }
    end)

    ControlStreamSession.handle_message(
      pid,
      %Monitoring.ControlStreamRequest{
        payload:
          {:console_frame,
           %Monitoring.ConsoleFrame{
             session_id: session_id,
             frame_type: "data",
             data: "hello",
             timestamp: 123
           }}
      },
      mismatched_identity
    )

    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}

    assert_receive {:control_stream_message_rejected, [:serviceradar, :control_stream, :message, :rejected], %{count: 1},
                    %{
                      agent_id: "agent-owned",
                      identity_partition_id: "partition-b",
                      partition_id: "partition-a",
                      reason: :partition_id_mismatch
                    }}

    refute_receive {:proxmox_console_frame, _frame}, 50
    refute_receive {:remote_access_frame, _frame}, 50
  end

  defp ensure_pubsub! do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    if !Process.whereis(ServiceRadar.PubSub) do
      start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    end
  end

  defp identity_context(agent_id, partition_id) do
    %{
      component_id: agent_id,
      partition_id: partition_id,
      component_type: :agent,
      cert_fingerprint_sha256: "fingerprint-#{agent_id}-#{partition_id}"
    }
  end
end
