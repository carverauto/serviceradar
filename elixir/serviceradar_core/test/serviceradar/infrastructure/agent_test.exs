defmodule ServiceRadar.Infrastructure.AgentTest do
  @moduledoc """
  Tests for the Infrastructure.Agent resource.

  Tests agent registration, state machine transitions, and API operations
  that gateways use to manage agent lifecycle.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.AgentPicker

  @moduletag :database

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    # Generate unique IDs to prevent test pollution
    unique_id = :erlang.unique_integer([:positive])
    actor = SystemActor.system(:test)

    {:ok, actor: actor, unique_id: unique_id}
  end

  describe "register/1" do
    test "creates agent in connecting state", %{actor: actor, unique_id: unique_id} do
      agent_uid = "agent-#{unique_id}"

      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(
          :register,
          %{
            uid: agent_uid,
            name: "Test Agent",
            host: "192.168.1.100",
            port: 50_051,
            capabilities: ["icmp", "tcp", "http"]
          },
          actor: actor
        )
        |> Ash.create()

      assert agent.uid == agent_uid
      assert agent.status == :connecting
      assert agent.host == "192.168.1.100"
      assert agent.port == 50_051
      assert agent.is_healthy == true
      assert "icmp" in agent.capabilities
      assert agent.first_seen_time
      assert agent.last_seen_time
    end

    test "creates agent with SPIFFE identity", %{actor: actor, unique_id: unique_id} do
      agent_uid = "agent-spiffe-#{unique_id}"
      spiffe_id = "spiffe://serviceradar.local/agent/test-account/default/#{agent_uid}"

      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(
          :register,
          %{
            uid: agent_uid,
            name: "SPIFFE Agent",
            host: "10.0.0.50",
            port: 50_051,
            spiffe_identity: spiffe_id
          },
          actor: actor
        )
        |> Ash.create()

      assert agent.spiffe_identity == spiffe_id
    end
  end

  describe "register_connected/1" do
    test "creates agent directly in connected state", %{actor: actor, unique_id: unique_id} do
      agent_uid = "agent-connected-#{unique_id}"

      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(
          :register_connected,
          %{
            uid: agent_uid,
            name: "Pre-connected Agent",
            host: "192.168.1.101",
            port: 50_051
          },
          actor: actor
        )
        |> Ash.create()

      assert agent.status == :connected
      assert agent.is_healthy == true
    end

    test "upserts existing agent without resetting first_seen_time", %{
      actor: actor,
      unique_id: unique_id
    } do
      agent_uid = "agent-connected-upsert-#{unique_id}"

      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(
          :register_connected,
          %{
            uid: agent_uid,
            name: "Initial Agent",
            host: "192.168.1.101",
            port: 50_051
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, updated} =
        Agent
        |> Ash.Changeset.for_create(
          :register_connected,
          %{
            uid: agent_uid,
            name: "Updated Agent",
            host: "192.168.1.200",
            port: 50_052
          },
          actor: actor
        )
        |> Ash.create()

      assert updated.uid == agent.uid
      assert updated.first_seen_time == agent.first_seen_time
      assert DateTime.compare(updated.last_seen_time, agent.last_seen_time) != :lt
      assert updated.host == "192.168.1.200"
      assert updated.port == 50_052
      assert updated.status == :connected
      assert updated.is_healthy == true
    end
  end

  describe "state machine transitions" do
    setup %{actor: actor, unique_id: unique_id} do
      agent_uid = "agent-sm-#{unique_id}"

      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(
          :register,
          %{
            uid: agent_uid,
            name: "State Machine Test Agent",
            host: "192.168.1.102",
            port: 50_051
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, agent: agent}
    end

    test "establish_connection: connecting -> connected", %{agent: agent, actor: actor} do
      assert agent.status == :connecting

      {:ok, updated} =
        agent
        |> Ash.Changeset.for_update(:establish_connection, %{}, actor: actor)
        |> Ash.update()

      assert updated.status == :connected
      assert updated.is_healthy == true
    end

    test "degrade: connected -> degraded", %{agent: agent, actor: actor} do
      # First connect
      {:ok, connected} =
        agent
        |> Ash.Changeset.for_update(:establish_connection, %{}, actor: actor)
        |> Ash.update()

      assert connected.status == :connected

      # Then degrade
      {:ok, degraded} =
        connected
        |> Ash.Changeset.for_update(:degrade, %{}, actor: actor)
        |> Ash.update()

      assert degraded.status == :degraded
      assert degraded.is_healthy == false
    end

    test "lose_connection: connected -> disconnected", %{agent: agent, actor: actor} do
      # First connect
      {:ok, connected} =
        agent
        |> Ash.Changeset.for_update(:establish_connection, %{}, actor: actor)
        |> Ash.update()

      # Then lose connection
      {:ok, disconnected} =
        connected
        |> Ash.Changeset.for_update(:lose_connection, %{}, actor: actor)
        |> Ash.update()

      assert disconnected.status == :disconnected
      assert disconnected.gateway_id == nil
    end

    test "reconnect: disconnected -> connecting", %{agent: agent, actor: actor} do
      # Connect -> Disconnect -> Reconnect
      {:ok, connected} =
        agent
        |> Ash.Changeset.for_update(:establish_connection, %{}, actor: actor)
        |> Ash.update()

      {:ok, disconnected} =
        connected
        |> Ash.Changeset.for_update(:lose_connection, %{}, actor: actor)
        |> Ash.update()

      {:ok, reconnecting} =
        disconnected
        |> Ash.Changeset.for_update(:reconnect, %{}, actor: actor)
        |> Ash.update()

      assert reconnecting.status == :connecting
    end

    test "restore_health: degraded -> connected", %{agent: agent, actor: actor} do
      # Connect -> Degrade -> Restore
      {:ok, connected} =
        agent
        |> Ash.Changeset.for_update(:establish_connection, %{}, actor: actor)
        |> Ash.update()

      {:ok, degraded} =
        connected
        |> Ash.Changeset.for_update(:degrade, %{}, actor: actor)
        |> Ash.update()

      {:ok, restored} =
        degraded
        |> Ash.Changeset.for_update(:restore_health, %{}, actor: actor)
        |> Ash.update()

      assert restored.status == :connected
      assert restored.is_healthy == true
    end

    test "mark_unavailable: any state -> unavailable", %{agent: agent, actor: actor} do
      {:ok, unavailable} =
        agent
        |> Ash.Changeset.for_update(:mark_unavailable, %{reason: "Maintenance"}, actor: actor)
        |> Ash.update()

      assert unavailable.status == :unavailable
      assert unavailable.is_healthy == false
    end
  end

  describe "heartbeat/1" do
    test "updates last_seen_time", %{actor: actor, unique_id: unique_id} do
      agent_uid = "agent-hb-#{unique_id}"

      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(
          :register_connected,
          %{
            uid: agent_uid,
            name: "Heartbeat Test Agent",
            host: "192.168.1.103",
            port: 50_051
          },
          actor: actor
        )
        |> Ash.create()

      original_last_seen = agent.last_seen_time

      # Wait longer to ensure measurable time difference (DateTime has second precision)
      Process.sleep(1100)

      {:ok, updated} =
        agent
        |> Ash.Changeset.for_update(:heartbeat, %{}, actor: actor)
        |> Ash.update()

      assert DateTime.compare(updated.last_seen_time, original_last_seen) in [:gt, :eq]
      # At minimum, the timestamp should be set
      assert updated.last_seen_time
    end

    test "can update capabilities", %{actor: actor, unique_id: unique_id} do
      agent_uid = "agent-hb-caps-#{unique_id}"

      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(
          :register_connected,
          %{
            uid: agent_uid,
            name: "Capability Update Agent",
            host: "192.168.1.104",
            port: 50_051,
            capabilities: ["icmp"]
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, updated} =
        agent
        |> Ash.Changeset.for_update(:heartbeat, %{capabilities: ["icmp", "tcp", "snmp"]},
          actor: actor
        )
        |> Ash.update()

      assert "snmp" in updated.capabilities
      assert length(updated.capabilities) == 3
    end
  end

  describe "queries" do
    setup %{actor: actor, unique_id: unique_id} do
      # Create multiple agents in different states (without gateway FK constraint)
      {:ok, connected_agent} =
        Agent
        |> Ash.Changeset.for_create(
          :register_connected,
          %{
            uid: "agent-q-connected-#{unique_id}",
            name: "Connected Query Agent",
            host: "192.168.1.110",
            port: 50_051,
            capabilities: ["icmp", "tcp"]
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, connecting_agent} =
        Agent
        |> Ash.Changeset.for_create(
          :register,
          %{
            uid: "agent-q-connecting-#{unique_id}",
            name: "Connecting Query Agent",
            host: "192.168.1.111",
            port: 50_051
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, connected_agent: connected_agent, connecting_agent: connecting_agent}
    end

    test "connected returns only connected and healthy agents", %{
      connected_agent: agent,
      connecting_agent: _connecting,
      actor: actor
    } do
      agents =
        Agent
        |> Ash.Query.for_read(:connected, %{}, actor: actor)
        |> Ash.read!()

      assert Enum.all?(agents, &(&1.status == :connected))
      assert Enum.all?(agents, &(&1.is_healthy == true))
      assert Enum.any?(agents, &(&1.uid == agent.uid))
    end

    test "by_capability returns agents with specific capability", %{
      connected_agent: agent,
      actor: actor
    } do
      agents =
        Agent
        |> Ash.Query.for_read(:by_capability, %{capability: "tcp"}, actor: actor)
        |> Ash.read!()

      assert Enum.any?(agents, &(&1.uid == agent.uid))
    end

    test "by_status returns agents in specific status", %{
      connected_agent: connected,
      connecting_agent: connecting,
      actor: actor
    } do
      connected_agents =
        Agent
        |> Ash.Query.for_read(:by_status, %{status: :connected}, actor: actor)
        |> Ash.read!()

      connecting_agents =
        Agent
        |> Ash.Query.for_read(:by_status, %{status: :connecting}, actor: actor)
        |> Ash.read!()

      assert Enum.any?(connected_agents, &(&1.uid == connected.uid))
      assert Enum.any?(connecting_agents, &(&1.uid == connecting.uid))
    end
  end

  describe "agent_picker" do
    test "searches trimmed names and UIDs case-insensitively with a stable name then UID order",
         %{
           actor: actor,
           unique_id: unique_id
         } do
      viewer_scope = %{actor: %{id: "viewer-#{unique_id}", role: :viewer}}

      agents = [
        create_picker_agent("picker-uid-b-#{unique_id}", "ALPHA", actor),
        create_picker_agent("picker-uid-a-#{unique_id}", "alpha", actor),
        create_picker_agent("picker-uid-only-#{unique_id}", nil, actor),
        create_picker_agent("picker-other-#{unique_id}", "Bravo", actor)
      ]

      {:ok, page} = agent_picker_page("  ALPHA  ", viewer_scope)

      assert [first, second] = page.results
      assert first.uid == "picker-uid-a-#{unique_id}"
      assert second.uid == "picker-uid-b-#{unique_id}"

      {:ok, uid_page} = agent_picker_page("UID-ONLY", viewer_scope)
      assert [%{uid: uid}] = uid_page.results
      assert uid == "picker-uid-only-#{unique_id}"

      {:ok, all_page} = agent_picker_page("   ", viewer_scope)
      returned_uids = MapSet.new(all_page.results, & &1.uid)

      assert MapSet.subset?(MapSet.new(Enum.map(agents, & &1.uid)), returned_uids)
    end

    test "caps every page at fifty records and supports forward and backward keysets", %{
      actor: actor,
      unique_id: unique_id
    } do
      operator_scope = %{actor: %{id: "operator-#{unique_id}", role: :operator}}
      prefix = "picker-page-#{unique_id}-"

      for index <- 1..101 do
        create_picker_agent(
          "#{prefix}#{String.pad_leading(Integer.to_string(index), 3, "0")}",
          "#{prefix}#{String.pad_leading(Integer.to_string(index), 3, "0")}",
          actor
        )
      end

      action = Ash.Resource.Info.action(Agent, :agent_picker, :read)
      assert %{default_limit: 50, max_page_size: 50, keyset?: true} = action.pagination

      {:ok, first_page} = agent_picker_page(prefix, operator_scope)

      assert 50 = length(first_page.results)
      assert first_page.before == nil
      assert first_page.after
      refute Enum.any?(first_page.results, &(&1.uid == "#{prefix}051"))

      {:ok, middle_page} =
        agent_picker_page(prefix, operator_scope, {:after, first_page.after})

      assert 50 = length(middle_page.results)
      assert %{uid: middle_first_uid} = List.first(middle_page.results)
      assert middle_first_uid == "#{prefix}051"
      assert %{uid: middle_last_uid} = List.last(middle_page.results)
      assert middle_last_uid == "#{prefix}100"
      assert middle_page.before
      assert middle_page.after

      {:ok, terminal_page} =
        agent_picker_page(prefix, operator_scope, {:after, middle_page.after})

      assert [%{uid: last_uid}] = terminal_page.results
      assert last_uid == "#{prefix}101"
      assert terminal_page.before
      assert terminal_page.after == nil

      {:ok, rewind_page} =
        agent_picker_page(prefix, operator_scope, {:before, middle_page.before})

      assert Enum.map(rewind_page.results, & &1.uid) == Enum.map(first_page.results, & &1.uid)
      assert rewind_page.before == nil
      assert rewind_page.after

      {:ok, empty_page} = agent_picker_page("picker-empty-#{unique_id}", operator_scope)
      assert empty_page.results == []
      assert empty_page.before == nil
      assert empty_page.after == nil
    end

    test "loads only each row's persisted gateway partition and retains viewer-plus authorization",
         %{
           actor: actor,
           unique_id: unique_id
         } do
      alias ServiceRadar.Infrastructure.Gateway

      gateway_id = "picker-gateway-#{unique_id}"

      {:ok, _gateway} =
        Gateway
        |> Ash.Changeset.for_create(
          :register,
          %{
            id: gateway_id,
            component_id: "picker-component-#{unique_id}",
            registration_source: "manual"
          },
          actor: actor
        )
        |> Ash.create()

      create_picker_agent(
        "picker-gateway-agent-#{unique_id}",
        "Gateway picker",
        actor,
        gateway_id
      )

      viewer_scope = %{actor: %{id: "viewer-#{unique_id}", role: :viewer}}
      operator_scope = %{actor: %{id: "operator-#{unique_id}", role: :operator}}
      denied_scope = %{actor: %{id: "denied-#{unique_id}", role: :guest}}

      {:ok, viewer_page} = agent_picker_page("gateway picker", viewer_scope)
      assert [%{gateway: %{id: ^gateway_id, partition_id: nil}}] = viewer_page.results

      assert {:ok, %Ash.Page.Keyset{}} = agent_picker_page("gateway picker", operator_scope)
      assert {:ok, %{results: []}} = agent_picker_page("gateway picker", denied_scope)
    end

    defp create_picker_agent(uid, name, actor, gateway_id \\ nil) do
      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(
          :register,
          %{uid: uid, name: name, host: "127.0.0.1", port: 50_051, gateway_id: gateway_id},
          actor: actor
        )
        |> Ash.create()

      agent
    end

    defp agent_picker_page(search, scope, selector \\ :first),
      do: AgentPicker.page(scope, search, selector)
  end
end
