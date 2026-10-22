defmodule ServiceRadar.Infrastructure.AgentTest do
  @moduledoc """
  Tests for Agent resource and state machine transitions.

  Verifies:
  - Agent registration and CRUD
  - State machine transitions (connecting → connected → degraded → disconnected → unavailable)
  - Read actions (by_uid, by_gateway, connected, by_status)
  - Calculations (type_name, is_online, status_color)
  - Operator display name and description
  - Policy enforcement
  """
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias Ash.Error.Forbidden
  alias Ash.Error.Invalid
  alias ServiceRadar.Infrastructure.Agent

  require Ash.Query

  @moduletag :web_ng_shared_fixture_db

  describe "agent registration" do
    setup do
      gateway = gateway_fixture()
      {:ok, gateway: gateway}
    end

    test "can register an agent with required fields", %{gateway: gateway} do
      result =
        Agent
        |> Ash.Changeset.for_create(
          :register,
          %{
            uid: "agent-test-001",
            name: "Test Agent",
            type_id: 4,
            gateway_id: gateway.id
          },
          actor: system_actor()
        )
        |> Ash.create()

      assert {:ok, agent} = result
      assert agent.uid == "agent-test-001"
      assert agent.name == "Test Agent"
      assert agent.type_id == 4
      # Default initial state
      assert agent.status == :connecting
      assert agent.is_healthy == true
    end

    test "can register agent as already connected", %{gateway: gateway} do
      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(
          :register_connected,
          %{
            uid: "agent-connected-001",
            gateway_id: gateway.id
          },
          actor: system_actor()
        )
        |> Ash.create()

      assert agent.status == :connected
      assert agent.is_healthy == true
    end

    test "sets timestamps on registration", %{gateway: gateway} do
      agent = agent_fixture(gateway)

      assert agent.first_seen_time
      assert agent.last_seen_time
      assert agent.created_time
      assert DateTime.diff(DateTime.utc_now(), agent.first_seen_time, :second) < 60
    end

    test "supports all OCSF agent type IDs", %{gateway: gateway} do
      for type_id <- [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 99] do
        unique = System.unique_integer([:positive])

        agent =
          agent_fixture(gateway, %{uid: "agent-type-#{type_id}-#{unique}", type_id: type_id})

        assert agent.type_id == type_id
      end
    end
  end

  describe "state machine - connection lifecycle" do
    setup do
      gateway = gateway_fixture()
      # Start with agent in connecting state
      # starts in :connecting by default
      agent = agent_fixture(gateway)
      {:ok, gateway: gateway, agent: agent}
    end

    test "can establish connection from connecting state", %{
      gateway: gateway,
      agent: agent
    } do
      actor = operator_actor()

      {:ok, connected} =
        agent
        |> Ash.Changeset.for_update(:establish_connection, %{gateway_id: gateway.id}, actor: actor)
        |> Ash.update()

      assert connected.status == :connected
      assert connected.is_healthy == true
      assert connected.last_seen_time
    end

    test "can mark connection as failed from connecting state", %{agent: agent} do
      actor = operator_actor()

      {:ok, disconnected} =
        agent
        |> Ash.Changeset.for_update(:connection_failed, %{}, actor: actor)
        |> Ash.update()

      assert disconnected.status == :disconnected
    end
  end

  describe "state machine - health degradation" do
    setup do
      gateway = gateway_fixture()

      # Create agent in connected state
      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(
          :register_connected,
          %{
            uid: "agent-health-test-#{System.unique_integer([:positive])}",
            gateway_id: gateway.id
          },
          actor: system_actor()
        )
        |> Ash.create()

      {:ok, gateway: gateway, agent: agent}
    end

    test "admin can degrade connected agent", %{agent: agent} do
      actor = admin_actor()

      {:ok, degraded} =
        agent
        |> Ash.Changeset.for_update(:degrade, %{}, actor: actor)
        |> Ash.update()

      assert degraded.status == :degraded
      assert degraded.is_healthy == false
    end

    test "admin can restore health from degraded state", %{agent: agent} do
      actor = admin_actor()

      # First degrade
      {:ok, degraded} =
        agent
        |> Ash.Changeset.for_update(:degrade, %{}, actor: actor)
        |> Ash.update()

      # Then restore
      {:ok, restored} =
        degraded
        |> Ash.Changeset.for_update(:restore_health, %{}, actor: actor)
        |> Ash.update()

      assert restored.status == :connected
      assert restored.is_healthy == true
    end

    test "operator can degrade agent", %{agent: agent} do
      actor = operator_actor()

      result =
        agent
        |> Ash.Changeset.for_update(:degrade, %{}, actor: actor)
        |> Ash.update()

      assert {:ok, degraded} = result
      assert degraded.status == :degraded
    end
  end

  describe "state machine - disconnection" do
    setup do
      gateway = gateway_fixture()

      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(
          :register_connected,
          %{
            uid: "agent-disconnect-test-#{System.unique_integer([:positive])}",
            gateway_id: gateway.id
          },
          actor: system_actor()
        )
        |> Ash.create()

      {:ok, gateway: gateway, agent: agent}
    end

    test "can lose connection from connected state", %{agent: agent} do
      actor = operator_actor()

      {:ok, disconnected} =
        agent
        |> Ash.Changeset.for_update(:lose_connection, %{}, actor: actor)
        |> Ash.update()

      assert disconnected.status == :disconnected
      assert disconnected.gateway_id == nil
    end

    test "can reconnect from disconnected state", %{agent: agent} do
      actor = operator_actor()

      # First disconnect
      {:ok, disconnected} =
        agent
        |> Ash.Changeset.for_update(:lose_connection, %{}, actor: actor)
        |> Ash.update()

      # Then reconnect
      {:ok, reconnecting} =
        disconnected
        |> Ash.Changeset.for_update(:reconnect, %{}, actor: actor)
        |> Ash.update()

      assert reconnecting.status == :connecting
    end
  end

  describe "state machine - unavailable" do
    setup do
      gateway = gateway_fixture()

      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(
          :register_connected,
          %{
            uid: "agent-unavailable-test-#{System.unique_integer([:positive])}",
            gateway_id: gateway.id
          },
          actor: system_actor()
        )
        |> Ash.create()

      {:ok, gateway: gateway, agent: agent}
    end

    test "admin can mark agent as unavailable", %{agent: agent} do
      actor = admin_actor()

      {:ok, unavailable} =
        agent
        |> Ash.Changeset.for_update(:mark_unavailable, %{reason: "Maintenance"}, actor: actor)
        |> Ash.update()

      assert unavailable.status == :unavailable
      assert unavailable.is_healthy == false
    end

    test "admin can recover agent from unavailable state", %{agent: agent} do
      actor = admin_actor()

      # First mark unavailable
      {:ok, unavailable} =
        agent
        |> Ash.Changeset.for_update(:mark_unavailable, %{}, actor: actor)
        |> Ash.update()

      # Then recover
      {:ok, recovering} =
        unavailable
        |> Ash.Changeset.for_update(:recover, %{}, actor: actor)
        |> Ash.update()

      assert recovering.status == :connecting
    end

    test "cannot transition to invalid state", %{agent: agent} do
      actor = admin_actor()

      # Agent is in :connected state, cannot transition to :connecting via reconnect
      # (reconnect is only valid from :disconnected)
      result =
        agent
        |> Ash.Changeset.for_update(:reconnect, %{}, actor: actor)
        |> Ash.update()

      assert {:error, _} = result
    end
  end

  describe "read actions" do
    setup do
      gateway = gateway_fixture()

      # Connected agent
      {:ok, agent_connected} =
        Agent
        |> Ash.Changeset.for_create(
          :register_connected,
          %{
            uid: "agent-connected-read",
            gateway_id: gateway.id
          },
          actor: system_actor()
        )
        |> Ash.create()

      # Connecting agent
      agent_connecting = agent_fixture(gateway, %{uid: "agent-connecting-read"})

      {:ok, gateway: gateway, agent_connected: agent_connected, agent_connecting: agent_connecting}
    end

    test "by_uid returns specific agent", %{agent_connected: agent} do
      actor = viewer_actor()

      {:ok, found} =
        Agent
        |> Ash.Query.for_read(:by_uid, %{uid: agent.uid}, actor: actor)
        |> Ash.read_one()

      assert found.uid == agent.uid
    end

    test "by_gateway returns agents for specific gateway", %{
      gateway: gateway,
      agent_connected: agent
    } do
      actor = viewer_actor()

      {:ok, agents} =
        Agent
        |> Ash.Query.for_read(:by_gateway, %{gateway_id: gateway.id}, actor: actor)
        |> Ash.read()

      uids = Enum.map(agents, & &1.uid)
      assert agent.uid in uids
    end

    test "connected action returns only connected healthy agents", %{
      agent_connected: connected,
      agent_connecting: connecting
    } do
      actor = viewer_actor()

      {:ok, agents} = Ash.read(Agent, action: :connected, actor: actor)
      uids = Enum.map(agents, & &1.uid)

      assert connected.uid in uids
      refute connecting.uid in uids
    end

    test "by_status filters by status", %{agent_connecting: connecting} do
      actor = viewer_actor()

      {:ok, agents} =
        Agent
        |> Ash.Query.for_read(:by_status, %{status: :connecting}, actor: actor)
        |> Ash.read()

      uids = Enum.map(agents, & &1.uid)
      assert connecting.uid in uids
    end
  end

  describe "calculations" do
    setup do
      gateway = gateway_fixture()
      {:ok, gateway: gateway}
    end

    test "type_name returns correct OCSF type names", %{gateway: gateway} do
      actor = viewer_actor()

      type_map = %{
        0 => "Unknown",
        1 => "EDR",
        4 => "Performance",
        6 => "Log Management",
        99 => "Other"
      }

      for {type_id, expected_name} <- type_map do
        unique = System.unique_integer([:positive])

        agent =
          agent_fixture(gateway, %{uid: "agent-type-calc-#{type_id}-#{unique}", type_id: type_id})

        {:ok, [loaded]} =
          Agent
          |> Ash.Query.filter(uid == ^agent.uid)
          |> Ash.Query.load(:type_name)
          |> Ash.read(actor: actor)

        assert loaded.type_name == expected_name
      end
    end

    test "listed_name prefers the operator label, then the reported name, then the host, then the uid",
         %{gateway: gateway} do
      operator = operator_actor()

      named =
        agent_fixture(gateway, %{
          name: "Gateway Reported",
          host: "192.0.2.10"
        })

      assert Agent.listed_name(named) == "Gateway Reported"

      assert Agent.listed_name(%{
               "display_name" => "North Sensor",
               "name" => "Gateway Reported",
               "host" => "192.0.2.10",
               "uid" => named.uid
             }) == "North Sensor"

      assert Agent.listed_name(%{"host" => "192.0.2.11", "uid" => "agent-host-only"}) ==
               "192.0.2.11"

      assert Agent.listed_name(%{"uid" => "agent-uid-only"}) == "agent-uid-only"
      assert Agent.listed_name(%{}) == "—"

      {:ok, labeled} =
        named
        |> Ash.Changeset.for_update(
          :edit_details,
          %{display_name: "  North Sensor  ", description: " Synthetic lab note "},
          actor: operator
        )
        |> Ash.update()

      assert labeled.display_name == "North Sensor"
      assert labeled.description == "Synthetic lab note"
      assert labeled.uid == named.uid
      assert Agent.listed_name(labeled) == "North Sensor"

      {:ok, cleared} =
        labeled
        |> Ash.Changeset.for_update(
          :edit_details,
          %{display_name: "   ", description: ""},
          actor: operator
        )
        |> Ash.update()

      assert cleared.display_name == nil
      assert cleared.description == nil
      assert Agent.listed_name(cleared) == "Gateway Reported"

      host_only =
        agent_fixture(gateway, %{
          name: nil,
          host: "192.0.2.11"
        })

      assert Agent.listed_name(host_only) == "192.0.2.11"

      uid_only = agent_fixture(gateway, %{name: nil, host: nil})
      assert Agent.listed_name(uid_only) == uid_only.uid
    end

    test "status_color returns correct colors for each status", %{
      gateway: gateway
    } do
      actor = admin_actor()

      # Connected healthy = green
      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(
          :register_connected,
          %{
            uid: "agent-color-test-#{System.unique_integer([:positive])}",
            gateway_id: gateway.id
          },
          actor: system_actor()
        )
        |> Ash.create()

      {:ok, [loaded]} =
        Agent
        |> Ash.Query.filter(uid == ^agent.uid)
        |> Ash.Query.load(:status_color)
        |> Ash.read(actor: actor)

      assert loaded.status_color == "green"
    end
  end

  describe "operator details" do
    setup do
      gateway = gateway_fixture()
      {:ok, gateway: gateway}
    end

    test "gateway sync leaves the operator label and note in place", %{gateway: gateway} do
      operator = operator_actor()

      agent =
        agent_fixture(gateway, %{
          name: "Gateway Reported",
          host: "192.0.2.10"
        })

      {:ok, labeled} =
        agent
        |> Ash.Changeset.for_update(
          :edit_details,
          %{display_name: "North Sensor", description: "Synthetic lab note"},
          actor: operator
        )
        |> Ash.update()

      {:ok, synced} =
        labeled
        |> Ash.Changeset.for_update(
          :gateway_sync,
          %{name: "gateway-reported", host: "host01.example.com"},
          actor: system_actor()
        )
        |> Ash.update()

      assert synced.uid == agent.uid
      assert synced.name == "gateway-reported"
      assert synced.host == "host01.example.com"
      assert synced.display_name == "North Sensor"
      assert synced.description == "Synthetic lab note"
    end

    test "a viewer cannot set the operator label", %{gateway: gateway} do
      agent = agent_fixture(gateway, %{name: "Gateway Reported"})

      assert {:error, %Forbidden{}} =
               agent
               |> Ash.Changeset.for_update(
                 :edit_details,
                 %{display_name: "North Sensor", description: "Synthetic lab note"},
                 actor: viewer_actor()
               )
               |> Ash.update()

      {:ok, reloaded} =
        Agent
        |> Ash.Query.filter(uid == ^agent.uid)
        |> Ash.read_one(actor: system_actor())

      assert reloaded.display_name == nil
      assert reloaded.description == nil
      assert reloaded.name == "Gateway Reported"
    end

    test "edit_details rejects a display name longer than 200 characters", %{gateway: gateway} do
      agent = agent_fixture(gateway, %{name: "Gateway Reported"})

      assert {:error, %Invalid{}} =
               agent
               |> Ash.Changeset.for_update(
                 :edit_details,
                 %{display_name: String.duplicate("n", 201)},
                 actor: operator_actor()
               )
               |> Ash.update()

      {:ok, reloaded} =
        Agent
        |> Ash.Query.filter(uid == ^agent.uid)
        |> Ash.read_one(actor: system_actor())

      assert reloaded.display_name == nil
    end
  end
end
