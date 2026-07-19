defmodule ServiceRadar.Plugins.AddonRolloutDbTest do
  use ServiceRadar.DataCase, async: false

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
