defmodule ServiceRadarAgentGateway.ControlStreamSessionTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.AgentCommands.PubSub, as: AgentCommandPubSub
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
             seq: 7,
             payload_sha256: "payload-hash",
             signature: "frame-signature",
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
                      seq: 7,
                      payload_sha256: "payload-hash",
                      signature: "frame-signature",
                      agent_id: "agent-owned",
                      partition_id: "partition-a"
                    }}

    assert_receive {:remote_access_frame,
                    %{
                      session_id: ^session_id,
                      frame_type: "data",
                      data: "hello",
                      seq: 7,
                      payload_sha256: "payload-hash",
                      signature: "frame-signature",
                      agent_id: "agent-owned",
                      partition_id: "partition-a"
                    }}
  end

  test "registered agent application and TCP frames stay bound to authenticated stream ownership" do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    if !Process.whereis(ServiceRadar.PubSub) do
      start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    end

    session_id = "session-#{System.unique_integer([:positive])}"

    :ok = RemoteAccessPubSub.subscribe(session_id)

    pid = start_supervised!({ControlStreamSession, stream: nil})

    :sys.replace_state(pid, fn state ->
      %{state | agent_id: "agent-owned", partition_id: "partition-a", gateway_node: "gateway-a"}
    end)

    ControlStreamSession.handle_message(pid, %Monitoring.ControlStreamRequest{
      payload:
        {:console_frame,
         %Monitoring.ConsoleFrame{
           session_id: session_id,
           frame_type: "app_response_metadata",
           data: Jason.encode!(%{request_id: "req-1", status_code: 200}),
           timestamp: 123
         }}
    })

    ControlStreamSession.handle_message(pid, %Monitoring.ControlStreamRequest{
      payload:
        {:console_frame,
         %Monitoring.ConsoleFrame{
           session_id: session_id,
           frame_type: "tcp_data",
           data: Jason.encode!(%{connection_id: "conn-1", sequence: 1}),
           timestamp: 124
         }}
    })

    assert_receive {:remote_access_frame,
                    %{
                      session_id: ^session_id,
                      frame_type: "app_response_metadata",
                      agent_id: "agent-owned",
                      partition_id: "partition-a",
                      gateway_node: "gateway-a"
                    }}

    assert_receive {:remote_access_frame,
                    %{
                      session_id: ^session_id,
                      frame_type: "tcp_data",
                      agent_id: "agent-owned",
                      partition_id: "partition-a",
                      gateway_node: "gateway-a"
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

  test "command results broadcast on the command-scoped topic" do
    ensure_pubsub!()

    command_id = Ecto.UUID.generate()
    :ok = AgentCommandPubSub.subscribe(command_id)

    pid = start_supervised!({ControlStreamSession, stream: nil})

    :sys.replace_state(pid, fn state ->
      %{
        state
        | agent_id: "agent-owned",
          partition_id: "partition-a",
          commands: %{
            command_id => %{
              command_type: "endpoint_inventory.cache_query",
              response_subject: AgentCommandPubSub.topic(command_id)
            }
          }
      }
    end)

    ControlStreamSession.handle_message(pid, %Monitoring.ControlStreamRequest{
      payload:
        {:command_result,
         %Monitoring.CommandResult{
           command_id: command_id,
           command_type: "endpoint_inventory.cache_query",
           success: true,
           message: "done",
           payload_json: Jason.encode!(%{count: 1}),
           timestamp: 123
         }}
    })

    assert_receive {:command_result,
                    %{
                      command_id: ^command_id,
                      command_type: "endpoint_inventory.cache_query",
                      success: true,
                      payload: %{"count" => 1},
                      response_subject: _
                    }},
                   1_000
  end

  test "command result payloads over the byte cap are failed before broadcast" do
    ensure_pubsub!()

    command_id = Ecto.UUID.generate()
    :ok = AgentCommandPubSub.subscribe(command_id)

    pid = start_supervised!({ControlStreamSession, stream: nil})

    :sys.replace_state(pid, fn state ->
      %{
        state
        | agent_id: "agent-owned",
          partition_id: "partition-a",
          commands: %{command_id => %{command_type: "endpoint_inventory.cache_query"}}
      }
    end)

    oversized_payload = Jason.encode!(%{"data" => String.duplicate("x", 70_000)})

    ControlStreamSession.handle_message(pid, %Monitoring.ControlStreamRequest{
      payload:
        {:command_result,
         %Monitoring.CommandResult{
           command_id: command_id,
           command_type: "endpoint_inventory.cache_query",
           success: true,
           message: "too large",
           payload_json: oversized_payload,
           timestamp: 123
         }}
    })

    assert_receive {:command_result,
                    %{
                      command_id: ^command_id,
                      command_type: "endpoint_inventory.cache_query",
                      success: false,
                      message: "command result payload exceeded byte cap",
                      payload: %{"error" => "payload_too_large"}
                    }},
                   1_000
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

    rejected_event = [:serviceradar, :control_stream, :message, :rejected]

    assert_receive {:control_stream_message_rejected, ^rejected_event, %{count: 1},
                    %{
                      agent_id: "agent-owned",
                      identity_partition_id: "partition-b",
                      partition_id: "partition-a",
                      reason: :partition_id_mismatch
                    }}

    refute_receive {:proxmox_console_frame, _frame}, 50
    refute_receive {:remote_access_frame, _frame}, 50
  end

  describe "config ack forwarding" do
    setup do
      test_pid = self()

      Application.put_env(:serviceradar_agent_gateway, :config_sync_rpc, fn function, args ->
        send(test_pid, {:config_sync, function, args})
        :ok
      end)

      on_exit(fn -> Application.delete_env(:serviceradar_agent_gateway, :config_sync_rpc) end)

      pid = start_supervised!({ControlStreamSession, stream: nil})

      :sys.replace_state(pid, fn state ->
        %{state | agent_id: "agent-ack", partition_id: "partition-a"}
      end)

      {:ok, pid: pid}
    end

    test "sectioned config ack is persisted to core with per-section statuses", %{pid: pid} do
      ControlStreamSession.handle_message(pid, %Monitoring.ControlStreamRequest{
        payload:
          {:config_ack,
           %Monitoring.ConfigAck{
             config_version: "v2",
             timestamp: 1_782_000_000,
             section_statuses: [
               %Monitoring.ConfigSectionStatus{
                 section: "visibility",
                 disposition: "permanent_failure",
                 error: "merge netprobe add-on config: parse error",
                 since: 1_781_900_000
               }
             ]
           }}
      })

      assert_receive {:config_sync, :record_config_ack, ["agent-ack", attrs]}
      assert attrs.config_version == "v2"

      assert [%{"section" => "visibility", "disposition" => "permanent_failure"}] =
               attrs.section_statuses
    end

    test "legacy config ack (no sections) is persisted as a whole-version ack", %{pid: pid} do
      ControlStreamSession.handle_message(pid, %Monitoring.ControlStreamRequest{
        payload: {:config_ack, %Monitoring.ConfigAck{config_version: "v1", timestamp: 123}}
      })

      assert_receive {:config_sync, :record_config_ack, ["agent-ack", attrs]}
      assert attrs.config_version == "v1"
      assert attrs.section_statuses == nil
    end

    test "heartbeat hello forwards the reported committed version, debounced", %{pid: pid} do
      hello = %Monitoring.ControlStreamHello{agent_id: "agent-ack", config_version: "v5"}

      ControlStreamSession.handle_message(pid, %Monitoring.ControlStreamRequest{
        payload: {:hello, hello}
      })

      assert_receive {:config_sync, :record_config_ack, ["agent-ack", attrs]}
      assert attrs.config_version == "v5"
      assert attrs.section_statuses == nil

      # Same version again: debounced (no second RPC).
      ControlStreamSession.handle_message(pid, %Monitoring.ControlStreamRequest{
        payload: {:hello, hello}
      })

      refute_receive {:config_sync, :record_config_ack, _args}, 100

      # A new committed version is forwarded again.
      ControlStreamSession.handle_message(pid, %Monitoring.ControlStreamRequest{
        payload: {:hello, %Monitoring.ControlStreamHello{agent_id: "agent-ack", config_version: "v6"}}
      })

      assert_receive {:config_sync, :record_config_ack, ["agent-ack", attrs]}
      assert attrs.config_version == "v6"
    end

    test "hello without a config version forwards nothing", %{pid: pid} do
      ControlStreamSession.handle_message(pid, %Monitoring.ControlStreamRequest{
        payload: {:hello, %Monitoring.ControlStreamHello{agent_id: "agent-ack"}}
      })

      refute_receive {:config_sync, _function, _args}, 100
    end

    test "an unregistered session does not forward acks" do
      pid = start_supervised!({ControlStreamSession, stream: nil}, id: :unregistered_session)

      ControlStreamSession.handle_message(pid, %Monitoring.ControlStreamRequest{
        payload: {:config_ack, %Monitoring.ConfigAck{config_version: "v1", timestamp: 123}}
      })

      refute_receive {:config_sync, _function, _args}, 100
    end
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
