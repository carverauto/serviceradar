defmodule ServiceRadar.Plugins.PolicyOwnedAssignmentRecoveryTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.PluginAssignmentMaterializer
  alias ServiceRadar.Plugins.PluginTargetPolicyOps
  alias ServiceRadar.Plugins.PolicyOwnedAssignmentRecovery
  alias ServiceRadar.Plugins.PolicyOwnedAssignmentRecovery.Authority
  alias ServiceRadar.Plugins.PolicyOwnedAssignmentRecovery.Executor
  alias ServiceRadar.Plugins.PolicyOwnedAssignmentRecovery.Lease

  @principal_id "6f844fc3-7d05-4a25-982b-58a93738d949"

  defmodule AuditWriterStub do
    @moduledoc false

    def write_async(opts) do
      send(Keyword.fetch!(opts, :test_pid), {:policy_recovery_audit, opts})
      :ok
    end
  end

  defmodule DisabledPrincipalSource do
    @moduledoc false

    def load_principal(:human, principal_id, nil) do
      {:ok,
       %{
         principal: %{id: principal_id},
         owner: %{id: principal_id, status: :disabled, role: :admin}
       }}
    end
  end

  test "requires explicit confirmation and writes a secret-safe denial audit" do
    legacy_assignment_id = "6fabcae3-6457-44d7-8a1e-b65f77239d43"
    secret = "must-not-reach-audit"

    assert {:error, :recovery_confirmation_required} =
             PolicyOwnedAssignmentRecovery.request(legacy_assignment_id,
               actor: %{id: @principal_id, email: "operator@example.test", bearer: secret},
               audit_writer: {AuditWriterStub, test_pid: self()}
             )

    assert_receive {:policy_recovery_audit, audit_opts}

    assert Keyword.fetch!(audit_opts, :action) == :plugin_policy_assignment_recovery_request
    assert Keyword.fetch!(audit_opts, :resource_type) == "plugin_policy_assignment_recovery"
    assert Keyword.fetch!(audit_opts, :resource_id) == legacy_assignment_id

    assert Keyword.fetch!(audit_opts, :details) == %{
             recovery_kind: "policy_owned",
             outcome: "denied",
             reason: "confirmation_required"
           }

    refute inspect(audit_opts) =~ secret
  end

  test "current authority denial happens before permission resolution or materialization" do
    test_pid = self()

    assert {:error, :principal_disabled} =
             Authority.rebuild_current_principal(
               %{principal_type: :human, principal_id: @principal_id, principal_owner_id: nil},
               source: DisabledPrincipalSource,
               permissions_loader: fn _owner ->
                 send(test_pid, :permissions_loaded)
                 {:ok, MapSet.new(["settings.plugins.manage"])}
               end
             )

    refute_received :permissions_loaded
    assert Executor.terminal_outcome(:principal_disabled) == :denied
  end

  test "missing policy owners and missing initiating principals finish safely" do
    assert Executor.terminal_outcome(:owner_not_found) == :owner_not_authoritative
    assert Executor.terminal_outcome(:policy_not_enabled) == :owner_not_authoritative
    assert Executor.terminal_outcome(:record_not_found) == :denied
    assert Executor.terminal_outcome(:principal_disabled) == :denied
  end

  test "only requested or expired work may acquire a recovery lease" do
    now = ~U[2026-07-15 12:00:00.000000Z]

    assert Lease.claimable?(:requested, nil, now)
    refute Lease.claimable?(:executing, DateTime.add(now, 1, :second), now)
    assert Lease.claimable?(:executing, now, now)
    assert Lease.claimable?(:executing, DateTime.add(now, -1, :second), now)
    refute Lease.claimable?(:reconciled, nil, now)
  end

  test "only the named executor may issue an atomic recovery finish" do
    assert {:error, :recovery_lease_requires_recovery_executor} =
             Lease.finish_current(
               "request-id",
               "lease-token",
               :failed,
               [],
               ~U[2026-07-15 12:00:00.000000Z],
               actor: SystemActor.system(:unrelated_recovery_component)
             )
  end

  test "only the named executor may claim a recovery lease" do
    assert {:error, :recovery_lease_requires_recovery_executor} =
             Lease.claim_current(
               "request-id",
               "lease-token",
               ~U[2026-07-15 12:00:00.000000Z],
               ~U[2026-07-15 12:30:00.000000Z],
               actor: SystemActor.system(:unrelated_recovery_component)
             )
  end

  test "only the named recovery executor may invoke narrowed materializers" do
    unrelated_system_actor = SystemActor.system(:unrelated_recovery_component)

    assert {:error, :restricted_rule_recovery_requires_recovery_executor} =
             PluginAssignmentMaterializer.reconcile_current_rule_for_agent(
               "rule-id",
               "agent-id",
               :console_access,
               actor: unrelated_system_actor
             )

    assert {:error, :restricted_policy_recovery_requires_recovery_executor} =
             PluginTargetPolicyOps.reconcile_policy_for_agent(
               "policy-id",
               "agent-id",
               actor: unrelated_system_actor
             )
  end

  test "a committed policy recovery seeds current service states and pushes the exact postflight principal after terminal persistence" do
    test_pid = self()
    request = %{id: "recovery-request-1", legacy_agent_uid: "agent-farm01", status: :requested}

    assert {:ok, :reconciled} =
             Executor.execute("recovery-request-1",
               test_request_loader: fn "recovery-request-1" ->
                 send(test_pid, :request_loaded)
                 {:ok, request}
               end,
               test_claimer: fn ^request ->
                 send(test_pid, :lease_claimed)
                 {:ok, {:claimed, request, "lease-token"}}
               end,
               test_materializer: fn ^request ->
                 # This return value is emitted only after Executor's guarded
                 # transaction commits in production; the dispatcher must wait
                 # for the terminal request status below as well.
                 send(test_pid, :materialization_committed)
                 {:ok, :reconciled, ["replacement-assignment-1"], "farm01"}
               end,
               test_recovered_assignment_loader: fn "replacement-assignment-1",
                                                    ^request,
                                                    "farm01" ->
                 send(test_pid, :recovered_assignment_reloaded)
                 {:ok, %{id: "replacement-assignment-1"}}
               end,
               service_state_upserter: fn %{id: "replacement-assignment-1"} ->
                 send(test_pid, :service_state_seeded)
                 :ok
               end,
               config_dispatcher: fn partition_id, agent_uid ->
                 send(test_pid, {:policy_recovery_config_push, partition_id, agent_uid})
                 :ok
               end,
               config_dispatch_async?: false,
               test_finisher: fn ^request,
                                 "lease-token",
                                 :reconciled,
                                 ["replacement-assignment-1"] ->
                 # The config push is an external effect. It must not run
                 # while the terminal status write is still in progress; nor
                 # may the recovery create a service-state placeholder before
                 # its request has become terminal.
                 refute_receive {:policy_recovery_config_push, _, _}
                 refute_receive :service_state_seeded
                 send(test_pid, :terminal_status_persisted)
                 {:ok, :reconciled}
               end
             )

    assert_receive :request_loaded
    assert_receive :lease_claimed
    assert_receive :materialization_committed
    assert_receive :terminal_status_persisted
    assert_receive :recovered_assignment_reloaded
    assert_receive :service_state_seeded
    assert_receive {:policy_recovery_config_push, "farm01", "agent-farm01"}
    refute_receive {:policy_recovery_config_push, _, _}
  end

  test "an identity-change rollback result never invokes the policy config dispatcher" do
    test_pid = self()
    request = %{id: "recovery-request-2", legacy_agent_uid: "agent-farm01", status: :requested}

    assert {:ok, :identity_changed} =
             Executor.execute("recovery-request-2",
               test_request_loader: fn "recovery-request-2" -> {:ok, request} end,
               test_claimer: fn ^request -> {:ok, {:claimed, request, "lease-token"}} end,
               test_materializer: fn ^request ->
                 # Simulate the post-write identity flip path: the guarded
                 # transaction has rolled its writes back and reports only the
                 # terminal identity-change result to the executor.
                 send(test_pid, :materialization_rolled_back)
                 {:error, :identity_changed}
               end,
               config_dispatcher: fn partition_id, agent_uid ->
                 send(
                   test_pid,
                   {:unexpected_policy_recovery_config_push, partition_id, agent_uid}
                 )

                 :ok
               end,
               config_dispatch_async?: false,
               test_finisher: fn ^request, "lease-token", :identity_changed, [] ->
                 send(test_pid, :identity_change_persisted)
                 {:ok, :identity_changed}
               end
             )

    assert_receive :materialization_rolled_back
    assert_receive :identity_change_persisted
    refute_receive {:unexpected_policy_recovery_config_push, _, _}
  end

  test "a lost materialization lease never terminalizes or dispatches config" do
    test_pid = self()

    request = %{
      id: "recovery-request-lost-lease",
      legacy_agent_uid: "agent-farm01",
      status: :requested
    }

    assert {:ok, :already_executing} =
             Executor.execute("recovery-request-lost-lease",
               test_request_loader: fn "recovery-request-lost-lease" -> {:ok, request} end,
               test_claimer: fn ^request -> {:ok, {:claimed, request, "stale-lease-token"}} end,
               # The database fence is covered independently below. This seam
               # exercises the executor's fail-closed boundary once that fence
               # reports an expired or stolen lease.
               test_materializer: fn ^request -> {:error, :recovery_lease_lost} end,
               test_finisher: fn _request, _lease_token, _outcome, _assignment_ids ->
                 send(test_pid, :unexpected_terminal_write)
                 {:ok, :failed}
               end,
               config_dispatcher: fn partition_id, agent_uid ->
                 send(
                   test_pid,
                   {:unexpected_policy_recovery_config_push, partition_id, agent_uid}
                 )

                 :ok
               end,
               config_dispatch_async?: false
             )

    refute_received :unexpected_terminal_write
    refute_received {:unexpected_policy_recovery_config_push, _, _}
  end

  test "a terminal-status persistence failure does not independently dispatch config" do
    test_pid = self()
    request = %{id: "recovery-request-3", legacy_agent_uid: "agent-farm01", status: :requested}

    assert {:error, :terminal_status_write_failed} =
             Executor.execute("recovery-request-3",
               test_request_loader: fn "recovery-request-3" -> {:ok, request} end,
               test_claimer: fn ^request -> {:ok, {:claimed, request, "lease-token"}} end,
               test_materializer: fn ^request ->
                 {:ok, :reconciled, ["replacement-assignment-3"], "farm01"}
               end,
               config_dispatcher: fn partition_id, agent_uid ->
                 send(test_pid, {:policy_recovery_config_push, partition_id, agent_uid})
                 :ok
               end,
               config_dispatch_async?: false,
               test_finisher: fn ^request,
                                 "lease-token",
                                 :reconciled,
                                 ["replacement-assignment-3"] ->
                 send(test_pid, :terminal_status_write_attempted)
                 {:error, :terminal_status_write_failed}
               end
             )

    assert_receive :terminal_status_write_attempted
    refute_receive {:policy_recovery_config_push, _, _}
  end
end
