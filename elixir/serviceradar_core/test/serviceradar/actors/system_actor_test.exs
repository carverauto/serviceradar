defmodule ServiceRadar.Actors.SystemActorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Actors.SystemActor

  describe "system/1" do
    test "creates a system actor" do
      actor = SystemActor.system(:state_monitor)

      assert actor.id == "system:state_monitor"
      assert actor.email == "state-monitor@system.serviceradar"
      assert actor.role == :system
      refute Map.has_key?(actor, :tenant_id)
    end

    test "converts underscores to hyphens in email" do
      actor = SystemActor.system(:sweep_compiler)

      assert actor.email == "sweep-compiler@system.serviceradar"
    end

    test "handles single-word component names" do
      actor = SystemActor.system(:gateway)

      assert actor.id == "system:gateway"
      assert actor.email == "gateway@system.serviceradar"
    end

    test "each component gets unique id" do
      actor1 = SystemActor.system(:health_tracker)
      actor2 = SystemActor.system(:config_server)

      assert actor1.id != actor2.id
      assert actor1.email != actor2.email
    end
  end

  describe "system_actor?/1" do
    test "returns true for system actor" do
      actor = SystemActor.system(:state_monitor)

      assert SystemActor.system_actor?(actor)
    end

    test "returns false for regular admin actor" do
      actor = %{role: :admin, id: "user-123"}

      refute SystemActor.system_actor?(actor)
    end

    test "returns false for regular user actor" do
      actor = %{role: :viewer, id: "user-456"}

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
    test "system actor has required keys for Ash policies" do
      actor = SystemActor.system(:test)

      # These are the keys that Ash policies check
      assert Map.has_key?(actor, :role)
      assert Map.has_key?(actor, :id)
      assert Map.has_key?(actor, :email)
      # Should NOT have tenant_id (tenant is implicit from search_path)
      refute Map.has_key?(actor, :tenant_id)
    end
  end
end
