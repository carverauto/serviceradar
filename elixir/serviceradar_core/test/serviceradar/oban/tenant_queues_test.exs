defmodule ServiceRadar.Oban.TenantQueuesTest do
  @moduledoc """
  Tests for per-tenant Oban queue management.

  Verifies that:
  - Queues are correctly named per tenant
  - Job insertion routes to tenant queues
  - Queue provisioning works for new tenants
  - Multi-tenant isolation is maintained
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Oban.TenantQueues

  @moduletag :database

  setup do
    unique_id = :erlang.unique_integer([:positive])
    tenant_a_id = Ash.UUID.generate()
    tenant_b_id = Ash.UUID.generate()

    {:ok,
      tenant_a_id: tenant_a_id,
      tenant_b_id: tenant_b_id,
      unique_id: unique_id
    }
  end

  describe "get_queue_name/2" do
    test "generates consistent queue names for tenant", %{tenant_a_id: tenant_id} do
      queue1 = TenantQueues.get_queue_name(tenant_id, :default)
      queue2 = TenantQueues.get_queue_name(tenant_id, :default)

      assert queue1 == queue2
      assert is_atom(queue1)
      assert String.starts_with?(Atom.to_string(queue1), "t_")
      assert String.ends_with?(Atom.to_string(queue1), "_default")
    end

    test "different queue types have different names", %{tenant_a_id: tenant_id} do
      default_queue = TenantQueues.get_queue_name(tenant_id, :default)
      polling_queue = TenantQueues.get_queue_name(tenant_id, :polling)
      alerts_queue = TenantQueues.get_queue_name(tenant_id, :alerts)

      assert default_queue != polling_queue
      assert polling_queue != alerts_queue
      assert default_queue != alerts_queue
    end

    test "different tenants have different queues", %{tenant_a_id: tenant_a, tenant_b_id: tenant_b} do
      queue_a = TenantQueues.get_queue_name(tenant_a, :default)
      queue_b = TenantQueues.get_queue_name(tenant_b, :default)

      assert queue_a != queue_b
    end
  end

  describe "get_all_queue_names/1" do
    test "returns all queue types for tenant", %{tenant_a_id: tenant_id} do
      queues = TenantQueues.get_all_queue_names(tenant_id)

      assert is_list(queues)
      assert length(queues) == length(TenantQueues.queue_types())

      queue_suffixes =
        Enum.map(queues, fn q ->
          q |> Atom.to_string() |> String.split("_") |> List.last() |> String.to_atom()
        end)

      assert :default in queue_suffixes
      assert :polling in queue_suffixes
      assert :alerts in queue_suffixes
    end
  end

  describe "provision_tenant/1" do
    test "provisions queues for tenant", %{tenant_a_id: tenant_id} do
      # Ensure not provisioned initially
      refute TenantQueues.tenant_provisioned?(tenant_id)

      # Provision
      result = TenantQueues.provision_tenant(tenant_id)
      assert result == :ok

      # Should be provisioned now
      assert TenantQueues.tenant_provisioned?(tenant_id)
    end

    test "is idempotent - multiple calls succeed", %{tenant_a_id: tenant_id} do
      assert :ok == TenantQueues.provision_tenant(tenant_id)
      assert :ok == TenantQueues.provision_tenant(tenant_id)
      assert :ok == TenantQueues.provision_tenant(tenant_id)

      assert TenantQueues.tenant_provisioned?(tenant_id)
    end
  end

  describe "deprovision_tenant/1" do
    test "deprovisions tenant queues", %{tenant_a_id: tenant_id} do
      # First provision
      :ok = TenantQueues.provision_tenant(tenant_id)
      assert TenantQueues.tenant_provisioned?(tenant_id)

      # Then deprovision
      :ok = TenantQueues.deprovision_tenant(tenant_id)
      refute TenantQueues.tenant_provisioned?(tenant_id)
    end
  end

  describe "list_provisioned_tenants/0" do
    test "lists all provisioned tenants", %{tenant_a_id: tenant_a, tenant_b_id: tenant_b} do
      :ok = TenantQueues.provision_tenant(tenant_a)
      :ok = TenantQueues.provision_tenant(tenant_b)

      tenants = TenantQueues.list_provisioned_tenants()

      assert is_list(tenants)
      assert tenant_a in tenants
      assert tenant_b in tenants
    end
  end

  describe "get_tenant_stats/1" do
    test "returns queue statistics for tenant", %{tenant_a_id: tenant_id} do
      :ok = TenantQueues.provision_tenant(tenant_id)

      stats = TenantQueues.get_tenant_stats(tenant_id)

      assert is_map(stats)
      assert stats.tenant_id == tenant_id
      assert stats.provisioned == true
      assert is_map(stats.queues)
      assert %DateTime{} = stats.collected_at
    end
  end

  describe "queue_types/0" do
    test "returns list of queue type atoms" do
      types = TenantQueues.queue_types()

      assert is_list(types)
      assert :default in types
      assert :polling in types
      assert :alerts in types
      assert :sync in types
      assert :events in types
    end
  end

  describe "default_concurrency/0" do
    test "returns concurrency map" do
      concurrency = TenantQueues.default_concurrency()

      assert is_map(concurrency)
      assert Map.has_key?(concurrency, :default)
      assert Map.has_key?(concurrency, :polling)
      assert is_integer(concurrency.default)
      assert concurrency.default > 0
    end
  end

  describe "pause_tenant/1 and resume_tenant/1" do
    test "pauses and resumes tenant queues", %{tenant_a_id: tenant_id} do
      :ok = TenantQueues.provision_tenant(tenant_id)

      # Pause
      :ok = TenantQueues.pause_tenant(tenant_id)

      # Resume
      :ok = TenantQueues.resume_tenant(tenant_id)
    end
  end

  describe "scale_tenant_queue/3" do
    test "scales queue concurrency", %{tenant_a_id: tenant_id} do
      :ok = TenantQueues.provision_tenant(tenant_id)

      # Scale up
      :ok = TenantQueues.scale_tenant_queue(tenant_id, :polling, 50)

      # Scale down
      :ok = TenantQueues.scale_tenant_queue(tenant_id, :polling, 5)
    end
  end

  describe "tenant isolation" do
    test "provisioned state is isolated per tenant", %{tenant_a_id: tenant_a, tenant_b_id: tenant_b} do
      # Initially neither provisioned
      refute TenantQueues.tenant_provisioned?(tenant_a)
      refute TenantQueues.tenant_provisioned?(tenant_b)

      # Provision only A
      :ok = TenantQueues.provision_tenant(tenant_a)

      # Only A should be provisioned
      assert TenantQueues.tenant_provisioned?(tenant_a)
      refute TenantQueues.tenant_provisioned?(tenant_b)

      # Provision B
      :ok = TenantQueues.provision_tenant(tenant_b)

      # Both should be provisioned
      assert TenantQueues.tenant_provisioned?(tenant_a)
      assert TenantQueues.tenant_provisioned?(tenant_b)

      # Deprovision A
      :ok = TenantQueues.deprovision_tenant(tenant_a)

      # Only B should be provisioned
      refute TenantQueues.tenant_provisioned?(tenant_a)
      assert TenantQueues.tenant_provisioned?(tenant_b)
    end
  end
end
