defmodule ServiceRadar.Edge.ProxmoxConsoleBrokerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.ProxmoxConsoleBroker
  alias ServiceRadar.Edge.ProxmoxConsoleCompatibility

  @required_capabilities ProxmoxConsoleCompatibility.required_capabilities()

  defmodule CommandBusStub do
    @moduledoc false

    def resolve_control_session_evidence(partition_id, agent_id, preferred_gateway_node) do
      send(
        owner(),
        {:resolve_control_session_evidence, partition_id, agent_id, preferred_gateway_node}
      )

      {:ok,
       %{
         control_session_pid: owner(),
         agent_id: agent_id,
         partition_id: partition_id,
         gateway_node: preferred_gateway_node || "gateway@test",
         capabilities: ProxmoxConsoleCompatibility.required_capabilities(),
         config_version: "config-policy-7",
         pending_config_version: nil,
         applied_plugin_assignments: [
           %{
             assignment_id: "assignment-1",
             plugin_id: "proxmox-console",
             assignment_policy_version: 7,
             assignment_policy_fingerprint: String.duplicate("a", 64)
           }
         ]
       }}
    end

    def send_console_frame(agent_id, frame, opts) do
      send(owner(), {:send_console_frame, agent_id, frame, opts})
      :ok
    end

    defp owner, do: Process.whereis(:proxmox_console_broker_test_owner)
  end

  defmodule PubSubStub do
    @moduledoc false

    def subscribe(session_id) do
      send(Process.whereis(:proxmox_console_broker_test_owner), {:subscribe, session_id})
      :ok
    end
  end

  setup do
    owner = self()
    Process.register(owner, :proxmox_console_broker_test_owner)

    on_exit(fn ->
      if Process.whereis(:proxmox_console_broker_test_owner) == owner do
        Process.unregister(:proxmox_console_broker_test_owner)
      end
    end)

    :ok
  end

  test "pins the open to one gateway and rejects frames from any other route" do
    session = session_fixture()

    {:ok, broker} =
      ProxmoxConsoleBroker.start_link(session, self(),
        command_bus: CommandBusStub,
        pubsub: PubSubStub,
        agent_loader: &valid_agent_loader/1,
        required_gateway_node: "gateway@one",
        cols: 132,
        rows: 43
      )

    assert_receive {:resolve_control_session_evidence, "farm01", "agent-1", "gateway@one"}
    assert_receive {:subscribe, "session-1"}

    assert_receive {:send_console_frame, "agent-1", %{frame_type: "open"} = open, opts}
    assert opts[:required_gateway_node] == "gateway@one"
    assert opts[:required_control_session_pid] == self()
    assert opts[:required_control_evidence].control_session_pid == self()
    assert open.assignment_policy_version == 7
    assert open.assignment_policy_fingerprint == String.duplicate("a", 64)

    assert %{
             "session_id" => "session-1",
             "plugin_assignment_id" => "assignment-1",
             "credential_rule_id" => "rule-1"
           } = Jason.decode!(open.data)

    for frame <- [
          routed_frame(session_id: "different-session"),
          routed_frame(agent_id: "different-agent"),
          routed_frame(gateway_node: "gateway@two"),
          routed_frame(agent_id: nil),
          routed_frame(gateway_node: nil)
        ] do
      send(broker, {:proxmox_console_frame, frame})
      refute_receive {:proxmox_console_data, _}, 20
      assert Process.alive?(broker)
    end

    send(broker, {:proxmox_console_frame, routed_frame()})
    assert_receive {:proxmox_console_data, "trusted-output"}

    send(
      broker,
      {:proxmox_console_frame,
       routed_frame(frame_type: "close", reason: "wrong route", gateway_node: "gateway@two")}
    )

    refute_receive {:proxmox_console_closed, _}, 20
    assert Process.alive?(broker)

    ref = Process.monitor(broker)

    send(
      broker,
      {:proxmox_console_frame, routed_frame(frame_type: "close", reason: "complete")}
    )

    assert_receive {:proxmox_console_closed, "complete"}
    assert_receive {:DOWN, ^ref, :process, ^broker, :normal}
  end

  test "fails closed when the session lacks an exact assignment policy binding" do
    session = put_in(session_fixture(), [:metadata, "plugin_assignment_policy_fingerprint"], nil)
    previous_trap_exit = Process.flag(:trap_exit, true)

    assert {:error, :console_assignment_policy_binding_missing} =
             ProxmoxConsoleBroker.start_link(session, self(),
               command_bus: CommandBusStub,
               pubsub: PubSubStub,
               agent_loader: &valid_agent_loader/1,
               required_gateway_node: "gateway@one"
             )

    Process.flag(:trap_exit, previous_trap_exit)

    refute_receive {:resolve_control_session_evidence, _, _, _}
    refute_receive {:send_console_frame, _, _, _}
  end

  test "mixed-version permutations fail closed before subscribe or open dispatch" do
    session = session_fixture()
    fingerprint = String.duplicate("a", 64)

    valid_evidence = %{
      agent_id: "agent-1",
      gateway_node: "gateway@one",
      capabilities: @required_capabilities,
      config_version: "config-policy-7",
      pending_config_version: nil,
      applied_plugin_assignments: [
        %{
          assignment_id: "assignment-1",
          plugin_id: "proxmox-console",
          assignment_policy_version: 7,
          assignment_policy_fingerprint: fingerprint
        }
      ]
    }

    valid_agent = valid_agent_record()

    permutations = [
      {"old agent hello has no explicit capabilities", put_in(valid_evidence.capabilities, []),
       valid_agent, :proxmox_console_upgrade_required},
      {"old gateway has no exact host-parsed proof",
       put_in(valid_evidence.applied_plugin_assignments, []), valid_agent,
       :console_assignment_policy_binding_mismatch},
      {"old persisted agent record has no capabilities", valid_evidence,
       %{valid_agent | capabilities: []}, :proxmox_console_upgrade_required},
      {"old control plane has no persisted config acknowledgement", valid_evidence,
       %{valid_agent | acked_config_version: nil}, :console_config_ack_required},
      {"gateway has dispatched a config the agent has not acknowledged",
       %{valid_evidence | pending_config_version: "config-policy-8"}, valid_agent,
       :console_config_ack_required},
      {"persisted pushed evidence is missing", valid_evidence,
       %{valid_agent | pushed_config_version: nil}, :console_config_ack_required},
      {"a newer pushed config is still pending", valid_evidence,
       %{valid_agent | pushed_config_version: "config-policy-8"}, :console_config_ack_required}
    ]

    Enum.each(permutations, fn {label, evidence, agent, expected_reason} ->
      command_bus = command_bus_for_evidence(evidence)
      previous_trap_exit = Process.flag(:trap_exit, true)

      assert {:error, ^expected_reason} =
               ProxmoxConsoleBroker.start_link(session, self(),
                 command_bus: command_bus,
                 pubsub: PubSubStub,
                 agent_loader: fn "agent-1" -> {:ok, agent} end,
                 required_gateway_node: "gateway@one"
               ),
             label

      Process.flag(:trap_exit, previous_trap_exit)
      refute_receive {:subscribe, "session-1"}, 20, label
      refute_receive {:send_console_frame, _, _, _}, 20, label
    end)
  end

  test "exact live proof mismatch is rejected" do
    session = session_fixture()
    policy = %{version: 7, fingerprint: String.duplicate("a", 64)}

    evidence = %{
      agent_id: "agent-1",
      capabilities: @required_capabilities,
      config_version: "config-policy-7",
      pending_config_version: nil,
      applied_plugin_assignments: [
        %{
          assignment_id: "assignment-1",
          plugin_id: "proxmox-console",
          assignment_policy_version: 8,
          assignment_policy_fingerprint: String.duplicate("b", 64)
        }
      ]
    }

    assert {:error, :console_assignment_policy_binding_mismatch} =
             ProxmoxConsoleCompatibility.verify(session, policy, evidence,
               agent_loader: &valid_agent_loader/1
             )
  end

  defp session_fixture do
    fingerprint = String.duplicate("a", 64)

    %{
      id: "session-1",
      agent_id: "agent-1",
      gateway_id: "logical-gateway-1",
      device_uid: "device-1",
      target_kind: :pve_host,
      console_mode: :ssh,
      credential_rule_id: "rule-1",
      metadata: %{
        "plugin_assignment_id" => "assignment-1",
        "assignment_partition_id" => "farm01",
        "plugin_assignment_version" => 7,
        "plugin_assignment_policy_fingerprint" => fingerprint,
        "credential_rule" => %{
          "assignment_version" => 7,
          "assignment_policy_fingerprint" => fingerprint
        },
        "target" => %{
          "device_uid" => "device-1",
          "ip" => "192.0.2.10",
          "provider_ref" => "proxmox:v3:source:controller:farm:node:pve01"
        }
      }
    }
  end

  defp valid_agent_loader("agent-1"), do: {:ok, valid_agent_record()}

  defp valid_agent_record do
    %{
      uid: "agent-1",
      capabilities: @required_capabilities,
      acked_config_version: "config-policy-7",
      pushed_config_version: "config-policy-7"
    }
  end

  defp command_bus_for_evidence(evidence) do
    module = Module.concat(__MODULE__, "Evidence#{System.unique_integer([:positive])}")

    Module.create(
      module,
      quote do
        def resolve_control_session_evidence(partition_id, agent_id, preferred_gateway_node) do
          send(
            Process.whereis(:proxmox_console_broker_test_owner),
            {:resolve_control_session_evidence, partition_id, agent_id, preferred_gateway_node}
          )

          {:ok,
           unquote(Macro.escape(evidence))
           |> Map.put(:control_session_pid, Process.whereis(:proxmox_console_broker_test_owner))
           |> Map.put(:agent_id, agent_id)
           |> Map.put(:partition_id, partition_id)
           |> Map.put_new(:pending_config_version, nil)}
        end

        def send_console_frame(agent_id, frame, opts) do
          send(
            Process.whereis(:proxmox_console_broker_test_owner),
            {:send_console_frame, agent_id, frame, opts}
          )

          :ok
        end
      end,
      Macro.Env.location(__ENV__)
    )

    module
  end

  defp routed_frame(overrides \\ []) do
    %{
      session_id: Keyword.get(overrides, :session_id, "session-1"),
      agent_id: Keyword.get(overrides, :agent_id, "agent-1"),
      gateway_node: Keyword.get(overrides, :gateway_node, "gateway@one"),
      frame_type: Keyword.get(overrides, :frame_type, "data"),
      data: Keyword.get(overrides, :data, "trusted-output"),
      reason: Keyword.get(overrides, :reason, "")
    }
  end
end
