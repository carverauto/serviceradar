defmodule ServiceRadarAgentGateway.ControlStreamSessionTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.AgentCommands.PubSub, as: AgentCommandPubSub
  alias ServiceRadar.Edge.ProxmoxConsolePubSub
  alias ServiceRadar.Edge.RemoteAccessPubSub
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
    assert :ok = ControlStreamSession.register(pid, agent_id, "partition-a", hello.capabilities, identity, hello)

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

    assert_receive {:stream_reply, %Monitoring.ControlStreamResponse{payload: {:config, %{config_version: "config-v2"}}}}

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
end
