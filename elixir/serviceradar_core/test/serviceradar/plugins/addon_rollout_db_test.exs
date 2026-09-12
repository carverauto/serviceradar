defmodule ServiceRadar.Plugins.AddonRolloutDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonProfile
  alias ServiceRadar.Plugins.AddonRollout
  alias ServiceRadar.Plugins.AddonRolloutCoordinator
  alias ServiceRadar.Plugins.AddonRolloutTarget
  alias ServiceRadar.Plugins.AddonStatus
  alias ServiceRadar.Plugins.AddonUpdatePolicyBackfillWorker
  alias ServiceRadar.Repo

  require Ash.Query

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  test "backfill dedupe query executes against the oban table without raising" do
    # Regression for issue #4645: Oban.Job.unique_states/1 returns atoms while
    # Oban.Job.state is a :string field; interpolating the atoms raised
    # Ecto.Query.CastError on every ensure_scheduled/0 call and crash-looped
    # the core supervision tree in v1.4.24.
    assert is_boolean(AddonUpdatePolicyBackfillWorker.backfill_scheduled?())
  end

  test "a trusted direct assignment advances through an override and promotes only after health" do
    actor = SystemActor.system(:addon_rollout_db_test)
    unique = System.unique_integer([:positive])
    addon_id = "rollout-db-#{unique}"
    agent_uid = "rollout-agent-#{unique}"
    started_at = DateTime.utc_now()

    current = approved_package(addon_id, "1.0.0", actor)
    candidate = approved_package(addon_id, "1.1.0", actor)

    {:ok, _agent} =
      Agent
      |> Ash.Changeset.for_create(
        :register_connected,
        %{
          uid: agent_uid,
          name: "Rollout test agent",
          version: "1.4.23",
          capabilities: [],
          host: "127.0.0.1",
          port: 50_051,
          metadata: %{"os" => "linux", "arch" => "amd64"}
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, assignment} =
      AddonAssignment
      |> Ash.Changeset.for_create(
        :create,
        %{
          agent_uid: agent_uid,
          addon_package_id: current.id,
          rollout_policy: %{
            "canary_size" => 1,
            "batch_size" => 1,
            "max_parallel" => 1,
            "soak_seconds" => 0,
            "health_timeout_seconds" => 60,
            "tolerated_failures" => 0
          }
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    assert assignment.update_policy == :track_latest_approved
    refute assignment.explicit_version_pin

    assert {:ok, rollout} =
             AddonRolloutCoordinator.start(assignment, candidate,
               actor: actor,
               now: started_at,
               trigger: :manual
             )

    assignment = get_assignment(assignment.id, actor)
    assert assignment.addon_package_id == current.id
    assert assignment.rollout_package_id == candidate.id
    assert assignment.rollout_id == rollout.id

    observed_at = DateTime.add(started_at, 1)

    {:ok, _status} =
      AddonStatus
      |> Ash.Changeset.for_create(
        :report,
        %{
          agent_uid: agent_uid,
          addon_id: addon_id,
          state: "running",
          active: true,
          version: candidate.version,
          reported_at: observed_at
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    assert :ok = AddonRolloutCoordinator.advance(rollout.id, actor: actor, now: observed_at)

    assert :ok =
             AddonRolloutCoordinator.advance(rollout.id,
               actor: actor,
               now: DateTime.add(observed_at, 1)
             )

    assignment = get_assignment(assignment.id, actor)
    assert assignment.addon_package_id == candidate.id
    assert is_nil(assignment.rollout_package_id)
    assert is_nil(assignment.rollout_id)

    rollout = get_rollout(rollout.id, actor)
    assert rollout.state == :completed
    assert get_rollout_target(rollout.id, actor).state == :promoted
  end

  test "legacy trusted sources are backfilled in a bounded post-startup batch" do
    actor = SystemActor.system(:addon_update_policy_backfill_test)
    unique = System.unique_integer([:positive])
    addon_id = "rollout-backfill-#{unique}"
    agent_uid = "rollout-backfill-agent-#{unique}"
    package = approved_package(addon_id, "1.0.0", actor, ["network-observe"])

    {:ok, assignment} =
      AddonAssignment
      |> Ash.Changeset.for_create(
        :create,
        %{agent_uid: agent_uid, addon_package_id: package.id},
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, profile} =
      AddonProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Rollout backfill profile #{unique}",
          addon_package_id: package.id,
          target_query: "in:agents"
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    assert assignment.update_policy == :track_latest_approved
    assert profile.update_policy == :track_latest_approved

    Repo.query!(
      """
      UPDATE platform.addon_assignments
      SET update_policy = 'manual_pin',
          capability_ceiling = ARRAY[]::text[],
          update_policy_backfill_pending = TRUE
      WHERE id = ($1::text)::uuid
      """,
      [assignment.id]
    )

    Repo.query!(
      """
      UPDATE platform.addon_profiles
      SET update_policy = 'manual_pin',
          capability_ceiling = ARRAY[]::text[],
          update_policy_backfill_pending = TRUE
      WHERE id = ($1::text)::uuid
      """,
      [profile.id]
    )

    assert {:ok, %{assignments: assignments, profiles: profiles}} =
             AddonUpdatePolicyBackfillWorker.backfill_batch(Repo, 100)

    assert assignments >= 1
    assert profiles >= 1

    assignment = get_assignment(assignment.id, actor)
    {:ok, profile} = AddonProfile.get_by_id(profile.id, actor: actor)

    assert assignment.update_policy == :track_latest_approved
    assert assignment.capability_ceiling == ["network-observe"]
    assert profile.update_policy == :track_latest_approved
    assert profile.capability_ceiling == ["network-observe"]

    assert %{rows: [[false]]} =
             Repo.query!(
               "SELECT update_policy_backfill_pending FROM platform.addon_assignments WHERE id = ($1::text)::uuid",
               [assignment.id]
             )

    assert %{rows: [[false]]} =
             Repo.query!(
               "SELECT update_policy_backfill_pending FROM platform.addon_profiles WHERE id = ($1::text)::uuid",
               [profile.id]
             )
  end

  test "reconcile repairs a non-explicit first-party profile stranded on a staged package" do
    actor = SystemActor.system(:addon_rollout_profile_recovery_test)
    unique = System.unique_integer([:positive])
    addon_id = "rollout-profile-recovery-#{unique}"
    previous = approved_package(addon_id, "1.0.0", actor, ["network-observe"])
    stranded = staged_package(addon_id, "1.1.0", actor)
    candidate = approved_package(addon_id, "1.2.0", actor, ["network-observe"])

    {:ok, profile} =
      AddonProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Stranded first-party profile #{unique}",
          addon_package_id: previous.id,
          target_query: "in:agents"
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    Repo.query!(
      """
      UPDATE platform.addon_profiles
      SET addon_package_id = ($1::text)::uuid,
          update_policy = 'manual_pin',
          explicit_version_pin = FALSE,
          capability_ceiling = ARRAY[]::text[]
      WHERE id = ($2::text)::uuid
      """,
      [stranded.id, profile.id]
    )

    assert {:ok, %{recovered_sources: 1, started: 1}} =
             AddonRolloutCoordinator.reconcile(actor: actor)

    {:ok, profile} = AddonProfile.get_by_id(profile.id, actor: actor)
    assert profile.update_policy == :track_latest_approved
    assert profile.capability_ceiling == ["network-observe"]
    assert profile.addon_package_id == candidate.id
  end

  test "pause, resume, and cancel preserve the stable package and clear the candidate override" do
    actor = SystemActor.system(:addon_rollout_pause_test)
    fixture = rollout_fixture(actor)

    assert {:ok, rollout} =
             AddonRolloutCoordinator.start(fixture.assignment, fixture.candidate,
               actor: actor,
               now: fixture.started_at,
               trigger: :manual
             )

    assert :ok = AddonRolloutCoordinator.pause(rollout.id, actor: actor)
    assert get_rollout(rollout.id, actor).state == :paused

    assert :ok = AddonRolloutCoordinator.resume(rollout.id, actor: actor)
    assert get_rollout(rollout.id, actor).state == :running

    assert :ok = AddonRolloutCoordinator.cancel(rollout.id, actor: actor)

    assignment = get_assignment(fixture.assignment.id, actor)
    assert assignment.addon_package_id == fixture.current.id
    assert is_nil(assignment.rollout_package_id)
    assert is_nil(assignment.rollout_id)
    assert get_rollout(rollout.id, actor).state == :canceled
    assert get_rollout_target(rollout.id, actor).state == :canceled
  end

  # openspec/changes/fix-stuck-addon-rollouts. Four rollouts sat paused on the
  # demo fleet for 19 days naming a candidate version the fleet already ran.
  test "a rollout whose candidate the fleet already runs is reaped as superseded" do
    actor = SystemActor.system(:addon_rollout_supersede_test)
    fixture = rollout_fixture(actor)

    assert {:ok, rollout} =
             AddonRolloutCoordinator.start(fixture.assignment, fixture.candidate,
               actor: actor,
               now: fixture.started_at,
               trigger: :manual
             )

    assert :ok = AddonRolloutCoordinator.pause(rollout.id, actor: actor)
    assert get_rollout(rollout.id, actor).state == :paused

    # The agent reached the candidate by some other route entirely.
    later = DateTime.add(fixture.started_at, 60)
    report_status(fixture, fixture.candidate.version, "running", true, later, actor)

    assert :ok = AddonRolloutCoordinator.advance(rollout.id, actor: actor, now: later)

    reaped = get_rollout(rollout.id, actor)
    assert reaped.state == :superseded
    assert reaped.blocked_reason == "fleet_already_on_candidate"

    # Terminal: none of the operator actions apply any more.
    assert {:error, :rollout_not_paused} =
             AddonRolloutCoordinator.resume(rollout.id, actor: actor)

    assert {:error, :rollout_not_active} =
             AddonRolloutCoordinator.cancel(rollout.id, actor: actor)
  end

  test "a fleet already past the candidate is reaped without rolling anything back" do
    actor = SystemActor.system(:addon_rollout_supersede_ahead_test)
    fixture = rollout_fixture(actor)

    assert {:ok, rollout} =
             AddonRolloutCoordinator.start(fixture.assignment, fixture.candidate,
               actor: actor,
               now: fixture.started_at,
               trigger: :manual
             )

    assert :ok = AddonRolloutCoordinator.pause(rollout.id, actor: actor)

    # workload-identity's shape: candidate 0.1.5, agents already on 0.1.7.
    later = DateTime.add(fixture.started_at, 60)
    report_status(fixture, "1.2.0", "running", true, later, actor)

    assert :ok = AddonRolloutCoordinator.advance(rollout.id, actor: actor, now: later)

    reaped = get_rollout(rollout.id, actor)
    assert reaped.state == :superseded
    refute get_rollout_target(rollout.id, actor).state in [:rolled_back, :rollback_pending]
  end

  test "an advancing rollout that reaches the candidate completes rather than being superseded" do
    actor = SystemActor.system(:addon_rollout_not_superseded_test)
    fixture = rollout_fixture(actor)

    assert {:ok, rollout} =
             AddonRolloutCoordinator.start(fixture.assignment, fixture.candidate,
               actor: actor,
               now: fixture.started_at,
               trigger: :manual
             )

    # Reaping on observed version alone cannot tell "the fleet converged
    # elsewhere" from "this rollout just delivered the candidate". Without the
    # paused precondition this hijacked three existing rollout tests, turning
    # healthy promotions into supersessions.
    later = DateTime.add(fixture.started_at, 60)
    report_status(fixture, fixture.candidate.version, "running", true, later, actor)

    assert :ok = AddonRolloutCoordinator.advance(rollout.id, actor: actor, now: later)
    refute get_rollout(rollout.id, actor).state == :superseded
  end

  test "a partially converged rollout is left alone" do
    actor = SystemActor.system(:addon_rollout_partial_test)
    fixture = rollout_fixture(actor)

    assert {:ok, rollout} =
             AddonRolloutCoordinator.start(fixture.assignment, fixture.candidate,
               actor: actor,
               now: fixture.started_at,
               trigger: :manual
             )

    # scalibr's shape: candidate 0.1.3 while the fleet sits on 0.1.2. Lexically
    # "1.0.5" >= "1.1.0" is false, but so is the semantic comparison -- this
    # asserts the version check is not fooled either way.
    later = DateTime.add(fixture.started_at, 60)
    report_status(fixture, "1.0.5", "running", true, later, actor)

    assert :ok = AddonRolloutCoordinator.advance(rollout.id, actor: actor, now: later)
    refute get_rollout(rollout.id, actor).state == :superseded
  end

  test "a running candidate reporting only an advisory degradation still converges" do
    actor = SystemActor.system(:addon_rollout_advisory_test)
    fixture = rollout_fixture(actor)

    assert {:ok, rollout} =
             AddonRolloutCoordinator.start(fixture.assignment, fixture.candidate,
               actor: actor,
               now: fixture.started_at,
               trigger: :manual
             )

    # anomaly's shape on ns01-ns05: running the candidate, reporting only that
    # the host has not delegated the cpu cgroup controller. Before the gate fix
    # this failed as candidate_reported_unhealthy.
    later = DateTime.add(fixture.started_at, 60)

    {:ok, _} =
      AddonStatus
      |> Ash.Changeset.for_create(
        :report,
        %{
          agent_uid: fixture.agent_uid,
          addon_id: fixture.addon_id,
          state: "running",
          active: true,
          version: fixture.candidate.version,
          degradation_reason:
            "resource limits not enforced: enable parent controllers for addon cgroup root " <>
              "/sys/fs/cgroup/serviceradar.slice/serviceradar-addons.slice",
          reported_at: later
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    assert :ok = AddonRolloutCoordinator.advance(rollout.id, actor: actor, now: later)

    refute get_rollout_target(rollout.id, actor).state in [:rolled_back, :rollback_pending],
           "an advisory degradation must not fail the candidate"
  end

  test "candidate failure rolls the target back and requires fresh prior-version recovery evidence" do
    actor = SystemActor.system(:addon_rollout_failure_test)
    fixture = rollout_fixture(actor)

    assert {:ok, rollout} =
             AddonRolloutCoordinator.start(fixture.assignment, fixture.candidate,
               actor: actor,
               now: fixture.started_at,
               trigger: :manual
             )

    failed_at = DateTime.add(fixture.started_at, 1)
    report_status(fixture, fixture.candidate.version, "unhealthy", false, failed_at, actor)

    assert :ok = AddonRolloutCoordinator.advance(rollout.id, actor: actor, now: failed_at)
    assert get_rollout(rollout.id, actor).state == :paused
    assert get_rollout_target(rollout.id, actor).state == :rollback_pending
    assert is_nil(get_assignment(fixture.assignment.id, actor).rollout_package_id)

    recovered_at = DateTime.add(failed_at, 1)
    report_status(fixture, fixture.current.version, "running", true, recovered_at, actor)

    assert :ok =
             AddonRolloutCoordinator.advance(rollout.id, actor: actor, now: recovered_at)

    assert get_rollout(rollout.id, actor).state == :paused
    assert :ok = AddonRolloutCoordinator.resume(rollout.id, actor: actor, now: recovered_at)
    assert get_rollout(rollout.id, actor).state == :failed
    assert get_rollout_target(rollout.id, actor).state == :rolled_back
    assert get_assignment(fixture.assignment.id, actor).addon_package_id == fixture.current.id
  end

  test "an authorized retry creates a fresh attempt without discarding failed rollout evidence" do
    actor = SystemActor.system(:addon_rollout_retry_test)
    fixture = rollout_fixture(actor)

    assert {:ok, rollout} =
             AddonRolloutCoordinator.start(fixture.assignment, fixture.candidate,
               actor: actor,
               now: fixture.started_at,
               trigger: :manual
             )

    failed_at = DateTime.add(fixture.started_at, 1)
    report_status(fixture, fixture.candidate.version, "unhealthy", false, failed_at, actor)
    assert :ok = AddonRolloutCoordinator.advance(rollout.id, actor: actor, now: failed_at)

    recovered_at = DateTime.add(failed_at, 1)
    report_status(fixture, fixture.current.version, "running", true, recovered_at, actor)
    assert :ok = AddonRolloutCoordinator.advance(rollout.id, actor: actor, now: recovered_at)
    assert :ok = AddonRolloutCoordinator.resume(rollout.id, actor: actor, now: recovered_at)
    assert get_rollout(rollout.id, actor).state == :failed

    retry_at = DateTime.add(recovered_at, 1)

    assert {:ok, retried} =
             AddonRolloutCoordinator.retry(rollout.id, actor: actor, now: retry_at)

    assert retried.id != rollout.id
    assert retried.trigger == :retry
    assert retried.state == :running
    assert get_rollout(rollout.id, actor).state == :failed
    assert get_rollout_target(retried.id, actor).state == :waiting_health

    assignment = get_assignment(fixture.assignment.id, actor)
    assert assignment.addon_package_id == fixture.current.id
    assert assignment.rollout_package_id == fixture.candidate.id
    assert assignment.rollout_id == retried.id
  end

  test "retry vacates a leftover succeeded target before inserting a new canary" do
    actor = SystemActor.system(:addon_rollout_retry_succeeded_slot_test)
    fixture = rollout_fixture(actor)

    assert {:ok, rollout} =
             AddonRolloutCoordinator.start(fixture.assignment, fixture.candidate,
               actor: actor,
               now: fixture.started_at,
               trigger: :manual
             )

    target = get_rollout_target(rollout.id, actor)
    failed_at = DateTime.add(fixture.started_at, 1)

    {:ok, _} =
      target
      |> Ash.Changeset.for_update(:update, %{state: :succeeded, completed_at: failed_at})
      |> Ash.update(actor: actor)

    {:ok, _} =
      rollout.id
      |> get_rollout(actor)
      |> Ash.Changeset.for_update(:update, %{
        state: :failed,
        completed_at: failed_at,
        blocked_reason: "candidate_health_timeout"
      })
      |> Ash.update(actor: actor)

    retry_at = DateTime.add(failed_at, 1)

    assert {:ok, retried} =
             AddonRolloutCoordinator.retry(rollout.id, actor: actor, now: retry_at)

    assert retried.id != rollout.id
    assert retried.trigger == :retry
    assert get_rollout_target(rollout.id, actor).state == :promoted
    assert get_rollout_target(retried.id, actor).state == :waiting_health
  end

  test "whole-rollout rollback restores prior desired state before becoming terminal" do
    actor = SystemActor.system(:addon_rollout_whole_rollback_test)
    fixture = rollout_fixture(actor)

    assert {:ok, rollout} =
             AddonRolloutCoordinator.start(fixture.assignment, fixture.candidate,
               actor: actor,
               now: fixture.started_at,
               trigger: :manual
             )

    assert :ok =
             AddonRolloutCoordinator.rollback(rollout.id,
               actor: actor,
               now: DateTime.add(fixture.started_at, 1)
             )

    assert get_rollout(rollout.id, actor).state == :rolling_back
    assert get_rollout_target(rollout.id, actor).state == :rollback_pending

    recovered_at = DateTime.add(fixture.started_at, 2)
    report_status(fixture, fixture.current.version, "running", true, recovered_at, actor)

    assert :ok =
             AddonRolloutCoordinator.advance(rollout.id, actor: actor, now: recovered_at)

    assert get_rollout(rollout.id, actor).state == :rolled_back
    assert get_assignment(fixture.assignment.id, actor).addon_package_id == fixture.current.id
  end

  # Demo ran seven sources 17-19 days behind because one decommissioned agent
  # held every rollout paused. ocsf_agents rows are never deleted, so the dead
  # host stayed a target, failed its health deadline, and landed :rolled_back --
  # and the reap asked it for a status it could never report.
  test "a paused rollout is reaped once its live targets converge despite a dead peer" do
    actor = SystemActor.system(:addon_rollout_dead_peer_supersede_test)
    fixture = profile_rollout_fixture(actor)

    assert {:ok, rollout} =
             AddonRolloutCoordinator.start(fixture.profile, fixture.candidate,
               actor: actor,
               now: fixture.started_at,
               trigger: :manual
             )

    assert :ok = AddonRolloutCoordinator.pause(rollout.id, actor: actor)

    targets = list_rollout_targets(rollout.id, actor)
    assert length(targets) == 2
    dead = Enum.find(targets, &(&1.agent_uid == fixture.dead_uid))

    # What a never-reporting host leaves behind once its deadline elapses.
    {:ok, _} =
      dead
      |> Ash.Changeset.for_update(
        :update,
        %{state: :rolled_back, reason_code: "rollback_recovery_unverified"},
        actor: actor
      )
      |> Ash.update(actor: actor)

    # The live half of the fleet is on the candidate. The dead peer never reports.
    later = DateTime.add(fixture.started_at, 60)
    report_status_for(fixture.addon_id, fixture.live_uid, fixture.candidate.version, later, actor)

    assert :ok = AddonRolloutCoordinator.advance(rollout.id, actor: actor, now: later)

    reaped = get_rollout(rollout.id, actor)
    assert reaped.state == :superseded
    assert reaped.blocked_reason == "fleet_already_on_candidate"
  end

  # addon_rollout_targets_one_active_target_index counts :succeeded as an active
  # target, so leaving those rows behind on a canceled rollout made every later
  # rollout for the source die on a unique-constraint violation that
  # reconcile_source only logs. Cancelling seven rollouts on demo stranded 26.
  test "cancelling a rollout frees its succeeded targets for the next rollout" do
    actor = SystemActor.system(:addon_rollout_cancel_succeeded_test)
    fixture = profile_rollout_fixture(actor)

    assert {:ok, rollout} =
             AddonRolloutCoordinator.start(fixture.profile, fixture.candidate,
               actor: actor,
               now: fixture.started_at,
               trigger: :manual
             )

    targets = list_rollout_targets(rollout.id, actor)
    succeeded = Enum.find(targets, &(&1.agent_uid == fixture.live_uid))

    {:ok, _} =
      succeeded
      |> Ash.Changeset.for_update(:update, %{state: :succeeded}, actor: actor)
      |> Ash.update(actor: actor)

    assert :ok = AddonRolloutCoordinator.cancel(rollout.id, actor: actor)

    index_active = [:pending, :waiting_health, :healthy_soak, :succeeded, :rollback_pending]

    for target <- list_rollout_targets(rollout.id, actor) do
      refute target.state in index_active
    end

    # The point of terminalizing them: the source can roll out again.
    assert {:ok, _next} =
             AddonRolloutCoordinator.start(fixture.profile, fixture.candidate,
               actor: actor,
               now: DateTime.add(fixture.started_at, 120),
               trigger: :manual
             )
  end

  # Operators should never have to write a target query that routes around an
  # agent the system can already see is not there. A non-reporting agent is
  # excluded automatically, exactly like one that advertises it cannot host
  # native add-ons.
  test "an agent that is not reporting is excluded rather than blocking the rollout" do
    actor = SystemActor.system(:addon_rollout_unavailable_excluded_test)
    fixture = profile_rollout_fixture(actor)

    # :register_connected always stamps last_seen_time with now, so age the agent
    # through the real lifecycle action instead. :mark_unavailable moves
    # :connected -> :unavailable, which is the state a retired-but-still-enrolled
    # agent actually sits in, and is what agent_available?/3 reads.
    {:ok, _} =
      fixture.agents
      |> Map.fetch!(fixture.dead_uid)
      |> Ash.Changeset.for_update(:mark_unavailable, %{reason: "test"}, actor: actor)
      |> Ash.update(actor: actor)

    assert {:ok, rollout} =
             AddonRolloutCoordinator.start(fixture.profile, fixture.candidate,
               actor: actor,
               now: fixture.started_at,
               trigger: :manual
             )

    targets = list_rollout_targets(rollout.id, actor)
    dead = Enum.find(targets, &(&1.agent_uid == fixture.dead_uid))
    live = Enum.find(targets, &(&1.agent_uid == fixture.live_uid))

    assert dead.classification == :unavailable
    assert dead.state == :excluded
    assert dead.reason_code == "agent_unavailable_or_stale"
    assert live.classification == :eligible
    assert live.state in [:pending, :waiting_health]
  end

  test "a rollout is not created when no target is eligible" do
    actor = SystemActor.system(:addon_rollout_no_eligible_test)
    fixture = profile_rollout_fixture(actor)

    for uid <- [fixture.live_uid, fixture.dead_uid] do
      {:ok, _} =
        fixture.agents
        |> Map.fetch!(uid)
        |> Ash.Changeset.for_update(:mark_unavailable, %{reason: "test"}, actor: actor)
        |> Ash.update(actor: actor)
    end

    # Promoting here would advance the source to a version no agent has run.
    assert {:error, :no_eligible_targets} =
             AddonRolloutCoordinator.start(fixture.profile, fixture.candidate,
               actor: actor,
               now: fixture.started_at,
               trigger: :manual
             )
  end

  defp profile_rollout_fixture(actor) do
    unique = System.unique_integer([:positive])
    addon_id = "rollout-profile-#{unique}"
    live_uid = "rollout-profile-live-#{unique}"
    dead_uid = "rollout-profile-dead-#{unique}"
    current = approved_package(addon_id, "1.0.0", actor)
    candidate = approved_package(addon_id, "1.1.0", actor)

    agents =
      Map.new([live_uid, dead_uid], fn uid ->
        {:ok, agent} =
          Agent
          |> Ash.Changeset.for_create(
            :register_connected,
            %{
              uid: uid,
              name: "Rollout profile test agent #{uid}",
              version: "1.4.23",
              capabilities: [],
              host: "127.0.0.1",
              port: 50_051,
              metadata: %{"os" => "linux", "arch" => "amd64"}
            },
            actor: actor
          )
          |> Ash.create(actor: actor)

        {uid, agent}
      end)

    {:ok, profile} =
      AddonProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Rollout profile #{unique}",
          addon_package_id: current.id,
          target_query: "in:agents"
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    for uid <- [live_uid, dead_uid] do
      {:ok, _assignment} =
        AddonAssignment
        |> Ash.Changeset.for_create(
          :create,
          %{
            agent_uid: uid,
            addon_package_id: current.id,
            source: :profile,
            source_key: "#{profile.id}:#{uid}",
            addon_profile_id: profile.id,
            rollout_policy: %{
              "canary_size" => 2,
              "batch_size" => 2,
              "max_parallel" => 2,
              "soak_seconds" => 0,
              "health_timeout_seconds" => 60,
              "tolerated_failures" => 0
            }
          },
          actor: actor
        )
        |> Ash.create(actor: actor)
    end

    %{
      addon_id: addon_id,
      live_uid: live_uid,
      dead_uid: dead_uid,
      agents: agents,
      profile: profile,
      current: current,
      candidate: candidate,
      started_at: DateTime.utc_now()
    }
  end

  defp report_status_for(addon_id, agent_uid, version, reported_at, actor) do
    {:ok, status} =
      AddonStatus
      |> Ash.Changeset.for_create(
        :report,
        %{
          agent_uid: agent_uid,
          addon_id: addon_id,
          state: "running",
          active: true,
          version: version,
          reported_at: reported_at
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    status
  end

  defp list_rollout_targets(rollout_id, actor) do
    AddonRolloutTarget
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(rollout_id == ^rollout_id)
    |> Ash.read!(actor: actor)
  end

  defp rollout_fixture(actor) do
    unique = System.unique_integer([:positive])
    addon_id = "rollout-state-#{unique}"
    agent_uid = "rollout-state-agent-#{unique}"
    started_at = DateTime.utc_now()
    current = approved_package(addon_id, "1.0.0", actor)
    candidate = approved_package(addon_id, "1.1.0", actor)

    {:ok, _agent} =
      Agent
      |> Ash.Changeset.for_create(
        :register_connected,
        %{
          uid: agent_uid,
          name: "Rollout state test agent",
          version: "1.4.23",
          capabilities: [],
          host: "127.0.0.1",
          port: 50_051,
          metadata: %{"os" => "linux", "arch" => "amd64"}
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, assignment} =
      AddonAssignment
      |> Ash.Changeset.for_create(
        :create,
        %{
          agent_uid: agent_uid,
          addon_package_id: current.id,
          rollout_policy: %{
            "canary_size" => 1,
            "batch_size" => 1,
            "max_parallel" => 1,
            "soak_seconds" => 0,
            "health_timeout_seconds" => 60,
            "tolerated_failures" => 0
          }
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    %{
      addon_id: addon_id,
      agent_uid: agent_uid,
      assignment: assignment,
      current: current,
      candidate: candidate,
      started_at: started_at
    }
  end

  defp report_status(fixture, version, state, active, reported_at, actor) do
    {:ok, status} =
      AddonStatus
      |> Ash.Changeset.for_create(
        :report,
        %{
          agent_uid: fixture.agent_uid,
          addon_id: fixture.addon_id,
          state: state,
          active: active,
          version: version,
          degradation_reason: if(state == "unhealthy", do: "test_failure"),
          reported_at: reported_at
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    status
  end

  defp approved_package(addon_id, version, actor, approved_capabilities \\ []) do
    package = staged_package(addon_id, version, actor)

    {:ok, package} =
      package
      |> Ash.Changeset.for_update(
        :approve,
        %{
          approved_capabilities: approved_capabilities,
          approved_by: "system:addon_rollout_db_test"
        },
        actor: actor
      )
      |> Ash.update(actor: actor)

    package
  end

  defp staged_package(addon_id, version, actor) do
    {:ok, package} =
      AddonPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          addon_id: addon_id,
          version: version,
          name: "Rollout DB package #{version}",
          source_type: :first_party,
          source_oci_ref: "registry.example/#{addon_id}:#{version}",
          source_oci_digest: "sha256:#{version}",
          verification_status: "verified",
          artifacts: %{
            "linux/amd64" => %{
              "object_key" => "addons/#{addon_id}/#{version}",
              "sha256" => "artifact-#{version}"
            }
          },
          requires: %{"platforms" => ["linux"]},
          config_schema: %{"type" => "object"}
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    package
  end

  defp get_assignment(id, actor) do
    AddonAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(actor: actor)
  end

  defp get_rollout(id, actor) do
    AddonRollout
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(actor: actor)
  end

  defp get_rollout_target(rollout_id, actor) do
    AddonRolloutTarget
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(rollout_id == ^rollout_id)
    |> Ash.read_one!(actor: actor)
  end
end
