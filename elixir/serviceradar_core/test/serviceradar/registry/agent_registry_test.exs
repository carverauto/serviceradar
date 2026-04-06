defmodule ServiceRadar.AgentRegistryTest do
  @moduledoc """
  Tests for AgentRegistry functionality including gRPC address resolution.

  Verifies that:
  - Agents can be registered with gRPC connection details
  - gRPC addresses can be looked up by agent ID
  - Registry properly supports gateway discovery of agents

  Note: Each single-deployment instance runs its own ERTS cluster with isolated
  resources. Deployment isolation is handled by infrastructure (separate
  deployments with PostgreSQL search_path determining the schema).
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.AgentRegistry
  alias ServiceRadar.TestSupport

  @moduletag :database

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    unique_id = :erlang.unique_integer([:positive])

    # ProcessRegistry is started by the application supervision tree

    {:ok, unique_id: unique_id}
  end

  describe "register_agent/2" do
    test "registers agent with gRPC details", %{unique_id: unique_id} do
      agent_id = "agent-reg-#{unique_id}"

      result =
        AgentRegistry.register_agent(agent_id, %{
          partition_id: "partition-1",
          grpc_host: "192.168.1.100",
          grpc_port: 50_051,
          capabilities: [:icmp, :tcp],
          status: :connected
        })

      assert {:ok, _pid} = result
    end

    test "registers agent and can be looked up", %{unique_id: unique_id} do
      agent_id = "agent-lookup-#{unique_id}"

      {:ok, _pid} =
        AgentRegistry.register_agent(agent_id, %{
          grpc_host: "10.0.0.50",
          grpc_port: 50_052,
          capabilities: [:http]
        })

      entries = eventually(fn -> AgentRegistry.lookup(agent_id) end, &(length(&1) == 1))

      [{_pid, metadata}] = entries
      assert metadata[:agent_id] == agent_id
      assert metadata[:grpc_host] == "10.0.0.50"
      assert metadata[:grpc_port] == 50_052
    end

    test "stores capabilities", %{unique_id: unique_id} do
      agent_id = "agent-caps-#{unique_id}"
      capabilities = [:icmp, :tcp, :http, :snmp]

      {:ok, _} =
        AgentRegistry.register_agent(agent_id, %{
          grpc_host: "192.168.1.11",
          grpc_port: 50_051,
          capabilities: capabilities
        })

      [{_pid, metadata}] =
        eventually(fn -> AgentRegistry.lookup(agent_id) end, &(length(&1) == 1))

      assert metadata[:capabilities] == capabilities
    end
  end

  describe "get_grpc_address/1" do
    test "returns host and port for registered agent", %{unique_id: unique_id} do
      agent_id = "agent-grpc-#{unique_id}"
      host = "192.168.1.100"
      port = 50_051

      {:ok, _} =
        AgentRegistry.register_agent(agent_id, %{
          grpc_host: host,
          grpc_port: port
        })

      assert {:ok, {^host, ^port}} =
               eventually(
                 fn -> AgentRegistry.get_grpc_address(agent_id) end,
                 &match?({:ok, {^host, ^port}}, &1)
               )
    end

    test "returns not_found for unregistered agent", %{unique_id: unique_id} do
      agent_id = "agent-not-exist-#{unique_id}"
      assert {:error, :not_found} = AgentRegistry.get_grpc_address(agent_id)
    end

    test "returns no_grpc_address if host is missing", %{unique_id: unique_id} do
      agent_id = "agent-no-host-#{unique_id}"

      {:ok, _} =
        AgentRegistry.register_agent(agent_id, %{
          grpc_port: 50_051
          # No grpc_host
        })

      assert {:error, :no_grpc_address} =
               eventually(
                 fn -> AgentRegistry.get_grpc_address(agent_id) end,
                 &(&1 == {:error, :no_grpc_address})
               )
    end

    test "returns no_grpc_address if port is missing", %{unique_id: unique_id} do
      agent_id = "agent-no-port-#{unique_id}"

      {:ok, _} =
        AgentRegistry.register_agent(agent_id, %{
          grpc_host: "192.168.1.101"
          # No grpc_port
        })

      assert {:error, :no_grpc_address} =
               eventually(
                 fn -> AgentRegistry.get_grpc_address(agent_id) end,
                 &(&1 == {:error, :no_grpc_address})
               )
    end
  end

  describe "find_agents_with_grpc/0" do
    test "returns only agents with complete gRPC addresses", %{unique_id: unique_id} do
      # Agent with gRPC
      {:ok, _} =
        AgentRegistry.register_agent("agent-grpc-a-#{unique_id}", %{
          grpc_host: "192.168.1.100",
          grpc_port: 50_051
        })

      # Agent without gRPC
      {:ok, _} =
        AgentRegistry.register_agent("agent-no-grpc-#{unique_id}", %{
          partition_id: "partition-1"
        })

      # Agent with only host
      {:ok, _} =
        AgentRegistry.register_agent("agent-partial-#{unique_id}", %{
          grpc_host: "192.168.1.102"
        })

      agents =
        eventually(
          fn -> AgentRegistry.find_agents_with_grpc() end,
          &Enum.any?(&1, fn agent -> agent[:agent_id] == "agent-grpc-a-#{unique_id}" end)
        )

      # Should only include the agent with complete gRPC details
      refute Enum.empty?(agents)
      assert Enum.any?(agents, &(&1[:agent_id] == "agent-grpc-a-#{unique_id}"))
      refute Enum.any?(agents, &(&1[:agent_id] == "agent-no-grpc-#{unique_id}"))
      refute Enum.any?(agents, &(&1[:agent_id] == "agent-partial-#{unique_id}"))
    end
  end

  describe "find_agents_with_capability/1" do
    test "returns agents with specified capability", %{unique_id: unique_id} do
      {:ok, _} =
        AgentRegistry.register_agent("agent-icmp-#{unique_id}", %{
          grpc_host: "192.168.1.100",
          grpc_port: 50_051,
          capabilities: [:icmp, :tcp]
        })

      {:ok, _} =
        AgentRegistry.register_agent("agent-http-#{unique_id}", %{
          grpc_host: "192.168.1.101",
          grpc_port: 50_051,
          capabilities: [:http, :tcp]
        })

      {:ok, _} =
        AgentRegistry.register_agent("agent-snmp-#{unique_id}", %{
          grpc_host: "192.168.1.102",
          grpc_port: 50_051,
          capabilities: [:snmp]
        })

      icmp_agents =
        eventually(
          fn -> AgentRegistry.find_agents_with_capability(:icmp) end,
          &(not Enum.empty?(&1))
        )

      tcp_agents =
        eventually(
          fn -> AgentRegistry.find_agents_with_capability(:tcp) end,
          &(length(&1) >= 2)
        )

      snmp_agents =
        eventually(
          fn -> AgentRegistry.find_agents_with_capability(:snmp) end,
          &(not Enum.empty?(&1))
        )

      refute Enum.empty?(icmp_agents)
      assert [_first, _second | _] = tcp_agents
      refute Enum.empty?(snmp_agents)
    end
  end

  describe "find_agents_for_partition/1" do
    test "returns agents in specified partition", %{unique_id: unique_id} do
      agent_p1 = "agent-p1-#{unique_id}"
      agent_p2 = "agent-p2-#{unique_id}"

      {:ok, _} =
        AgentRegistry.register_agent(agent_p1, %{
          partition_id: "partition-1",
          grpc_host: "192.168.1.100",
          grpc_port: 50_051
        })

      {:ok, _} =
        AgentRegistry.register_agent(agent_p2, %{
          partition_id: "partition-2",
          grpc_host: "192.168.1.101",
          grpc_port: 50_051
        })

      all_agents =
        eventually(
          fn -> AgentRegistry.find_agents() end,
          fn agents ->
            Enum.any?(agents, &(&1[:agent_id] == agent_p1)) and
              Enum.any?(agents, &(&1[:agent_id] == agent_p2))
          end
        )

      assert Enum.any?(all_agents, &(&1[:agent_id] == agent_p1))
      assert Enum.any?(all_agents, &(&1[:agent_id] == agent_p2))

      # Now test partition filtering
      p1_agents =
        eventually(
          fn -> AgentRegistry.find_agents_for_partition("partition-1") end,
          &Enum.any?(&1, fn agent -> agent[:agent_id] == agent_p1 end)
        )

      assert Enum.any?(p1_agents, &(&1[:agent_id] == agent_p1))
    end
  end

  describe "unregister_agent/1" do
    test "removes agent from registry", %{unique_id: unique_id} do
      agent_id = "agent-unreg-#{unique_id}"

      {:ok, _} =
        AgentRegistry.register_agent(agent_id, %{
          grpc_host: "192.168.1.100",
          grpc_port: 50_051
        })

      # Verify registered
      assert [_entry] = eventually(fn -> AgentRegistry.lookup(agent_id) end, &(length(&1) == 1))

      # Unregister
      :ok = AgentRegistry.unregister_agent(agent_id)

      # Verify removed
      assert [] = eventually(fn -> AgentRegistry.lookup(agent_id) end, &(&1 == []))
    end
  end

  describe "heartbeat/1" do
    test "updates last_heartbeat timestamp", %{unique_id: unique_id} do
      agent_id = "agent-hb-#{unique_id}"

      {:ok, _} =
        AgentRegistry.register_agent(agent_id, %{
          grpc_host: "192.168.1.100",
          grpc_port: 50_051
        })

      [{_pid, original}] =
        eventually(fn -> AgentRegistry.lookup(agent_id) end, &(length(&1) == 1))

      original_hb = original[:last_heartbeat]

      # Wait a bit
      Process.sleep(100)

      # Send heartbeat
      :ok = AgentRegistry.heartbeat(agent_id)

      [{_pid, updated}] =
        eventually(fn -> AgentRegistry.lookup(agent_id) end, &(length(&1) == 1))

      new_hb = updated[:last_heartbeat]

      # Heartbeat should be updated
      assert DateTime.compare(new_hb, original_hb) in [:eq, :gt]
    end

    test "returns error for non-existent agent", %{unique_id: unique_id} do
      agent_id = "agent-hb-noexist-#{unique_id}"
      assert :error = AgentRegistry.heartbeat(agent_id)
    end
  end

  describe "count/0" do
    test "registered agents are countable", %{unique_id: unique_id} do
      agent_id = "agent-count-#{unique_id}"

      {:ok, _} =
        AgentRegistry.register_agent(agent_id, %{
          grpc_host: "192.168.1.100",
          grpc_port: 50_051
        })

      # Verify agent can be found via lookup
      entries = eventually(fn -> AgentRegistry.lookup(agent_id) end, &(length(&1) == 1))
      assert length(entries) == 1

      # And via find_agents
      agents =
        eventually(
          fn -> AgentRegistry.find_agents() end,
          &Enum.any?(&1, fn agent -> agent[:agent_id] == agent_id end)
        )

      assert Enum.any?(agents, &(&1[:agent_id] == agent_id))
    end
  end

  defp eventually(fun, predicate, attempts \\ 40)

  defp eventually(fun, predicate, attempts) when attempts > 0 do
    value = fun.()

    if predicate.(value) do
      value
    else
      Process.sleep(10)
      eventually(fun, predicate, attempts - 1)
    end
  end

  defp eventually(fun, _predicate, 0), do: fun.()
end
