defmodule ServiceRadarAgentGateway.ControlStreamSessionTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.AgentCommands.PubSub, as: AgentCommandPubSub
  alias ServiceRadar.Edge.ProxmoxConsolePubSub
  alias ServiceRadar.Edge.RemoteAccessFileTransfers
  alias ServiceRadar.Edge.RemoteAccessPubSub
  alias ServiceRadar.NATS.DurablePublish
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadarAgentGateway.ControlStreamSession

  test "authenticated hello and config ack refresh exact control evidence in the registry" do
    ensure_process_registry!()

    agent_id = "agent-policy-#{System.unique_integer([:positive])}"
    fingerprint = String.duplicate("a", 64)
    test_pid = self()

    Application.put_env(:serviceradar_agent_gateway, :config_sync_rpc, fn function, args ->
      send(test_pid, {:config_sync, function, args})
      :ok
    end)

    on_exit(fn -> Application.delete_env(:serviceradar_agent_gateway, :config_sync_rpc) end)

    hello = %Monitoring.ControlStreamHello{
      agent_id: agent_id,
      config_version: "config-v1",
      capabilities: [
        "plugin-host-authority:v1",
        "proxmox-console-policy-binding:v1"
      ],
      applied_plugin_assignments: [policy_ack("assignment-1", 7, fingerprint)]
    }

    pid = start_supervised!({ControlStreamSession, stream: nil})

    assert :ok =
             ControlStreamSession.register(
               pid,
               agent_id,
               "partition-a",
               hello.capabilities,
               identity_context(agent_id, "partition-a"),
               hello
             )

    assert_receive {:config_sync, :record_config_ack, [^agent_id, %{config_version: "config-v1"}]}

    assert_registry_evidence("partition-a", agent_id, pid, fn metadata ->
      metadata.config_version == "config-v1" and
        metadata.capabilities == Enum.sort(hello.capabilities) and
        metadata.applied_plugin_assignments == [
          %{
            assignment_id: "assignment-1",
            plugin_id: "proxmox-console",
            assignment_policy_version: 7,
            assignment_policy_fingerprint: fingerprint
          }
        ]
    end)

    next_fingerprint = String.duplicate("b", 64)

    ControlStreamSession.handle_message(
      pid,
      %Monitoring.ControlStreamRequest{
        payload:
          {:config_ack,
           %Monitoring.ConfigAck{
             config_version: "config-v2",
             applied_plugin_assignments: [policy_ack("assignment-1", 8, next_fingerprint)]
           }}
      },
      identity_context(agent_id, "partition-a")
    )

    assert_registry_evidence("partition-a", agent_id, pid, fn metadata ->
      metadata.config_version == "config-v2" and
        metadata.applied_plugin_assignments == [
          %{
            assignment_id: "assignment-1",
            plugin_id: "proxmox-console",
            assignment_policy_version: 8,
            assignment_policy_fingerprint: next_fingerprint
          }
        ]
    end)
  end

  test "same agent and gateway register independently in two partitions while duplicate principal fails closed" do
    ensure_process_registry!()

    agent_id = "agent-shared-#{System.unique_integer([:positive])}"
    farm_pid = start_supervised!({ControlStreamSession, stream: nil}, id: :farm_control_session)
    tonka_pid = start_supervised!({ControlStreamSession, stream: nil}, id: :tonka_control_session)

    duplicate_pid =
      start_supervised!({ControlStreamSession, stream: nil}, id: :duplicate_control_session)

    assert :ok =
             ControlStreamSession.register(
               farm_pid,
               agent_id,
               "farm01",
               [],
               identity_context(agent_id, "farm01")
             )

    assert :ok =
             ControlStreamSession.register(
               tonka_pid,
               agent_id,
               "tonka01",
               [],
               identity_context(agent_id, "tonka01")
             )

    assert [{^farm_pid, %{partition_id: "farm01"}}] =
             ProcessRegistry.lookup_agent_control("farm01", agent_id)

    assert [{^tonka_pid, %{partition_id: "tonka01"}}] =
             ProcessRegistry.lookup_agent_control("tonka01", agent_id)

    assert {:error, {:control_session_already_registered, ^farm_pid}} =
             ControlStreamSession.register(
               duplicate_pid,
               agent_id,
               "farm01",
               [],
               identity_context(agent_id, "farm01")
             )

    refute Enum.any?(ProcessRegistry.lookup_agent_control("farm01", agent_id), fn
             {^duplicate_pid, _metadata} -> true
             _entry -> false
           end)
  end

  test "malformed or duplicate assignment proofs fail closed as an empty evidence set" do
    fingerprint = String.duplicate("a", 64)
    valid = policy_ack("assignment-1", 7, fingerprint)

    assert [proof] = ControlStreamSession.normalize_applied_plugin_assignments([valid])
    assert proof.assignment_id == "assignment-1"

    assert [] =
             ControlStreamSession.normalize_applied_plugin_assignments([
               valid,
               policy_ack("assignment-1", 7, fingerprint)
             ])

    assert [] =
             ControlStreamSession.normalize_applied_plugin_assignments([
               %{valid | assignment_policy_fingerprint: "not-a-fingerprint"}
             ])
  end

  test "config push is live-pending before send, retries persistence, and blocks stale console evidence" do
    ensure_process_registry!()

    agent_id = "agent-pending-#{System.unique_integer([:positive])}"
    fingerprint = String.duplicate("c", 64)
    identity = identity_context(agent_id, "partition-a")
    test_pid = self()
    {:ok, sync_gate} = Agent.start_link(fn -> %{allow_push?: false, push_attempts: 0} end)

    Application.put_env(:serviceradar_agent_gateway, :control_stream_reply, fn stream, response ->
      send(test_pid, {:stream_reply, response})
      stream
    end)

    Application.put_env(:serviceradar_agent_gateway, :config_sync_rpc, fn function, args ->
      case function do
        :record_config_push ->
          allow_push? =
            Agent.get_and_update(sync_gate, fn state ->
              {state.allow_push?, %{state | push_attempts: state.push_attempts + 1}}
            end)

          send(test_pid, {:config_push_sync_attempt, args, allow_push?})
          if allow_push?, do: :ok, else: {:error, :core_unavailable}

        _other ->
          :ok
      end
    end)

    on_exit(fn ->
      Application.delete_env(:serviceradar_agent_gateway, :control_stream_reply)
      Application.delete_env(:serviceradar_agent_gateway, :config_sync_rpc)
    end)

    hello = %Monitoring.ControlStreamHello{
      agent_id: agent_id,
      config_version: "config-v1",
      capabilities: ["plugin-host-authority:v1", "proxmox-console-policy-binding:v1"],
      applied_plugin_assignments: [policy_ack("assignment-1", 7, fingerprint)]
    }

    pid = start_supervised!({ControlStreamSession, stream: nil})

    assert :ok =
             ControlStreamSession.register(
               pid,
               agent_id,
               "partition-a",
               hello.capabilities,
               identity,
               hello
             )

    assert_registry_evidence("partition-a", agent_id, pid, fn metadata ->
      metadata.config_version == "config-v1" and metadata.pending_config_version == nil
    end)

    old_metadata = registry_metadata("partition-a", agent_id, pid)

    old_evidence = %{
      control_session_pid: pid,
      agent_id: old_metadata.agent_id,
      gateway_node: old_metadata.gateway_node,
      capabilities: old_metadata.capabilities,
      config_version: old_metadata.config_version,
      pending_config_version: old_metadata.pending_config_version,
      applied_plugin_assignments: old_metadata.applied_plugin_assignments
    }

    assert :ok =
             ControlStreamSession.push_config(pid, %Monitoring.AgentConfigResponse{
               config_version: "config-v2"
             })

    assert_receive {:stream_reply,
                    %Monitoring.ControlStreamResponse{
                      payload: {:config, %{config_version: "config-v2"}}
                    }}

    assert_receive {:config_push_sync_attempt, [^agent_id, %{config_version: "config-v2"}], false}

    assert_registry_evidence("partition-a", agent_id, pid, fn metadata ->
      metadata.config_version == "config-v1" and
        metadata.pending_config_version == "config-v2"
    end)

    assert {:error, :console_config_transition_pending} =
             ControlStreamSession.send_console_frame(
               pid,
               %{session_id: "session-1", frame_type: "open"},
               old_evidence
             )

    refute_receive {:stream_reply, %Monitoring.ControlStreamResponse{payload: {:console_frame, _frame}}},
                   50

    ControlStreamSession.handle_message(
      pid,
      %Monitoring.ControlStreamRequest{
        payload:
          {:config_ack,
           %Monitoring.ConfigAck{
             config_version: "config-v2",
             applied_plugin_assignments: [policy_ack("assignment-1", 7, fingerprint)]
           }}
      },
      identity
    )

    # The agent ACK alone is insufficient while the pushed-version write is
    # still unavailable on core.
    assert_registry_evidence("partition-a", agent_id, pid, fn metadata ->
      metadata.config_version == "config-v2" and
        metadata.pending_config_version == "config-v2"
    end)

    Agent.update(sync_gate, &%{&1 | allow_push?: true})

    assert_registry_evidence("partition-a", agent_id, pid, fn metadata ->
      metadata.config_version == "config-v2" and metadata.pending_config_version == nil
    end)

    assert Agent.get(sync_gate, & &1.push_attempts) >= 2

    current_metadata = registry_metadata("partition-a", agent_id, pid)

    current_evidence = %{
      control_session_pid: pid,
      agent_id: current_metadata.agent_id,
      gateway_node: current_metadata.gateway_node,
      capabilities: current_metadata.capabilities,
      config_version: current_metadata.config_version,
      pending_config_version: current_metadata.pending_config_version,
      applied_plugin_assignments: current_metadata.applied_plugin_assignments
    }

    assert :ok =
             ControlStreamSession.send_console_frame(
               pid,
               %{session_id: "session-1", frame_type: "open"},
               current_evidence
             )

    assert_receive {:stream_reply, %Monitoring.ControlStreamResponse{payload: {:console_frame, _frame}}}
  end

  test "full config with a blank version is rejected before stream delivery" do
    test_pid = self()

    Application.put_env(:serviceradar_agent_gateway, :control_stream_reply, fn stream, response ->
      send(test_pid, {:stream_reply, response})
      stream
    end)

    on_exit(fn ->
      Application.delete_env(:serviceradar_agent_gateway, :control_stream_reply)
    end)

    pid = start_supervised!({ControlStreamSession, stream: nil})

    for version <- [nil, "", "   "] do
      assert {:error, :invalid_config_version} =
               ControlStreamSession.push_config(pid, %Monitoring.AgentConfigResponse{
                 config_version: version,
                 not_modified: false
               })
    end

    refute_receive {:stream_reply, %Monitoring.ControlStreamResponse{payload: {:config, _config}}},
                   50
  end

  test "a config version already pushed on the stream is not sent again until it changes" do
    ensure_process_registry!()

    agent_id = "agent-repush-#{System.unique_integer([:positive])}"
    pid = start_push_session!(agent_id, [], start: :linked)

    push = fn version ->
      ControlStreamSession.push_config(pid, %Monitoring.AgentConfigResponse{config_version: version})
    end

    assert :ok = push.("config-v1")
    assert_receive {:stream_reply, %Monitoring.ControlStreamResponse{payload: {:config, %{config_version: "config-v1"}}}}

    # The agent has not acknowledged config-v1; a dependency write regenerates it.
    assert :ok = push.("config-v1")
    refute_receive {:stream_reply, %Monitoring.ControlStreamResponse{payload: {:config, _config}}}, 50

    assert :ok = push.("config-v2")
    assert_receive {:stream_reply, %Monitoring.ControlStreamResponse{payload: {:config, %{config_version: "config-v2"}}}}

    # Changing back is a change.
    assert :ok = push.("config-v1")
    assert_receive {:stream_reply, %Monitoring.ControlStreamResponse{payload: {:config, %{config_version: "config-v1"}}}}

    # The stream identity is the trimmed version, so padding is not a new push.
    assert :ok = push.("  config-v1  ")
    refute_receive {:stream_reply, %Monitoring.ControlStreamResponse{payload: {:config, _config}}}, 50

    # A reconnect opens a new session for the same agent. The previous stream's
    # push does not carry over, so the agent receives the version again.
    GenServer.stop(pid)

    reconnected = start_push_session!(agent_id, [], start: :linked)

    assert :ok =
             ControlStreamSession.push_config(
               reconnected,
               %Monitoring.AgentConfigResponse{config_version: "config-v1"}
             )

    assert_receive {:stream_reply, %Monitoring.ControlStreamResponse{payload: {:config, %{config_version: "config-v1"}}}}
  end

  test "config push to a config_push_chunks agent arrives as ordered chunks that reassemble to the config" do
    ensure_process_registry!()

    agent_id = "agent-chunked-#{System.unique_integer([:positive])}"
    pid = start_push_session!(agent_id, ["config_push_chunks"])

    # Larger than the agent's 4 MiB single-message limit, so a one-message push
    # would tear down the agent's control stream.
    config = %Monitoring.AgentConfigResponse{
      config_version: "config-large",
      config_json: :crypto.strong_rand_bytes(4_500_000)
    }

    assert :ok = ControlStreamSession.push_config(pid, config)

    chunks = receive_config_chunks([])

    assert length(chunks) > 1
    assert Enum.map(chunks, & &1.chunk_index) == Enum.to_list(0..(length(chunks) - 1))
    assert Enum.map(chunks, & &1.is_final) == List.duplicate(false, length(chunks) - 1) ++ [true]

    assert Enum.all?(
             chunks,
             &(&1.config_version == "config-large" and &1.total_chunks == length(chunks))
           )

    payload = chunks |> Enum.map(& &1.payload) |> IO.iodata_to_binary()

    assert hd(chunks).payload_sha256 ==
             :sha256 |> :crypto.hash(payload) |> Base.encode16(case: :lower)

    assert Monitoring.AgentConfigResponse.decode(payload) == config

    refute_receive {:stream_reply, %Monitoring.ControlStreamResponse{payload: {:config, _config}}},
                   50

    assert_registry_evidence("partition-a", agent_id, pid, fn metadata ->
      metadata.pending_config_version == "config-large"
    end)
  end

  test "oversized config push to an agent without config_push_chunks is refused without touching the stream" do
    ensure_process_registry!()

    agent_id = "agent-legacy-#{System.unique_integer([:positive])}"
    pid = start_push_session!(agent_id, [])

    assert {:error, :config_push_too_large} =
             ControlStreamSession.push_config(pid, %Monitoring.AgentConfigResponse{
               config_version: "config-large",
               config_json: :crypto.strong_rand_bytes(4_500_000)
             })

    refute_receive {:stream_reply, _response}, 50

    assert registry_metadata("partition-a", agent_id, pid).pending_config_version == nil
  end

  describe "config push on control-session registration" do
    # Core resolves sessions through the cluster registry, which lags a fresh
    # registration; anything that addresses this session through core's view of
    # it reports the agent offline. The gateway owns the session and the
    # authenticated partition, so the push must not depend on that view.
    test "a changed config reaches the new session while core cannot see it" do
      ensure_process_registry!()

      agent_id = "agent-reconnect-#{System.unique_integer([:positive])}"

      config_sync_rpc = fn
        :get_config_if_changed, [^agent_id, "partition-a", "config-v1"] ->
          {:ok, generated_config("config-v2")}

        :push_config, [^agent_id] ->
          {:error, {:agent_offline, agent_id}}

        _function, _args ->
          :ok
      end

      start_push_session!(agent_id, [],
        config_sync_rpc: config_sync_rpc,
        hello: %Monitoring.ControlStreamHello{agent_id: agent_id, config_version: "config-v1"}
      )

      assert_receive {:stream_reply,
                      %Monitoring.ControlStreamResponse{
                        payload: {:config, %{config_version: "config-v2", not_modified: false}}
                      }}
    end

    test "an agent already running the current config is not sent it again" do
      ensure_process_registry!()

      agent_id = "agent-current-#{System.unique_integer([:positive])}"
      test_pid = self()

      config_sync_rpc = fn
        :get_config_if_changed, args ->
          send(test_pid, {:config_fetch, args})
          :not_modified

        _function, _args ->
          :ok
      end

      start_push_session!(agent_id, [],
        config_sync_rpc: config_sync_rpc,
        hello: %Monitoring.ControlStreamHello{agent_id: agent_id, config_version: "config-v1"}
      )

      assert_receive {:config_fetch, [^agent_id, "partition-a", "config-v1"]}
      refute_receive {:stream_reply, %Monitoring.ControlStreamResponse{payload: {:config, _config}}}, 100
    end
  end

  test "console open normalization preserves the exact assignment policy binding" do
    fingerprint = String.duplicate("a", 64)

    assert {:ok,
            %Monitoring.ConsoleFrame{
              session_id: "session-policy",
              frame_type: "open",
              assignment_policy_version: 7,
              assignment_policy_fingerprint: ^fingerprint
            }} =
             ControlStreamSession.normalize_console_frame(%{
               session_id: "session-policy",
               frame_type: "open",
               assignment_policy_version: 7,
               assignment_policy_fingerprint: fingerprint
             })
  end

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

  test "with repo disabled, durable publish returns repo_unavailable without raising" do
    previous_repo_enabled = Application.fetch_env(:serviceradar_core, :repo_enabled)
    Application.put_env(:serviceradar_core, :repo_enabled, false)

    on_exit(fn ->
      case previous_repo_enabled do
        {:ok, value} -> Application.put_env(:serviceradar_core, :repo_enabled, value)
        :error -> Application.delete_env(:serviceradar_core, :repo_enabled)
      end
    end)

    assert Process.whereis(ServiceRadar.Repo) == nil

    assert {:error, :repo_unavailable} =
             DurablePublish.publish("logs.internal.audit", "{}",
               msg_id: "gateway-dbless-#{System.unique_integer([:positive])}"
             )
  end

  test "with repo disabled, file-transfer frames route to core over RPC and fail cleanly without raising when core is unavailable" do
    ensure_pubsub!()

    previous_repo_enabled = Application.fetch_env(:serviceradar_core, :repo_enabled)
    Application.put_env(:serviceradar_core, :repo_enabled, false)

    on_exit(fn ->
      case previous_repo_enabled do
        {:ok, value} -> Application.put_env(:serviceradar_core, :repo_enabled, value)
        :error -> Application.delete_env(:serviceradar_core, :repo_enabled)
      end
    end)

    assert Process.whereis(ServiceRadar.Repo) == nil

    session_id = Ecto.UUID.generate()
    transfer_id = Ecto.UUID.generate()
    identity_context = identity_context("agent-owned", "partition-a")

    :ok = RemoteAccessPubSub.subscribe(session_id)

    pid =
      start_supervised!(
        {ControlStreamSession, stream: nil},
        id: :dbless_file_transfer_session,
        restart: :temporary
      )

    :sys.replace_state(pid, fn state ->
      %{
        state
        | agent_id: "agent-owned",
          partition_id: "partition-a",
          gateway_node: "gateway-a",
          registered_identity: identity_context
      }
    end)

    frame_data =
      Jason.encode!(%{
        transfer_id: transfer_id,
        status: "completed",
        bytes_transferred: 512,
        files_transferred: 1
      })

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        ControlStreamSession.handle_message(
          pid,
          %Monitoring.ControlStreamRequest{
            payload:
              {:console_frame,
               %Monitoring.ConsoleFrame{
                 session_id: session_id,
                 frame_type: "file_transfer_outcome",
                 data: frame_data,
                 timestamp: 125
               }}
          },
          identity_context
        )

        _ = :sys.get_state(pid)
      end)

    assert log =~ "Remote access file transfer failed because core is unavailable"
    assert_receive {:remote_access_frame, %{session_id: ^session_id, frame_type: "file_transfer_outcome"} = frame_payload}
    assert {:error, :core_unavailable} = ControlStreamSession.handle_file_transfer_frame(frame_payload)
    assert {:error, :repo_unavailable} = RemoteAccessFileTransfers.handle_agent_frame(frame_payload)

    core_node = start_file_transfer_core_peer!(session_id, transfer_id)

    ControlStreamSession.handle_message(
      pid,
      %Monitoring.ControlStreamRequest{
        payload:
          {:console_frame,
           %Monitoring.ConsoleFrame{
             session_id: session_id,
             frame_type: "file_transfer_outcome",
             data: frame_data,
             timestamp: 126
           }}
      },
      identity_context
    )

    assert_receive {:core_transfer_read, ^core_node, ^transfer_id}, 5_000
    assert_receive {:core_transfer_finish, ^core_node, ^transfer_id, %{byte_count: 512, file_count: 1}}, 5_000
    assert_receive {:core_published_audit, ^core_node, audit_event}, 5_000
    assert core_node != node()
    assert audit_event.unmapped["action"] == "remote_access_file_transfer_completed"
    assert audit_event.unmapped["resource_id"] == transfer_id
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

  test "command results broadcast only to the pre-persistence ingress topic" do
    ensure_pubsub!()

    command_id = Ecto.UUID.generate()
    :ok = AgentCommandPubSub.subscribe_ingress()

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
    :ok = AgentCommandPubSub.subscribe_ingress()

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

  test "bounded AWX catalog projections may exceed the generic result cap" do
    ensure_pubsub!()

    command_id = Ecto.UUID.generate()
    :ok = AgentCommandPubSub.subscribe_ingress()
    pid = start_supervised!({ControlStreamSession, stream: nil})

    :sys.replace_state(pid, fn state ->
      %{
        state
        | agent_id: "agent-owned",
          partition_id: "partition-a",
          commands: %{command_id => %{command_type: "awx.list_hosts"}}
      }
    end)

    hosts =
      Enum.map(1..1_500, fn id ->
        %{
          "id" => id,
          "name" => "host-#{String.pad_leading(Integer.to_string(id), 4, "0")}",
          "inventory" => 67,
          "enabled" => true
        }
      end)

    payload =
      Jason.encode!(%{
        "verb" => "awx.list_hosts",
        "ok" => true,
        "count" => length(hosts),
        "pages_walked" => 8,
        "results" => hosts,
        "extra" => %{"inventory_id" => 67}
      })

    assert byte_size(payload) > 64 * 1024

    ControlStreamSession.handle_message(pid, %Monitoring.ControlStreamRequest{
      payload:
        {:command_result,
         %Monitoring.CommandResult{
           command_id: command_id,
           command_type: "awx.list_hosts",
           success: true,
           message: "done",
           payload_json: payload,
           timestamp: 123
         }}
    })

    assert_receive {:command_result,
                    %{
                      command_id: ^command_id,
                      command_type: "awx.list_hosts",
                      success: true,
                      payload: %{"count" => 1_500, "results" => results}
                    }},
                   1_000

    assert length(results) == 1_500
  end

  test "untracked AWX results retain the generic parsing cap" do
    ensure_pubsub!()

    command_id = Ecto.UUID.generate()
    :ok = AgentCommandPubSub.subscribe_ingress()
    pid = start_supervised!({ControlStreamSession, stream: nil})

    :sys.replace_state(pid, fn state ->
      %{state | agent_id: "agent-owned", partition_id: "partition-a", commands: %{}}
    end)

    oversized_payload = Jason.encode!(%{"data" => String.duplicate("x", 70_000)})

    ControlStreamSession.handle_message(pid, %Monitoring.ControlStreamRequest{
      payload:
        {:command_result,
         %Monitoring.CommandResult{
           command_id: command_id,
           command_type: "awx.list_hosts",
           success: true,
           message: "too large",
           payload_json: oversized_payload,
           timestamp: 123
         }}
    })

    assert_receive {:command_result,
                    %{
                      command_id: ^command_id,
                      command_type: "awx.list_hosts",
                      success: false,
                      failure_reason: "automation_command_failed",
                      payload: %{"verb" => "awx.list_hosts", "ok" => false}
                    }},
                   1_000
  end

  test "protected AWX failures are sanitized before gateway broadcast" do
    ensure_pubsub!()

    command_id = Ecto.UUID.generate()
    :ok = AgentCommandPubSub.subscribe_ingress()
    pid = start_supervised!({ControlStreamSession, stream: nil})

    :sys.replace_state(pid, fn state ->
      %{
        state
        | agent_id: "agent-owned",
          partition_id: "partition-a",
          commands: %{command_id => %{command_type: "awx.fetch_job"}}
      }
    end)

    secret = "Bearer gateway-result-must-not-survive"

    ControlStreamSession.handle_message(pid, %Monitoring.ControlStreamRequest{
      payload:
        {:command_result,
         %Monitoring.CommandResult{
           command_id: command_id,
           command_type: "awx.fetch_job",
           success: false,
           message: secret,
           payload_json: Jason.encode!(%{"details" => secret, "raw_result_base64" => secret}),
           timestamp: 123
         }}
    })

    assert_receive {:command_result, safe}, 1_000
    assert safe.command_id == command_id
    assert safe.command_type == "awx.fetch_job"
    assert safe.success == false
    assert safe.message == "automation command failed"
    assert safe.failure_reason == "automation_command_failed"
    assert safe.payload == %{"verb" => "awx.fetch_job", "ok" => false}
    refute inspect(safe) =~ secret
  end

  test "tracked command type cannot be downgraded by agent status echoes" do
    ensure_pubsub!()

    command_id = Ecto.UUID.generate()
    :ok = AgentCommandPubSub.subscribe_ingress()
    pid = start_supervised!({ControlStreamSession, stream: nil})

    :sys.replace_state(pid, fn state ->
      %{
        state
        | agent_id: "agent-owned",
          partition_id: "partition-a",
          commands: %{command_id => %{command_type: "awx.fetch_job"}}
      }
    end)

    secret = "Bearer downgraded-status-must-not-survive"

    ControlStreamSession.handle_message(pid, %Monitoring.ControlStreamRequest{
      payload:
        {:command_ack,
         %Monitoring.CommandAck{
           command_id: command_id,
           command_type: "mtr.run",
           message: secret,
           timestamp: 123
         }}
    })

    ControlStreamSession.handle_message(pid, %Monitoring.ControlStreamRequest{
      payload:
        {:command_progress,
         %Monitoring.CommandProgress{
           command_id: command_id,
           command_type: "mtr.run",
           progress_percent: 25,
           message: secret,
           payload_json: Jason.encode!(%{"details" => secret}),
           timestamp: 124
         }}
    })

    refute_receive {:command_ack, _}, 50
    refute_receive {:command_progress, _}, 50

    ControlStreamSession.handle_message(pid, %Monitoring.ControlStreamRequest{
      payload:
        {:command_result,
         %Monitoring.CommandResult{
           command_id: command_id,
           command_type: "mtr.run",
           success: true,
           message: secret,
           payload_json: Jason.encode!(%{"details" => secret}),
           timestamp: 125
         }}
    })

    assert_receive {:command_result, safe}, 1_000
    assert safe.command_type == "awx.fetch_job"
    assert safe.success == false
    assert safe.failure_reason == "automation_command_failed"
    assert safe.payload == %{"verb" => "awx.fetch_job", "ok" => false}
    refute inspect(safe) =~ secret
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

    test "hello section statuses are persisted without an ack, debounced against the last stored set",
         %{pid: pid} do
      deferring = [
        %Monitoring.ConfigSectionStatus{section: "bumblebee", disposition: "success"},
        %Monitoring.ConfigSectionStatus{
          section: "addons",
          disposition: "transient_failure",
          error: "one or more add-on assignments did not apply yet: addon-a",
          since: 1_782_000_000
        }
      ]

      hello = %Monitoring.ControlStreamHello{
        agent_id: "agent-ack",
        config_version: "v1",
        config_section_statuses: deferring
      }

      send_hello = fn ->
        ControlStreamSession.handle_message(pid, %Monitoring.ControlStreamRequest{payload: {:hello, hello}})
      end

      send_hello.()

      assert_receive {:config_sync, :record_config_section_statuses, ["agent-ack", attrs]}

      assert [
               %{"section" => "bumblebee", "disposition" => "success"},
               %{"section" => "addons", "disposition" => "transient_failure"} = failing
             ] = attrs.section_statuses

      assert failing["error"] =~ "addon-a"
      assert failing["since"] == 1_782_000_000 |> DateTime.from_unix!() |> DateTime.to_iso8601()

      # The 60s heartbeat repeats the same state: not re-sent.
      send_hello.()
      refute_receive {:config_sync, :record_config_section_statuses, _args}, 100

      # A sectioned ack replaces the stored statuses, so the same hello state after
      # it must be persisted again rather than debounced against the older hello.
      ControlStreamSession.handle_message(pid, %Monitoring.ControlStreamRequest{
        payload:
          {:config_ack,
           %Monitoring.ConfigAck{
             config_version: "v2",
             timestamp: 1_782_000_100,
             section_statuses: [
               %Monitoring.ConfigSectionStatus{
                 section: "addons",
                 disposition: "permanent_failure",
                 error: "addon-a: not found",
                 since: 1_782_000_050
               }
             ]
           }}
      })

      send_hello.()
      assert_receive {:config_sync, :record_config_section_statuses, ["agent-ack", _attrs]}
    end

    test "a slow hello cannot commit section statuses after a later ack", %{pid: pid} do
      parent = self()

      Application.put_env(:serviceradar_agent_gateway, :config_sync_rpc, fn function, args ->
        if function == :record_config_section_statuses do
          send(parent, {:hello_entered, self()})

          receive do
            :release_hello -> :ok
          end
        end

        send(parent, {:committed, function, args})
        :ok
      end)

      hello = %Monitoring.ControlStreamHello{
        agent_id: "agent-ack",
        config_version: "v1",
        config_section_statuses: [
          %Monitoring.ConfigSectionStatus{
            section: "addons",
            disposition: "permanent_failure",
            error: "stuck",
            since: 1
          }
        ]
      }

      ControlStreamSession.handle_message(pid, %Monitoring.ControlStreamRequest{payload: {:hello, hello}})

      assert_receive {:hello_entered, hello_pid}

      ControlStreamSession.handle_message(pid, %Monitoring.ControlStreamRequest{
        payload:
          {:config_ack,
           %Monitoring.ConfigAck{
             config_version: "v1",
             timestamp: 20,
             section_statuses: [
               %Monitoring.ConfigSectionStatus{section: "addons", disposition: "success", since: 2}
             ]
           }}
      })

      refute_receive {:committed, :record_config_ack, [_, %{section_statuses: [_ | _]}]}, 100

      send(hello_pid, :release_hello)

      assert_receive {:committed, :record_config_section_statuses, ["agent-ack", hello_attrs]}

      assert [%{"disposition" => "permanent_failure"}] = hello_attrs.section_statuses

      assert_receive {:committed, :record_config_ack, ["agent-ack", %{section_statuses: [%{"disposition" => "success"}]}]}
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

  defp ensure_process_registry! do
    {:ok, _apps} = Application.ensure_all_started(:horde)

    if !Process.whereis(ProcessRegistry.registry_name()) do
      Enum.each(ProcessRegistry.child_specs(), fn child_spec -> start_supervised!(child_spec) end)
    end
  end

  # A registered session whose stream replies and config-sync writes are
  # captured, for exercising config push delivery.
  defp start_push_session!(agent_id, capabilities, opts \\ []) do
    test_pid = self()

    Application.put_env(:serviceradar_agent_gateway, :control_stream_reply, fn stream, response ->
      send(test_pid, {:stream_reply, response})
      stream
    end)

    Application.put_env(
      :serviceradar_agent_gateway,
      :config_sync_rpc,
      Keyword.get(opts, :config_sync_rpc, fn _function, _args -> :ok end)
    )

    on_exit(fn ->
      Application.delete_env(:serviceradar_agent_gateway, :control_stream_reply)
      Application.delete_env(:serviceradar_agent_gateway, :config_sync_rpc)
    end)

    pid =
      case Keyword.get(opts, :start, :supervised) do
        :linked ->
          start_supervised!(
            {ControlStreamSession, stream: nil},
            id: System.unique_integer([:positive]),
            restart: :temporary
          )

        :supervised ->
          start_supervised!({ControlStreamSession, stream: nil})
      end

    assert :ok =
             ControlStreamSession.register(
               pid,
               agent_id,
               "partition-a",
               capabilities,
               identity_context(agent_id, "partition-a"),
               Keyword.get(opts, :hello)
             )

    pid
  end

  # The shape core's AgentConfigGenerator returns from get_config_if_changed.
  defp generated_config(version) do
    %{
      config_version: version,
      config_timestamp: 1_700_000_000,
      heartbeat_interval_sec: 30,
      config_poll_interval_sec: 300,
      checks: [],
      plugins: []
    }
  end

  defp receive_config_chunks(acc) do
    receive do
      {:stream_reply, %Monitoring.ControlStreamResponse{payload: {:config_chunk, chunk}}} ->
        if chunk.is_final,
          do: Enum.reverse([chunk | acc]),
          else: receive_config_chunks([chunk | acc])
    after
      1_000 -> flunk("timed out waiting for config chunks; received #{length(acc)}")
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

  defp policy_ack(assignment_id, version, fingerprint) do
    %Monitoring.PluginAssignmentPolicyAck{
      assignment_id: assignment_id,
      plugin_id: "proxmox-console",
      assignment_policy_version: version,
      assignment_policy_fingerprint: fingerprint
    }
  end

  defp assert_registry_evidence(partition_id, agent_id, pid, predicate, attempts \\ 40)

  defp assert_registry_evidence(_partition_id, _agent_id, _pid, _predicate, 0) do
    flunk("timed out waiting for control-session registry evidence")
  end

  defp assert_registry_evidence(partition_id, agent_id, pid, predicate, attempts) do
    metadata = registry_metadata(partition_id, agent_id, pid)

    if metadata && predicate.(metadata) do
      :ok
    else
      Process.sleep(25)
      assert_registry_evidence(partition_id, agent_id, pid, predicate, attempts - 1)
    end
  end

  defp registry_metadata(partition_id, agent_id, pid) do
    partition_id
    |> ProcessRegistry.lookup_agent_control(agent_id)
    |> Enum.find_value(fn
      {^pid, metadata} -> metadata
      _entry -> nil
    end)
  end

  defp start_file_transfer_core_peer!(session_id, transfer_id) do
    if !Node.alive?() do
      {_, 0} = System.cmd("epmd", ["-daemon"])
      {:ok, _} = :net_kernel.start([:gateway_control_stream_test, :shortnames])
      on_exit(fn -> :net_kernel.stop() end)
    end

    basename = "control_stream_core_#{System.unique_integer([:positive])}"

    previous_basename =
      Application.get_env(:serviceradar_agent_gateway, :cluster_core_node_basename)

    Application.put_env(:serviceradar_agent_gateway, :cluster_core_node_basename, basename)

    on_exit(fn ->
      if previous_basename do
        Application.put_env(
          :serviceradar_agent_gateway,
          :cluster_core_node_basename,
          previous_basename
        )
      else
        Application.delete_env(:serviceradar_agent_gateway, :cluster_core_node_basename)
      end
    end)

    peer =
      start_supervised!(%{
        id: :control_stream_core_peer,
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
    :ok = :peer.call(peer, Code, :put_compiler_option, [:ignore_module_conflict, true])

    :ok =
      :peer.call(peer, :persistent_term, :put, [
        :control_stream_test_owner,
        {self(), session_id, transfer_id}
      ])

    :peer.call(peer, Code, :compile_string, [
      """
      if Process.whereis(ServiceRadar.Repo) == nil do
        {:ok, _} = Agent.start(fn -> :ok end, name: ServiceRadar.Repo)
      end

      defmodule ServiceRadar.Events.InternalLogPublisher do
        def publish("audit", event) do
          {owner, _session_id, _transfer_id} = :persistent_term.get(:control_stream_test_owner)
          send(owner, {:core_published_audit, node(), event})
          :ok
        end
      end

      defmodule ServiceRadar.Edge.RemoteAccessRecording do
        def get_by_session(_session_id, _opts), do: {:ok, nil}
      end

      defmodule ServiceRadar.Edge.RemoteAccessFileTransfer do
        def utc_now, do: DateTime.utc_now()

        def get_by_id(transfer_id, _opts) do
          {owner, session_id, expected_transfer_id} = :persistent_term.get(:control_stream_test_owner)
          send(owner, {:core_transfer_read, node(), transfer_id})

          if transfer_id == expected_transfer_id do
            {:ok,
             %{
               id: transfer_id,
               session_id: session_id,
               requested_by: nil,
               device_uid: "sr:device-1",
               target_kind: :device,
               target_host: "192.0.2.10",
               target_port: 22,
               agent_id: "agent-owned",
               gateway_id: "gateway-a",
               operation: :download,
               direction: :read,
               protocol: :sftp,
               credential_custody_mode: :ssh_certificate,
               target_path: "/var/log/app.log",
               redacted_path: "/var/log/app.log",
               path_hash: String.duplicate("a", 64),
               byte_count: 0,
               file_count: 0,
               policy_decision: %{allowed: true, content_audit_retain: false},
               quota_snapshot: %{max_bytes: 10_000},
               approval_id: nil,
               content_audit_retained: false,
               content_artifact_ref: %{},
               status: :in_progress
             }}
          else
            {:error, :not_found}
          end
        end

        def finish(transfer, attrs, _opts) do
          {owner, _session_id, _expected_transfer_id} = :persistent_term.get(:control_stream_test_owner)
          send(owner, {:core_transfer_finish, node(), transfer.id, Map.take(attrs, [:byte_count, :file_count])})
          {:ok, Map.merge(transfer, Map.put(attrs, :status, :completed))}
        end
      end
      """
    ])

    true = Node.connect(core_node)
    core_node
  end
end
