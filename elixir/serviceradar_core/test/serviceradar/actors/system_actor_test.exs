defmodule ServiceRadar.Actors.SystemActorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Actors.SystemActor

  @tenant_id "550e8400-e29b-41d4-a716-446655440000"

  describe "for_tenant/2" do
    test "creates a tenant-scoped system actor" do
      actor = SystemActor.for_tenant(@tenant_id, :state_monitor)

      assert actor.id == "system:state_monitor"
      assert actor.email == "state-monitor@system.serviceradar"
      assert actor.role == :system
      assert actor.tenant_id == @tenant_id
    end

    test "converts underscores to hyphens in email" do
      actor = SystemActor.for_tenant(@tenant_id, :sweep_compiler)

      assert actor.email == "sweep-compiler@system.serviceradar"
    end

    test "handles single-word component names" do
      actor = SystemActor.for_tenant(@tenant_id, :gateway)

      assert actor.id == "system:gateway"
      assert actor.email == "gateway@system.serviceradar"
    end

    test "each component gets unique id" do
      actor1 = SystemActor.for_tenant(@tenant_id, :health_tracker)
      actor2 = SystemActor.for_tenant(@tenant_id, :config_server)

      assert actor1.id != actor2.id
      assert actor1.email != actor2.email
    end

    test "same component for different tenants have same id but different tenant_id" do
      actor1 = SystemActor.for_tenant(@tenant_id, :state_monitor)
      actor2 = SystemActor.for_tenant("other-tenant-id", :state_monitor)

      assert actor1.id == actor2.id
      assert actor1.tenant_id != actor2.tenant_id
    end
  end

  describe "platform/1" do
    test "creates a platform-level system actor" do
      actor = SystemActor.platform(:tenant_bootstrap)

      assert actor.id == "platform:tenant_bootstrap"
      assert actor.email == "tenant-bootstrap@platform.serviceradar"
      assert actor.role == :super_admin
      refute Map.has_key?(actor, :tenant_id)
    end

    test "converts underscores to hyphens in email" do
      actor = SystemActor.platform(:operator_bootstrap)

      assert actor.email == "operator-bootstrap@platform.serviceradar"
    end

    test "handles single-word component names" do
      actor = SystemActor.platform(:seeder)

      assert actor.id == "platform:seeder"
      assert actor.email == "seeder@platform.serviceradar"
    end
  end

  describe "system_actor?/1" do
    test "returns true for tenant-scoped system actor" do
      actor = SystemActor.for_tenant(@tenant_id, :state_monitor)

      assert SystemActor.system_actor?(actor)
    end

    test "returns true for platform system actor" do
      actor = SystemActor.platform(:tenant_bootstrap)

      assert SystemActor.system_actor?(actor)
    end

    test "returns false for regular admin actor" do
      actor = %{role: :admin, tenant_id: @tenant_id, id: "user-123"}

      refute SystemActor.system_actor?(actor)
    end

    test "returns false for regular user actor" do
      actor = %{role: :viewer, tenant_id: @tenant_id, id: "user-456"}

      refute SystemActor.system_actor?(actor)
    end

    test "returns false for super_admin without platform prefix" do
      # A regular super_admin user (not a platform system actor)
      actor = %{role: :super_admin, id: "user-789"}

      refute SystemActor.system_actor?(actor)
    end

    test "returns false for nil" do
      refute SystemActor.system_actor?(nil)
    end

    test "returns false for non-map values" do
      refute SystemActor.system_actor?("not an actor")
      refute SystemActor.system_actor?(123)
      refute SystemActor.system_actor?([])
    end
  end

  describe "actor structure" do
    test "tenant actor has required keys for Ash policies" do
      actor = SystemActor.for_tenant(@tenant_id, :test)

      # These are the keys that Ash policies check
      assert Map.has_key?(actor, :role)
      assert Map.has_key?(actor, :tenant_id)
      assert Map.has_key?(actor, :id)
    end

    test "platform actor has required keys for Ash policies" do
      actor = SystemActor.platform(:test)

      # Platform actors need role for bypass checks
      assert Map.has_key?(actor, :role)
      assert Map.has_key?(actor, :id)
      # Should NOT have tenant_id (platform-wide access)
      refute Map.has_key?(actor, :tenant_id)
    end
  end
end
