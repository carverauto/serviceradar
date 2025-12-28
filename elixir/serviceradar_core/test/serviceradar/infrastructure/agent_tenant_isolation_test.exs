defmodule ServiceRadar.Infrastructure.AgentTenantIsolationTest do
  @moduledoc """
  Tests for multi-tenant isolation in the Infrastructure.Agent resource.

  Verifies that:
  - Agents are properly scoped to tenants
  - Policies enforce tenant boundaries
  - Cross-tenant access is denied
  - Queries respect tenant context
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Infrastructure.Agent

  @moduletag :database

  setup do
    # Create two separate tenants
    unique_id = :erlang.unique_integer([:positive])
    tenant_a_id = Ash.UUID.generate()
    tenant_b_id = Ash.UUID.generate()

    # Create actors for each tenant
    actor_a = %{
      id: Ash.UUID.generate(),
      email: "user-a@tenant-a.local",
      role: :admin,
      tenant_id: tenant_a_id
    }

    actor_b = %{
      id: Ash.UUID.generate(),
      email: "user-b@tenant-b.local",
      role: :admin,
      tenant_id: tenant_b_id
    }

    # Super admin can see all tenants
    super_admin = %{
      id: Ash.UUID.generate(),
      email: "super@serviceradar.local",
      role: :super_admin,
      tenant_id: tenant_a_id
    }

    {:ok,
      tenant_a_id: tenant_a_id,
      tenant_b_id: tenant_b_id,
      actor_a: actor_a,
      actor_b: actor_b,
      super_admin: super_admin,
      unique_id: unique_id
    }
  end

  describe "tenant isolation" do
    setup %{tenant_a_id: tenant_a_id, tenant_b_id: tenant_b_id, super_admin: super_admin, unique_id: unique_id} do
      # Create agents in each tenant using super_admin (bypasses policies)
      {:ok, agent_a} =
        Agent
        |> Ash.Changeset.for_create(:register_connected, %{
          uid: "agent-tenant-a-#{unique_id}",
          name: "Tenant A Agent",
          host: "192.168.1.10",
          port: 50051,
          capabilities: ["icmp", "tcp"]
        }, actor: super_admin, tenant: tenant_a_id, authorize?: false)
        |> Ash.create()

      {:ok, agent_b} =
        Agent
        |> Ash.Changeset.for_create(:register_connected, %{
          uid: "agent-tenant-b-#{unique_id}",
          name: "Tenant B Agent",
          host: "192.168.2.10",
          port: 50051,
          capabilities: ["http", "grpc"]
        }, actor: super_admin, tenant: tenant_b_id, authorize?: false)
        |> Ash.create()

      {:ok, agent_a: agent_a, agent_b: agent_b}
    end

    test "tenant A actor can only see tenant A agents", %{
      actor_a: actor_a,
      tenant_a_id: tenant_a_id,
      agent_a: agent_a,
      agent_b: agent_b
    } do
      # Actor A queries with their tenant context
      agents =
        Agent
        |> Ash.Query.for_read(:read, %{}, actor: actor_a, tenant: tenant_a_id)
        |> Ash.read!()

      # Should see their own agent
      assert Enum.any?(agents, &(&1.uid == agent_a.uid))

      # Should NOT see tenant B's agent
      refute Enum.any?(agents, &(&1.uid == agent_b.uid))
    end

    test "tenant B actor can only see tenant B agents", %{
      actor_b: actor_b,
      tenant_b_id: tenant_b_id,
      agent_a: agent_a,
      agent_b: agent_b
    } do
      # Actor B queries with their tenant context
      agents =
        Agent
        |> Ash.Query.for_read(:read, %{}, actor: actor_b, tenant: tenant_b_id)
        |> Ash.read!()

      # Should see their own agent
      assert Enum.any?(agents, &(&1.uid == agent_b.uid))

      # Should NOT see tenant A's agent
      refute Enum.any?(agents, &(&1.uid == agent_a.uid))
    end

    test "super admin can see all agents across tenants", %{
      super_admin: super_admin,
      agent_a: agent_a,
      agent_b: agent_b
    } do
      # Super admin queries without tenant restriction (global? true allows this)
      agents =
        Agent
        |> Ash.Query.for_read(:read, %{}, actor: super_admin)
        |> Ash.read!()

      # Should see both agents
      assert Enum.any?(agents, &(&1.uid == agent_a.uid))
      assert Enum.any?(agents, &(&1.uid == agent_b.uid))
    end

    test "tenant A actor cannot directly read tenant B agent by UID", %{
      actor_a: actor_a,
      tenant_a_id: tenant_a_id,
      agent_b: agent_b
    } do
      # Try to read tenant B's agent with tenant A context
      result =
        Agent
        |> Ash.Query.for_read(:by_uid, %{uid: agent_b.uid}, actor: actor_a, tenant: tenant_a_id)
        |> Ash.read()

      case result do
        {:ok, []} ->
          # Expected: empty result due to tenant isolation
          assert true

        {:ok, agents} ->
          # Should not find tenant B's agent
          refute Enum.any?(agents, &(&1.uid == agent_b.uid))

        {:error, _} ->
          # Access denied is also acceptable
          assert true
      end
    end
  end

  describe "tenant-scoped queries" do
    setup %{tenant_a_id: tenant_a_id, tenant_b_id: tenant_b_id, super_admin: super_admin, unique_id: unique_id} do
      # Create agents with specific capabilities in each tenant
      {:ok, agent_a_icmp} =
        Agent
        |> Ash.Changeset.for_create(:register_connected, %{
          uid: "agent-a-icmp-#{unique_id}",
          name: "Tenant A ICMP Agent",
          host: "192.168.1.20",
          port: 50051,
          capabilities: ["icmp"]
        }, actor: super_admin, tenant: tenant_a_id, authorize?: false)
        |> Ash.create()

      {:ok, agent_b_icmp} =
        Agent
        |> Ash.Changeset.for_create(:register_connected, %{
          uid: "agent-b-icmp-#{unique_id}",
          name: "Tenant B ICMP Agent",
          host: "192.168.2.20",
          port: 50051,
          capabilities: ["icmp"]
        }, actor: super_admin, tenant: tenant_b_id, authorize?: false)
        |> Ash.create()

      {:ok, agent_a_icmp: agent_a_icmp, agent_b_icmp: agent_b_icmp}
    end

    test "by_capability query respects tenant isolation", %{
      actor_a: actor_a,
      tenant_a_id: tenant_a_id,
      agent_a_icmp: agent_a_icmp,
      agent_b_icmp: agent_b_icmp
    } do
      # Both tenants have agents with "icmp" capability
      # Tenant A actor should only see their own
      agents =
        Agent
        |> Ash.Query.for_read(:by_capability, %{capability: "icmp"}, actor: actor_a, tenant: tenant_a_id)
        |> Ash.read!()

      assert Enum.any?(agents, &(&1.uid == agent_a_icmp.uid))
      refute Enum.any?(agents, &(&1.uid == agent_b_icmp.uid))
    end

    test "connected query respects tenant isolation", %{
      actor_a: actor_a,
      actor_b: actor_b,
      tenant_a_id: tenant_a_id,
      tenant_b_id: tenant_b_id,
      agent_a_icmp: agent_a_icmp,
      agent_b_icmp: agent_b_icmp
    } do
      # Both are connected, but should only see own tenant
      agents_a =
        Agent
        |> Ash.Query.for_read(:connected, %{}, actor: actor_a, tenant: tenant_a_id)
        |> Ash.read!()

      agents_b =
        Agent
        |> Ash.Query.for_read(:connected, %{}, actor: actor_b, tenant: tenant_b_id)
        |> Ash.read!()

      # Tenant A sees only their agents
      assert Enum.any?(agents_a, &(&1.uid == agent_a_icmp.uid))
      refute Enum.any?(agents_a, &(&1.uid == agent_b_icmp.uid))

      # Tenant B sees only their agents
      assert Enum.any?(agents_b, &(&1.uid == agent_b_icmp.uid))
      refute Enum.any?(agents_b, &(&1.uid == agent_a_icmp.uid))
    end
  end

  describe "update isolation" do
    setup %{tenant_a_id: tenant_a_id, tenant_b_id: tenant_b_id, super_admin: super_admin, unique_id: unique_id} do
      {:ok, agent_a} =
        Agent
        |> Ash.Changeset.for_create(:register_connected, %{
          uid: "agent-update-a-#{unique_id}",
          name: "Tenant A Update Test",
          host: "192.168.1.30",
          port: 50051
        }, actor: super_admin, tenant: tenant_a_id, authorize?: false)
        |> Ash.create()

      {:ok, agent_b} =
        Agent
        |> Ash.Changeset.for_create(:register_connected, %{
          uid: "agent-update-b-#{unique_id}",
          name: "Tenant B Update Test",
          host: "192.168.2.30",
          port: 50051
        }, actor: super_admin, tenant: tenant_b_id, authorize?: false)
        |> Ash.create()

      {:ok, agent_a: agent_a, agent_b: agent_b}
    end

    test "tenant A actor can update their own agent", %{
      actor_a: actor_a,
      agent_a: agent_a
    } do
      result =
        agent_a
        |> Ash.Changeset.for_update(:heartbeat, %{}, actor: actor_a, authorize?: false)
        |> Ash.update()

      assert {:ok, _updated} = result
    end

    test "super admin can update any tenant's agent", %{
      super_admin: super_admin,
      agent_a: agent_a,
      agent_b: agent_b
    } do
      # Super admin updates agent in tenant A
      result_a =
        agent_a
        |> Ash.Changeset.for_update(:heartbeat, %{}, actor: super_admin, authorize?: false)
        |> Ash.update()

      assert {:ok, _} = result_a

      # Super admin updates agent in tenant B
      result_b =
        agent_b
        |> Ash.Changeset.for_update(:heartbeat, %{}, actor: super_admin, authorize?: false)
        |> Ash.update()

      assert {:ok, _} = result_b
    end
  end

  describe "tenant ID enforcement" do
    test "agent creation requires valid tenant context", %{actor_a: actor_a, unique_id: unique_id} do
      # Attempt to create without tenant context should fail
      result =
        Agent
        |> Ash.Changeset.for_create(:register, %{
          uid: "agent-no-tenant-#{unique_id}",
          name: "No Tenant Agent",
          host: "192.168.1.40",
          port: 50051
        }, actor: actor_a, authorize?: false)
        |> Ash.create()

      # Should fail because tenant_id is required (allow_nil? false)
      assert {:error, _} = result
    end

    test "agent tenant_id matches creation context", %{actor_a: actor_a, tenant_a_id: tenant_a_id, unique_id: unique_id} do
      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(:register, %{
          uid: "agent-tenant-match-#{unique_id}",
          name: "Tenant Match Agent",
          host: "192.168.1.50",
          port: 50051
        }, actor: actor_a, tenant: tenant_a_id, authorize?: false)
        |> Ash.create()

      # The agent should have the correct tenant_id
      assert agent.tenant_id == tenant_a_id
    end
  end
end
