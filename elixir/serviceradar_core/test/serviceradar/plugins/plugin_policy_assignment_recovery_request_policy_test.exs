defmodule ServiceRadar.Plugins.PluginPolicyAssignmentRecoveryRequestPolicyTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.Checks.RecoveryRequestDispatcher
  alias ServiceRadar.Plugins.Checks.RecoveryRequestExecutor
  alias ServiceRadar.Plugins.Checks.RecoveryRequestLookup
  alias ServiceRadar.Plugins.PluginPolicyAssignmentRecoveryRequest

  @plugin_manager %{
    id: "plugin-manager",
    role: :admin,
    permissions: MapSet.new(["settings.plugins.manage"])
  }
  @executor SystemActor.system(:plugin_policy_assignment_recovery_executor)
  @dispatcher SystemActor.system(:plugin_policy_assignment_recovery_dispatcher)
  @lookup SystemActor.system(:plugin_policy_assignment_recovery_lookup)

  test "only the named executor can load an individual recovery request" do
    assert RecoveryRequestExecutor.match?(@executor, [], %{})
    refute RecoveryRequestExecutor.match?(@plugin_manager, [], %{})
    refute RecoveryRequestExecutor.match?(@dispatcher, [], %{})

    assert Ash.can?({PluginPolicyAssignmentRecoveryRequest, :by_id}, @executor, maybe_is: false)

    refute Ash.can?({PluginPolicyAssignmentRecoveryRequest, :by_id}, @plugin_manager,
             maybe_is: false
           )

    refute Ash.can?({PluginPolicyAssignmentRecoveryRequest, :by_id}, @dispatcher, maybe_is: false)
  end

  test "only the named dispatcher can enumerate requests and the lookup actor can read one legacy request" do
    assert Ash.can?({PluginPolicyAssignmentRecoveryRequest, :read}, @dispatcher)
    refute Ash.can?({PluginPolicyAssignmentRecoveryRequest, :read}, @plugin_manager)
    assert Ash.can?({PluginPolicyAssignmentRecoveryRequest, :active_for_legacy}, @lookup)
    assert Ash.can?({PluginPolicyAssignmentRecoveryRequest, :latest_for_legacy}, @lookup)
    refute Ash.can?({PluginPolicyAssignmentRecoveryRequest, :active_for_legacy}, @plugin_manager)
    refute Ash.can?({PluginPolicyAssignmentRecoveryRequest, :latest_for_legacy}, @plugin_manager)
    assert Ash.can?({PluginPolicyAssignmentRecoveryRequest, :request}, @plugin_manager)

    assert RecoveryRequestDispatcher.match?(@dispatcher, [], %{})
    refute RecoveryRequestDispatcher.match?(@executor, [], %{})
    refute RecoveryRequestDispatcher.match?(@plugin_manager, [], %{})
    assert RecoveryRequestLookup.match?(@lookup, [], %{})
    refute RecoveryRequestLookup.match?(@dispatcher, [], %{})
    refute RecoveryRequestLookup.match?(@plugin_manager, [], %{})

    refute Ash.can?({PluginPolicyAssignmentRecoveryRequest, :request}, @dispatcher)
  end

  test "an unrelated system actor cannot claim, finish, or read recovery requests" do
    unrelated_system_actor = SystemActor.system(:unrelated_recovery_component)

    assert RecoveryRequestExecutor.match?(@executor, [], %{})
    assert RecoveryRequestDispatcher.match?(@dispatcher, [], %{})
    assert RecoveryRequestLookup.match?(@lookup, [], %{})
    refute RecoveryRequestExecutor.match?(unrelated_system_actor, [], %{})
    refute RecoveryRequestDispatcher.match?(unrelated_system_actor, [], %{})
    refute RecoveryRequestLookup.match?(unrelated_system_actor, [], %{})

    for action <- [:request] do
      refute Ash.can?({PluginPolicyAssignmentRecoveryRequest, action}, unrelated_system_actor)
    end

    refute Ash.can?({PluginPolicyAssignmentRecoveryRequest, :by_id}, unrelated_system_actor,
             maybe_is: false
           )

    refute Ash.can?(
             {PluginPolicyAssignmentRecoveryRequest, :active_for_legacy},
             unrelated_system_actor
           )

    refute Ash.can?(
             {PluginPolicyAssignmentRecoveryRequest, :latest_for_legacy},
             unrelated_system_actor
           )
  end
end
