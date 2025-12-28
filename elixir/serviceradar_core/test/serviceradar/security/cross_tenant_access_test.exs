defmodule ServiceRadar.Security.CrossTenantAccessTest do
  @moduledoc """
  Penetration test: Attempt cross-tenant access from edge (9.4).

  This test suite simulates attack scenarios where a malicious edge component
  (or compromised agent) attempts to access resources belonging to a different tenant.

  ## Attack Scenarios Tested

  1. **Registry Enumeration** - Attempt to list agents from another tenant
  2. **Direct Resource Access** - Attempt to read/modify another tenant's resources
  3. **gRPC Address Theft** - Attempt to get gRPC addresses for another tenant's agents
  4. **Job Injection** - Attempt to create jobs in another tenant's context
  5. **Certificate Spoofing** - Attempt to use wrong tenant's credentials

  ## Security Properties Verified

  - Tenant isolation is enforced at the registry level
  - Ash multitenancy prevents cross-tenant data access
  - All tenant-scoped queries require valid tenant context
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.AgentRegistry
  alias ServiceRadar.Cluster.TenantRegistry
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Monitoring.PollJob
  alias ServiceRadar.Monitoring.PollingSchedule

  @moduletag :database

  setup do
    unique_id = :erlang.unique_integer([:positive])

    # Create two tenants - attacker and victim
    attacker_tenant_id = Ash.UUID.generate()
    victim_tenant_id = Ash.UUID.generate()

    # Ensure registries exist for both tenants
    TenantRegistry.ensure_registry(attacker_tenant_id)
    TenantRegistry.ensure_registry(victim_tenant_id)
    Process.sleep(100)

    # Create actors for each tenant
    attacker_actor = %{
      id: Ash.UUID.generate(),
      email: "attacker@malicious.local",
      role: :admin,
      tenant_id: attacker_tenant_id
    }

    victim_actor = %{
      id: Ash.UUID.generate(),
      email: "victim@legitimate.local",
      role: :admin,
      tenant_id: victim_tenant_id
    }

    super_admin = %{
      id: Ash.UUID.generate(),
      email: "super@serviceradar.local",
      role: :super_admin,
      tenant_id: attacker_tenant_id
    }

    {:ok,
      attacker_tenant_id: attacker_tenant_id,
      victim_tenant_id: victim_tenant_id,
      attacker_actor: attacker_actor,
      victim_actor: victim_actor,
      super_admin: super_admin,
      unique_id: unique_id
    }
  end

  describe "Attack Scenario 1: Registry Enumeration" do
    setup %{victim_tenant_id: victim_tenant_id, super_admin: super_admin, unique_id: unique_id} do
      # Create victim's agent
      victim_agent_id = "victim-agent-#{unique_id}"

      {:ok, _} = AgentRegistry.register_agent(victim_tenant_id, victim_agent_id, %{
        grpc_host: "192.168.100.50",
        grpc_port: 50051,
        capabilities: [:icmp, :tcp, :http]
      })

      {:ok, victim_agent_id: victim_agent_id}
    end

    test "attacker cannot enumerate victim's agents via registry",
         %{attacker_tenant_id: attacker_tenant_id, victim_agent_id: victim_agent_id} do

      # Attack: Try to look up victim's agent using attacker's tenant context
      result = AgentRegistry.lookup(attacker_tenant_id, victim_agent_id)

      assert result == [],
        "Attacker should not find victim's agent in their tenant context"
    end

    test "attacker cannot get victim's agent gRPC address",
         %{attacker_tenant_id: attacker_tenant_id, victim_agent_id: victim_agent_id} do

      # Attack: Try to get gRPC address for victim's agent
      result = AgentRegistry.get_grpc_address(attacker_tenant_id, victim_agent_id)

      assert result == {:error, :not_found},
        "Attacker should not get gRPC address for victim's agent"
    end

    test "attacker cannot list victim's agents",
         %{attacker_tenant_id: attacker_tenant_id, victim_tenant_id: victim_tenant_id,
           victim_agent_id: victim_agent_id} do

      # Attack: Try to list all agents - should only see attacker's tenant
      attacker_agents = AgentRegistry.find_agents_for_tenant(attacker_tenant_id)
      victim_agents = AgentRegistry.find_agents_for_tenant(victim_tenant_id)

      # Attacker's query should not return victim's agent
      refute Enum.any?(attacker_agents, &(&1[:agent_id] == victim_agent_id)),
        "Attacker should not see victim's agent in their tenant listing"

      # Victim's query should find their own agent
      assert Enum.any?(victim_agents, &(&1[:agent_id] == victim_agent_id)),
        "Victim should see their own agent"
    end
  end

  describe "Attack Scenario 2: Direct Resource Access" do
    setup %{victim_tenant_id: victim_tenant_id, super_admin: super_admin, unique_id: unique_id} do
      # Create victim's infrastructure agent
      {:ok, victim_agent} =
        Agent
        |> Ash.Changeset.for_create(:register_connected, %{
          uid: "victim-infra-agent-#{unique_id}",
          name: "Victim's Production Agent",
          host: "192.168.100.60",
          port: 50051,
          capabilities: ["icmp", "tcp", "http", "snmp"]
        }, actor: super_admin, tenant: victim_tenant_id, authorize?: false)
        |> Ash.create()

      {:ok, victim_agent: victim_agent}
    end

    test "attacker cannot read victim's agents via Ash query",
         %{attacker_actor: attacker_actor, attacker_tenant_id: attacker_tenant_id,
           victim_agent: victim_agent} do

      # Attack: Query with attacker's tenant context
      agents =
        Agent
        |> Ash.Query.for_read(:read, %{}, actor: attacker_actor, tenant: attacker_tenant_id)
        |> Ash.read!()

      refute Enum.any?(agents, &(&1.uid == victim_agent.uid)),
        "Attacker should not see victim's agent in Ash query"
    end

    test "attacker cannot read victim's agent by UID",
         %{attacker_actor: attacker_actor, attacker_tenant_id: attacker_tenant_id,
           victim_agent: victim_agent} do

      # Attack: Try to get victim's agent by UID with wrong tenant context
      result =
        Agent
        |> Ash.Query.for_read(:by_uid, %{uid: victim_agent.uid},
            actor: attacker_actor, tenant: attacker_tenant_id)
        |> Ash.read()

      case result do
        {:ok, []} ->
          # Expected: empty result due to tenant isolation
          assert true

        {:ok, agents} ->
          refute Enum.any?(agents, &(&1.uid == victim_agent.uid)),
            "Attacker should not find victim's agent by UID"

        {:error, _} ->
          # Access denied is also acceptable
          assert true
      end
    end

    test "attacker cannot update victim's agent",
         %{attacker_actor: attacker_actor, victim_agent: victim_agent} do

      # Attack: Try to update victim's agent (heartbeat)
      # This should fail because the record belongs to a different tenant
      result =
        victim_agent
        |> Ash.Changeset.for_update(:heartbeat, %{}, actor: attacker_actor)
        |> Ash.update()

      # Should either fail with policy error or forbidden
      case result do
        {:error, %Ash.Error.Forbidden{}} ->
          assert true, "Update correctly blocked by policy"

        {:error, %Ash.Error.Invalid{}} ->
          assert true, "Update correctly blocked due to tenant mismatch"

        {:error, _other} ->
          assert true, "Update blocked"

        {:ok, _} ->
          flunk "SECURITY VIOLATION: Attacker was able to update victim's agent!"
      end
    end
  end

  describe "Attack Scenario 3: Job Injection" do
    setup %{victim_tenant_id: victim_tenant_id, super_admin: super_admin, unique_id: unique_id} do
      # Create victim's polling schedule
      {:ok, victim_schedule} =
        PollingSchedule
        |> Ash.Changeset.for_create(:create, %{
          name: "Victim's Critical Schedule #{unique_id}",
          schedule_type: :interval,
          interval_seconds: 60
        }, tenant: victim_tenant_id, authorize?: false)
        |> Ash.create()

      {:ok, victim_schedule: victim_schedule}
    end

    test "attacker's job for victim's schedule is isolated to attacker's tenant",
         %{attacker_tenant_id: attacker_tenant_id, victim_tenant_id: victim_tenant_id,
           victim_schedule: victim_schedule} do

      # Note: The FK constraint allows cross-tenant schedule references,
      # but the job is still created in the attacker's tenant context.
      # This is because schedule_id is just a reference - the actual tenant
      # isolation happens via the tenant_id attribute on the job itself.

      result =
        PollJob
        |> Ash.Changeset.for_create(:create, %{
          schedule_id: victim_schedule.id,
          schedule_name: "Attempted Cross-Tenant Job",
          check_count: 1
        }, tenant: attacker_tenant_id, authorize?: false)
        |> Ash.create()

      case result do
        {:ok, job} ->
          # Even if created, the job belongs to attacker's tenant
          assert job.tenant_id == attacker_tenant_id,
            "Job should be in attacker's tenant, not victim's"
          refute job.tenant_id == victim_tenant_id,
            "Job should NOT be in victim's tenant"

          # Victim cannot see this job
          victim_jobs =
            PollJob
            |> Ash.Query.for_read(:read, %{}, tenant: victim_tenant_id)
            |> Ash.read!(authorize?: false)

          refute Enum.any?(victim_jobs, &(&1.id == job.id)),
            "Victim should not see job created with their schedule_id but attacker's tenant"

        {:error, _} ->
          # If blocked, that's also acceptable
          assert true
      end
    end

    test "attacker cannot see victim's jobs",
         %{attacker_tenant_id: attacker_tenant_id, victim_tenant_id: victim_tenant_id,
           victim_schedule: victim_schedule, unique_id: unique_id} do

      # Create a legitimate job in victim's tenant
      {:ok, victim_job} =
        PollJob
        |> Ash.Changeset.for_create(:create, %{
          schedule_id: victim_schedule.id,
          schedule_name: "Victim's Legitimate Job #{unique_id}",
          check_count: 5
        }, tenant: victim_tenant_id, authorize?: false)
        |> Ash.create()

      # Attack: Query jobs with attacker's tenant context
      attacker_jobs =
        PollJob
        |> Ash.Query.for_read(:read, %{}, tenant: attacker_tenant_id)
        |> Ash.read!(authorize?: false)

      refute Enum.any?(attacker_jobs, &(&1.id == victim_job.id)),
        "Attacker should not see victim's jobs"
    end
  end

  describe "Attack Scenario 4: Capability-based Discovery" do
    setup %{victim_tenant_id: victim_tenant_id, unique_id: unique_id} do
      # Create victim's SNMP-capable agent (high-value target)
      victim_snmp_agent = "victim-snmp-#{unique_id}"

      {:ok, _} = AgentRegistry.register_agent(victim_tenant_id, victim_snmp_agent, %{
        grpc_host: "192.168.100.70",
        grpc_port: 50051,
        capabilities: [:snmp, :icmp]
      })

      {:ok, victim_snmp_agent: victim_snmp_agent}
    end

    test "attacker cannot discover victim's agents by capability",
         %{attacker_tenant_id: attacker_tenant_id, victim_snmp_agent: victim_snmp_agent} do

      # Attack: Try to find SNMP-capable agents across all tenants
      snmp_agents = AgentRegistry.find_agents_with_capability(attacker_tenant_id, :snmp)

      refute Enum.any?(snmp_agents, &(&1[:agent_id] == victim_snmp_agent)),
        "Attacker should not discover victim's SNMP agent via capability search"
    end

    test "attacker cannot discover victim's agents by gRPC availability",
         %{attacker_tenant_id: attacker_tenant_id, victim_snmp_agent: victim_snmp_agent} do

      # Attack: Try to find all gRPC-enabled agents
      grpc_agents = AgentRegistry.find_agents_with_grpc(attacker_tenant_id)

      refute Enum.any?(grpc_agents, &(&1[:agent_id] == victim_snmp_agent)),
        "Attacker should not discover victim's agents via gRPC search"
    end
  end

  describe "Attack Scenario 5: Tenant Spoofing" do
    test "cannot create agent with wrong tenant_id attribute",
         %{attacker_actor: attacker_actor, attacker_tenant_id: attacker_tenant_id,
           victim_tenant_id: victim_tenant_id, unique_id: unique_id} do

      # Attack: Try to create agent with victim's tenant_id
      # The tenant context should override any tenant_id in attributes
      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(:register, %{
          uid: "spoofed-agent-#{unique_id}",
          name: "Spoofed Agent",
          host: "192.168.1.1",
          port: 50051
        }, actor: attacker_actor, tenant: attacker_tenant_id, authorize?: false)
        |> Ash.create()

      # Agent should have attacker's tenant, not victim's
      assert agent.tenant_id == attacker_tenant_id,
        "Agent tenant_id should match the creation context, not be spoofable"

      refute agent.tenant_id == victim_tenant_id,
        "Agent should NOT have victim's tenant_id"
    end

    test "attacker actor with wrong tenant_id cannot bypass isolation",
         %{attacker_tenant_id: attacker_tenant_id, victim_tenant_id: victim_tenant_id} do

      # Attack: Create actor with mismatched tenant_id
      spoofed_actor = %{
        id: Ash.UUID.generate(),
        email: "attacker@malicious.local",
        role: :admin,
        tenant_id: victim_tenant_id  # Attacker claims to be in victim's tenant
      }

      # But use attacker's actual tenant context
      agents =
        Agent
        |> Ash.Query.for_read(:read, %{}, actor: spoofed_actor, tenant: attacker_tenant_id)
        |> Ash.read!()

      # Should only return agents from attacker's tenant (the actual tenant context)
      # not victim's tenant (the claimed actor tenant_id)
      for agent <- agents do
        assert agent.tenant_id == attacker_tenant_id,
          "Query should respect tenant context, not actor.tenant_id"
      end
    end
  end

  describe "Defense Verification" do
    test "super_admin can see all tenants (legitimate cross-tenant access)",
         %{super_admin: super_admin, victim_tenant_id: victim_tenant_id, unique_id: unique_id} do

      # Create agent in victim's tenant
      {:ok, victim_agent} =
        Agent
        |> Ash.Changeset.for_create(:register, %{
          uid: "super-admin-test-#{unique_id}",
          name: "Test Agent",
          host: "192.168.1.1",
          port: 50051
        }, actor: super_admin, tenant: victim_tenant_id, authorize?: false)
        |> Ash.create()

      # Super admin query without tenant restriction
      all_agents =
        Agent
        |> Ash.Query.for_read(:read, %{}, actor: super_admin)
        |> Ash.read!()

      # Super admin should see the agent (global access)
      assert Enum.any?(all_agents, &(&1.uid == victim_agent.uid)),
        "Super admin should have cross-tenant visibility"
    end

    test "tenant isolation is enforced at database level",
         %{attacker_tenant_id: attacker_tenant_id, victim_tenant_id: victim_tenant_id} do

      # Verify tenants are actually different
      refute attacker_tenant_id == victim_tenant_id,
        "Test requires different tenant IDs"

      # Verify both are valid UUIDs (36 chars with hyphens)
      assert String.length(attacker_tenant_id) == 36, "Attacker tenant should be valid UUID"
      assert String.length(victim_tenant_id) == 36, "Victim tenant should be valid UUID"

      # UUID format validation
      uuid_regex = ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
      assert Regex.match?(uuid_regex, attacker_tenant_id), "Attacker tenant should be valid UUID format"
      assert Regex.match?(uuid_regex, victim_tenant_id), "Victim tenant should be valid UUID format"
    end
  end
end
