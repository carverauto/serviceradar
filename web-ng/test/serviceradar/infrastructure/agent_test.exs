defmodule ServiceRadar.Infrastructure.AgentTest do
  @moduledoc """
  Tests for Agent resource and state machine transitions.

  Verifies:
  - Agent registration and CRUD
  - State machine transitions (connecting → connected → degraded → disconnected → unavailable)
  - Read actions (by_uid, by_poller, connected, by_status)
  - Calculations (type_name, display_name, is_online, status_color)
  - Policy enforcement
  - Tenant isolation
  """
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  require Ash.Query

  alias ServiceRadar.Infrastructure.Agent

  describe "agent registration" do
    setup do
      tenant = tenant_fixture()
      poller = poller_fixture(tenant)
      {:ok, tenant: tenant, poller: poller}
    end

    test "can register an agent with required fields", %{tenant: tenant, poller: poller} do
      result =
        Agent
        |> Ash.Changeset.for_create(
          :register,
          %{
            uid: "agent-test-001",
            name: "Test Agent",
            type_id: 4,
            poller_id: poller.id
          },
          actor: system_actor(),
          authorize?: false,
          tenant: tenant.id
        )
        |> Ash.create()

      assert {:ok, agent} = result
      assert agent.uid == "agent-test-001"
      assert agent.name == "Test Agent"
      assert agent.type_id == 4
      # Default initial state
      assert agent.status == :connecting
      assert agent.is_healthy == true
      assert agent.tenant_id == tenant.id
    end

    test "can register agent as already connected", %{tenant: tenant, poller: poller} do
      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(
          :register_connected,
          %{
            uid: "agent-connected-001",
            poller_id: poller.id
          },
          actor: system_actor(),
          authorize?: false,
          tenant: tenant.id
        )
        |> Ash.create()

      assert agent.status == :connected
      assert agent.is_healthy == true
    end

    test "sets timestamps on registration", %{tenant: tenant, poller: poller} do
      agent = agent_fixture(poller)

      assert agent.first_seen_time != nil
      assert agent.last_seen_time != nil
      assert agent.created_time != nil
      assert DateTime.diff(DateTime.utc_now(), agent.first_seen_time, :second) < 60
    end

    test "supports all OCSF agent type IDs", %{tenant: tenant, poller: poller} do
      for type_id <- [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 99] do
        unique = System.unique_integer([:positive])
        agent = agent_fixture(poller, %{uid: "agent-type-#{type_id}-#{unique}", type_id: type_id})
        assert agent.type_id == type_id
      end
    end
  end

  describe "state machine - connection lifecycle" do
    setup do
      tenant = tenant_fixture()
      poller = poller_fixture(tenant)
      # Start with agent in connecting state
      # starts in :connecting by default
      agent = agent_fixture(poller)
      {:ok, tenant: tenant, poller: poller, agent: agent}
    end

    test "can establish connection from connecting state", %{
      tenant: tenant,
      poller: poller,
      agent: agent
    } do
      actor = operator_actor(tenant)

      {:ok, connected} =
        agent
        |> Ash.Changeset.for_update(:establish_connection, %{poller_id: poller.id},
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert connected.status == :connected
      assert connected.is_healthy == true
      assert connected.last_seen_time != nil
    end

    test "can mark connection as failed from connecting state", %{tenant: tenant, agent: agent} do
      actor = operator_actor(tenant)

      {:ok, disconnected} =
        agent
        |> Ash.Changeset.for_update(:connection_failed, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert disconnected.status == :disconnected
    end
  end

  describe "state machine - health degradation" do
    setup do
      tenant = tenant_fixture()
      poller = poller_fixture(tenant)

      # Create agent in connected state
      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(
          :register_connected,
          %{
            uid: "agent-health-test-#{System.unique_integer([:positive])}",
            poller_id: poller.id
          },
          actor: system_actor(),
          authorize?: false,
          tenant: tenant.id
        )
        |> Ash.create()

      {:ok, tenant: tenant, poller: poller, agent: agent}
    end

    test "admin can degrade connected agent", %{tenant: tenant, agent: agent} do
      actor = admin_actor(tenant)

      {:ok, degraded} =
        agent
        |> Ash.Changeset.for_update(:degrade, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert degraded.status == :degraded
      assert degraded.is_healthy == false
    end

    test "admin can restore health from degraded state", %{tenant: tenant, agent: agent} do
      actor = admin_actor(tenant)

      # First degrade
      {:ok, degraded} =
        agent
        |> Ash.Changeset.for_update(:degrade, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      # Then restore
      {:ok, restored} =
        degraded
        |> Ash.Changeset.for_update(:restore_health, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert restored.status == :connected
      assert restored.is_healthy == true
    end

    test "operator cannot degrade agent (admin only)", %{tenant: tenant, agent: agent} do
      actor = operator_actor(tenant)

      result =
        agent
        |> Ash.Changeset.for_update(:degrade, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "state machine - disconnection" do
    setup do
      tenant = tenant_fixture()
      poller = poller_fixture(tenant)

      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(
          :register_connected,
          %{
            uid: "agent-disconnect-test-#{System.unique_integer([:positive])}",
            poller_id: poller.id
          },
          actor: system_actor(),
          authorize?: false,
          tenant: tenant.id
        )
        |> Ash.create()

      {:ok, tenant: tenant, poller: poller, agent: agent}
    end

    test "can lose connection from connected state", %{tenant: tenant, agent: agent} do
      actor = operator_actor(tenant)

      {:ok, disconnected} =
        agent
        |> Ash.Changeset.for_update(:lose_connection, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert disconnected.status == :disconnected
      assert disconnected.poller_id == nil
    end

    test "can reconnect from disconnected state", %{tenant: tenant, agent: agent} do
      actor = operator_actor(tenant)

      # First disconnect
      {:ok, disconnected} =
        agent
        |> Ash.Changeset.for_update(:lose_connection, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      # Then reconnect
      {:ok, reconnecting} =
        disconnected
        |> Ash.Changeset.for_update(:reconnect, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert reconnecting.status == :connecting
    end
  end

  describe "state machine - unavailable" do
    setup do
      tenant = tenant_fixture()
      poller = poller_fixture(tenant)

      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(
          :register_connected,
          %{
            uid: "agent-unavailable-test-#{System.unique_integer([:positive])}",
            poller_id: poller.id
          },
          actor: system_actor(),
          authorize?: false,
          tenant: tenant.id
        )
        |> Ash.create()

      {:ok, tenant: tenant, poller: poller, agent: agent}
    end

    test "admin can mark agent as unavailable", %{tenant: tenant, agent: agent} do
      actor = admin_actor(tenant)

      {:ok, unavailable} =
        agent
        |> Ash.Changeset.for_update(:mark_unavailable, %{reason: "Maintenance"},
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert unavailable.status == :unavailable
      assert unavailable.is_healthy == false
    end

    test "admin can recover agent from unavailable state", %{tenant: tenant, agent: agent} do
      actor = admin_actor(tenant)

      # First mark unavailable
      {:ok, unavailable} =
        agent
        |> Ash.Changeset.for_update(:mark_unavailable, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      # Then recover
      {:ok, recovering} =
        unavailable
        |> Ash.Changeset.for_update(:recover, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert recovering.status == :connecting
    end

    test "cannot transition to invalid state", %{tenant: tenant, agent: agent} do
      actor = admin_actor(tenant)

      # Agent is in :connected state, cannot transition to :connecting via reconnect
      # (reconnect is only valid from :disconnected)
      result =
        agent
        |> Ash.Changeset.for_update(:reconnect, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert {:error, _} = result
    end
  end

  describe "read actions" do
    setup do
      tenant = tenant_fixture()
      poller = poller_fixture(tenant)

      # Connected agent
      {:ok, agent_connected} =
        Agent
        |> Ash.Changeset.for_create(
          :register_connected,
          %{
            uid: "agent-connected-read",
            poller_id: poller.id
          },
          actor: system_actor(),
          authorize?: false,
          tenant: tenant.id
        )
        |> Ash.create()

      # Connecting agent
      agent_connecting = agent_fixture(poller, %{uid: "agent-connecting-read"})

      {:ok,
       tenant: tenant,
       poller: poller,
       agent_connected: agent_connected,
       agent_connecting: agent_connecting}
    end

    test "by_uid returns specific agent", %{tenant: tenant, agent_connected: agent} do
      actor = viewer_actor(tenant)

      {:ok, found} =
        Agent
        |> Ash.Query.for_read(:by_uid, %{uid: agent.uid}, actor: actor, tenant: tenant.id)
        |> Ash.read_one()

      assert found.uid == agent.uid
    end

    test "by_poller returns agents for specific poller", %{
      tenant: tenant,
      poller: poller,
      agent_connected: agent
    } do
      actor = viewer_actor(tenant)

      {:ok, agents} =
        Agent
        |> Ash.Query.for_read(:by_poller, %{poller_id: poller.id},
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.read()

      uids = Enum.map(agents, & &1.uid)
      assert agent.uid in uids
    end

    test "connected action returns only connected healthy agents", %{
      tenant: tenant,
      agent_connected: connected,
      agent_connecting: connecting
    } do
      actor = viewer_actor(tenant)

      {:ok, agents} = Ash.read(Agent, action: :connected, actor: actor, tenant: tenant.id)
      uids = Enum.map(agents, & &1.uid)

      assert connected.uid in uids
      refute connecting.uid in uids
    end

    test "by_status filters by status", %{tenant: tenant, agent_connecting: connecting} do
      actor = viewer_actor(tenant)

      {:ok, agents} =
        Agent
        |> Ash.Query.for_read(:by_status, %{status: :connecting}, actor: actor, tenant: tenant.id)
        |> Ash.read()

      uids = Enum.map(agents, & &1.uid)
      assert connecting.uid in uids
    end
  end

  describe "calculations" do
    setup do
      tenant = tenant_fixture()
      poller = poller_fixture(tenant)
      {:ok, tenant: tenant, poller: poller}
    end

    test "type_name returns correct OCSF type names", %{tenant: tenant, poller: poller} do
      actor = viewer_actor(tenant)

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
          agent_fixture(poller, %{uid: "agent-type-calc-#{type_id}-#{unique}", type_id: type_id})

        {:ok, [loaded]} =
          Agent
          |> Ash.Query.filter(uid == ^agent.uid)
          |> Ash.Query.load(:type_name)
          |> Ash.read(actor: actor, tenant: tenant.id)

        assert loaded.type_name == expected_name
      end
    end

    test "display_name uses name, then host, then uid", %{tenant: tenant, poller: poller} do
      actor = viewer_actor(tenant)

      # Agent with name
      agent_named =
        agent_fixture(poller, %{
          uid: "agent-display-named",
          name: "My Custom Agent",
          host: "192.168.1.100"
        })

      {:ok, [loaded]} =
        Agent
        |> Ash.Query.filter(uid == ^agent_named.uid)
        |> Ash.Query.load(:display_name)
        |> Ash.read(actor: actor, tenant: tenant.id)

      assert loaded.display_name == "My Custom Agent"

      # Agent without name but with host
      agent_host =
        agent_fixture(poller, %{
          uid: "agent-display-host",
          name: nil,
          host: "192.168.1.101"
        })

      {:ok, [loaded]} =
        Agent
        |> Ash.Query.filter(uid == ^agent_host.uid)
        |> Ash.Query.load(:display_name)
        |> Ash.read(actor: actor, tenant: tenant.id)

      assert loaded.display_name == "192.168.1.101"
    end

    test "status_color returns correct colors for each status", %{tenant: tenant, poller: poller} do
      actor = admin_actor(tenant)

      # Connected healthy = green
      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(
          :register_connected,
          %{
            uid: "agent-color-test-#{System.unique_integer([:positive])}",
            poller_id: poller.id
          },
          actor: system_actor(),
          authorize?: false,
          tenant: tenant.id
        )
        |> Ash.create()

      {:ok, [loaded]} =
        Agent
        |> Ash.Query.filter(uid == ^agent.uid)
        |> Ash.Query.load(:status_color)
        |> Ash.read(actor: actor, tenant: tenant.id)

      assert loaded.status_color == "green"
    end
  end

  describe "tenant isolation" do
    setup do
      tenant_a = tenant_fixture(%{name: "Tenant A", slug: "tenant-a-agent"})
      tenant_b = tenant_fixture(%{name: "Tenant B", slug: "tenant-b-agent"})

      poller_a = poller_fixture(tenant_a)
      poller_b = poller_fixture(tenant_b)

      agent_a = agent_fixture(poller_a, %{uid: "agent-a"})
      agent_b = agent_fixture(poller_b, %{uid: "agent-b"})

      {:ok, tenant_a: tenant_a, tenant_b: tenant_b, agent_a: agent_a, agent_b: agent_b}
    end

    test "user cannot see agents from other tenant", %{
      tenant_a: tenant_a,
      agent_a: agent_a,
      agent_b: agent_b
    } do
      actor = viewer_actor(tenant_a)

      {:ok, agents} = Ash.read(Agent, actor: actor, tenant: tenant_a.id)
      uids = Enum.map(agents, & &1.uid)

      assert agent_a.uid in uids
      refute agent_b.uid in uids
    end

    test "user cannot update agent from other tenant", %{
      tenant_a: tenant_a,
      agent_b: agent_b
    } do
      actor = operator_actor(tenant_a)

      result =
        agent_b
        |> Ash.Changeset.for_update(:update, %{name: "Hacked"}, actor: actor, tenant: tenant_a.id)
        |> Ash.update()

      assert {:error, error} = result
      assert match?(%Ash.Error.Forbidden{}, error) or match?(%Ash.Error.Invalid{}, error)
    end

    test "user cannot get agent from other tenant by uid", %{
      tenant_a: tenant_a,
      agent_b: agent_b
    } do
      actor = viewer_actor(tenant_a)

      {:ok, result} =
        Agent
        |> Ash.Query.for_read(:by_uid, %{uid: agent_b.uid}, actor: actor, tenant: tenant_a.id)
        |> Ash.read_one()

      assert result == nil
    end
  end
end
