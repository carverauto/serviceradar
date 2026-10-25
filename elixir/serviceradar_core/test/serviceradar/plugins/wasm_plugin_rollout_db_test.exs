defmodule ServiceRadar.Plugins.WasmPluginRolloutDbTest do
  @moduledoc """
  Wasm plugin rollouts for manual and target-policy owners, driven through
  `AddonRolloutCoordinator` with `WasmPluginRolloutArtifact`.

  Health evidence is the plugin results an agent pushed, written here as
  `service_status` rows the way `PluginResultIngestor` stores them, with the
  host-stamped provenance under `_serviceradar_plugin_result.provenance`.
  Assignment rows are inserted directly: each case is about what a rollout does
  to rows that already exist.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.DependencyDiagnostics
  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.AddonRollout
  alias ServiceRadar.Plugins.AddonRolloutCoordinator
  alias ServiceRadar.Plugins.AddonRolloutTarget
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.PluginTargetPolicy
  alias ServiceRadar.Repo

  require Ash.Query

  @moduletag :integration

  @system SystemActor.system(:wasm_plugin_rollout_db_test)
  @partition "default"

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    unique = System.unique_integer([:positive])
    plugin_id = "example-rollout-#{unique}"
    plugin!(plugin_id)

    # Far enough in the past that every result a case writes relative to it
    # has outlived the downstream-ingest settle period.
    now = DateTime.shift(DateTime.utc_now(), minute: -15)

    {:ok,
     unique: unique,
     previous: package!(plugin_id, "1.0.0"),
     candidate: package!(plugin_id, "1.1.0"),
     now: now}
  end

  test "a canary then a batch move overrides and promote the stable package after verified health",
       ctx do
    {policy, [first, second]} = policy_with_members!(ctx, 2)

    {:ok, rollout} =
      AddonRolloutCoordinator.start(policy, ctx.candidate,
        actor: @system,
        now: ctx.now,
        policy: batches(canary_size: 1, max_parallel: 1, soak_seconds: 0)
      )

    assert %{plugin_package_id: previous_id, rollout_plugin_package_id: candidate_id} =
             assignment(first)

    assert previous_id == ctx.previous.id
    assert candidate_id == ctx.candidate.id
    assert %{rollout_plugin_package_id: nil} = assignment(second)

    result!(first, ctx.candidate, "OK", at(ctx, 1))
    assert :ok = AddonRolloutCoordinator.advance(rollout.id, actor: @system, now: at(ctx, 2))

    # The canary passed, and the next batch carries the candidate while the
    # stable package of every member is still the previous one.
    assert %{plugin_package_id: previous_id, rollout_plugin_package_id: candidate_id} =
             assignment(second)

    assert previous_id == ctx.previous.id
    assert candidate_id == ctx.candidate.id
    assert reload(policy).plugin_package_id == ctx.previous.id

    result!(second, ctx.candidate, "OK", at(ctx, 3))
    assert :ok = AddonRolloutCoordinator.advance(rollout.id, actor: @system, now: at(ctx, 4))

    assert %AddonRollout{state: :completed} = reload(rollout)
    assert reload(policy).plugin_package_id == ctx.candidate.id

    for member <- [first, second] do
      assert %{plugin_package_id: stable_id, rollout_plugin_package_id: nil, rollout_id: nil} =
               assignment(member)

      assert stable_id == ctx.candidate.id

      assert %{state: :promoted, reason_code: "candidate_health_verified"} =
               target(rollout, member)
    end
  end

  test "a failing candidate rolls the whole rollout back and clears every override", ctx do
    {policy, [failing, healthy]} = policy_with_members!(ctx, 2)

    {:ok, rollout} =
      AddonRolloutCoordinator.start(policy, ctx.candidate,
        actor: @system,
        now: ctx.now,
        policy: batches(canary_size: 2, max_parallel: 2, soak_seconds: 300)
      )

    result!(failing, ctx.candidate, "UNKNOWN", at(ctx, 1))
    result!(healthy, ctx.candidate, "OK", at(ctx, 1))
    assert :ok = AddonRolloutCoordinator.advance(rollout.id, actor: @system, now: at(ctx, 2))
    assert :ok = AddonRolloutCoordinator.advance(rollout.id, actor: @system, now: at(ctx, 3))

    # Both members are back on the previous package before either recovered.
    for member <- [failing, healthy] do
      assert %{rollout_plugin_package_id: nil, rollout_id: nil} = assignment(member)
      assert %{state: :rollback_pending} = target(rollout, member)
    end

    assert %{state: :rolling_back, blocked_reason: "candidate_reported_unhealthy"} =
             reload(rollout)

    result!(failing, ctx.previous, "OK", at(ctx, 4))
    result!(healthy, ctx.previous, "OK", at(ctx, 4))
    assert :ok = AddonRolloutCoordinator.advance(rollout.id, actor: @system, now: at(ctx, 5))

    assert %{state: :rolled_back, error: "candidate_reported_unhealthy"} = reload(rollout)
    assert reload(policy).plugin_package_id == ctx.previous.id

    for member <- [failing, healthy] do
      assert assignment(member).plugin_package_id == ctx.previous.id
      assert %{state: :rolled_back} = target(rollout, member)
    end
  end

  test "a target passes without version evidence only when its agent stamps no results", ctx do
    {policy, [silent, stale]} = policy_with_members!(ctx, 2)

    {:ok, rollout} =
      AddonRolloutCoordinator.start(policy, ctx.candidate,
        actor: @system,
        now: ctx.now,
        policy: batches(canary_size: 2, max_parallel: 2, soak_seconds: 0)
      )

    # This agent stamps its results, and every one of them still comes from the
    # previous package: it has not loaded the candidate.
    result!(stale, ctx.previous, "OK", at(ctx, 1))
    assert :ok = AddonRolloutCoordinator.advance(rollout.id, actor: @system, now: at(ctx, 2))

    assert %{state: :succeeded, reason_code: "no_version_evidence"} = target(rollout, silent)
    assert %{state: :waiting_health} = target(rollout, stale)
  end

  test "a downstream ingest failure fails its observation even when its row sorts earlier",
       ctx do
    {policy, [member]} = policy_with_members!(ctx, 1)

    {:ok, rollout} =
      AddonRolloutCoordinator.start(policy, ctx.candidate,
        actor: @system,
        now: ctx.now,
        policy: batches(canary_size: 1, max_parallel: 1, soak_seconds: 0)
      )

    # The agent observed at +1s and the server received the result at +3s; the
    # ingestor writes the failed downstream ingest with the observation's
    # timestamp, so its row is older than the healthy reported row.
    observation = %{observed_at: at(ctx, 1), digest: "example-digest-#{ctx.unique}"}
    result!(member, ctx.candidate, "OK", at(ctx, 3), observation)
    downstream_failure!(member, ctx.candidate, observation)

    assert :ok = AddonRolloutCoordinator.advance(rollout.id, actor: @system, now: at(ctx, 4))

    assert %{state: :rolling_back, blocked_reason: "candidate_reported_unhealthy"} =
             reload(rollout)

    assert assignment(member).rollout_plugin_package_id == nil

    assert %{state: :rollback_pending, reason_code: "candidate_reported_unhealthy"} =
             target(rollout, member)
  end

  test "a result whose downstream ingest may still fail waits, then fails with it", ctx do
    {policy, [member]} = policy_with_members!(ctx, 1)

    {:ok, rollout} =
      AddonRolloutCoordinator.start(policy, ctx.candidate,
        actor: @system,
        now: ctx.now,
        policy: batches(canary_size: 1, max_parallel: 1, soak_seconds: 0)
      )

    # Received just now: the ingestor may still be running its handlers.
    received_at = DateTime.utc_now()
    observation = %{observed_at: received_at, digest: "example-pending-#{ctx.unique}"}
    result!(member, ctx.candidate, "OK", received_at, observation)

    assert :ok = AddonRolloutCoordinator.advance(rollout.id, actor: @system, now: at(ctx, 2))
    assert %{state: :waiting_health} = target(rollout, member)

    downstream_failure!(member, ctx.candidate, observation)
    assert :ok = AddonRolloutCoordinator.advance(rollout.id, actor: @system, now: at(ctx, 3))

    assert %{state: :rollback_pending, reason_code: "candidate_reported_unhealthy"} =
             target(rollout, member)
  end

  test "results arriving faster than the settle period are judged by the settled ones", ctx do
    {policy, [steady, failing]} = policy_with_members!(ctx, 2)

    {:ok, rollout} =
      AddonRolloutCoordinator.start(policy, ctx.candidate,
        actor: @system,
        now: ctx.now,
        policy: batches(canary_size: 2, max_parallel: 2, soak_seconds: 0)
      )

    # A plugin reporting every 10 seconds: settled results, then the newest one
    # received just now, whose downstream ingest may still be running.
    for member <- [steady, failing], seconds <- [10, 20, 30] do
      result!(member, ctx.candidate, "OK", at(ctx, seconds))
    end

    result!(failing, ctx.candidate, "UNKNOWN", at(ctx, 40))

    for member <- [steady, failing] do
      received_at = DateTime.utc_now()
      observation = %{observed_at: received_at, digest: "example-latest-#{member.id}"}
      result!(member, ctx.candidate, "OK", received_at, observation)
    end

    assert :ok = AddonRolloutCoordinator.advance(rollout.id, actor: @system, now: at(ctx, 50))

    assert %{reason_code: "candidate_health_verified"} = target(rollout, steady)

    assert %{state: :rollback_pending, reason_code: "candidate_reported_unhealthy"} =
             target(rollout, failing)
  end

  test "a downstream ingest that recovered after a failure verifies its observation", ctx do
    {policy, [member]} = policy_with_members!(ctx, 1)

    {:ok, rollout} =
      AddonRolloutCoordinator.start(policy, ctx.candidate,
        actor: @system,
        now: ctx.now,
        policy: batches(canary_size: 1, max_parallel: 1, soak_seconds: 0)
      )

    observation = %{observed_at: at(ctx, 1), digest: "example-recovered-#{ctx.unique}"}
    result!(member, ctx.candidate, "OK", at(ctx, 2), observation)
    downstream_failure!(member, ctx.candidate, observation)
    downstream_recovery!(member, ctx.candidate, observation)

    assert :ok = AddonRolloutCoordinator.advance(rollout.id, actor: @system, now: at(ctx, 3))

    assert %AddonRollout{state: :completed} = reload(rollout)

    assert %{state: :promoted, reason_code: "candidate_health_verified"} =
             target(rollout, member)
  end

  test "older results with later agent timestamps do not hide a fresh candidate failure",
       ctx do
    {policy, [member]} = policy_with_members!(ctx, 1)

    {:ok, rollout} =
      AddonRolloutCoordinator.start(policy, ctx.candidate,
        actor: @system,
        now: ctx.now,
        policy: batches(canary_size: 1, max_parallel: 1, soak_seconds: 0)
      )

    # Results of the previous package received before the override, from an
    # agent whose clock has since moved back, outnumber the evidence read.
    for index <- 1..25 do
      observation = %{observed_at: at(ctx, 600 + index), digest: "example-stale-#{index}"}
      result!(member, ctx.previous, "OK", at(ctx, -index), observation)
    end

    result!(member, ctx.candidate, "UNKNOWN", at(ctx, 1))
    assert :ok = AddonRolloutCoordinator.advance(rollout.id, actor: @system, now: at(ctx, 2))

    assert %{state: :rollback_pending, reason_code: "candidate_reported_unhealthy"} =
             target(rollout, member)
  end

  test "a candidate failure observed by an agent clock far behind the server still fails",
       ctx do
    {policy, [member]} = policy_with_members!(ctx, 1)

    {:ok, rollout} =
      AddonRolloutCoordinator.start(policy, ctx.candidate,
        actor: @system,
        now: ctx.now,
        policy: batches(canary_size: 1, max_parallel: 1, soak_seconds: 0)
      )

    # Received after the override, stamped with an observation time two hours
    # before it.
    observation = %{observed_at: at(ctx, -7_200), digest: "example-behind-#{ctx.unique}"}
    result!(member, ctx.candidate, "UNKNOWN", at(ctx, 1), observation)

    assert :ok = AddonRolloutCoordinator.advance(rollout.id, actor: @system, now: at(ctx, 2))

    assert %{state: :rollback_pending, reason_code: "candidate_reported_unhealthy"} =
             target(rollout, member)
  end

  test "retracting an assignment during a rollout clears its override and cancels its target",
       ctx do
    {policy, [member]} = policy_with_members!(ctx, 1)

    {:ok, rollout} =
      AddonRolloutCoordinator.start(policy, ctx.candidate,
        actor: @system,
        now: ctx.now,
        policy: batches(canary_size: 1, max_parallel: 1, soak_seconds: 300)
      )

    assert assignment(member).rollout_id == rollout.id

    operator = %{
      id: "plugin-operator-#{ctx.unique}",
      email: "plugin-operator@example.com",
      role: :operator,
      permissions: MapSet.new(["settings.plugins.manage"])
    }

    policy
    |> Ash.Changeset.for_update(:update, %{enabled: false}, actor: operator)
    |> Ash.update!()

    assert %{
             enabled: false,
             disabled_reason: :owner_disabled,
             rollout_plugin_package_id: nil,
             rollout_id: nil,
             rollout_started_at: nil
           } = assignment(member)

    assert %{state: :canceled, reason_code: "assignment_retracted", error: "owner_disabled"} =
             target(rollout, member)

    # No target ran the candidate, so the rollout ends without moving the
    # disabled owner or its member to it.
    _ = AddonRolloutCoordinator.advance(rollout.id, actor: @system, now: at(ctx, 1))

    assert %{state: :canceled, blocked_reason: "every_target_canceled"} = reload(rollout)
    assert reload(policy).plugin_package_id == ctx.previous.id
    assert assignment(member).plugin_package_id == ctx.previous.id
  end

  test "a batch launch cancels a target whose assignment was disabled after it was planned",
       ctx do
    {policy, members} = policy_with_members!(ctx, 2)

    {:ok, rollout} =
      AddonRolloutCoordinator.start(policy, ctx.candidate,
        actor: @system,
        now: ctx.now,
        policy: batches(canary_size: 1, max_parallel: 1, soak_seconds: 0)
      )

    {[canary], [later]} = Enum.split_with(members, &(assignment(&1).rollout_id == rollout.id))

    # Disabled underneath the rollout, the way a write that skips the owner's
    # retraction path would leave it: the target still waits to launch.
    Repo.query!(
      "UPDATE platform.plugin_assignments SET enabled = false WHERE id = $1::text::uuid",
      [later.id]
    )

    result!(canary, ctx.candidate, "OK", at(ctx, 1))
    assert :ok = AddonRolloutCoordinator.advance(rollout.id, actor: @system, now: at(ctx, 2))

    assert %{state: :canceled, reason_code: "assignment_retracted"} = target(rollout, later)
    assert %{rollout_plugin_package_id: nil, rollout_id: nil} = assignment(later)
    refute reload(rollout).state == :paused
  end

  test "a rollout does not start for a candidate revoked after the caller read it", ctx do
    member = manual_member!(ctx)
    read_before_revocation = ctx.candidate

    ctx.candidate
    |> Ash.Changeset.for_update(:revoke, %{denied_reason: "example revocation"})
    |> Ash.update!(actor: @system)

    assert {:error, :candidate_not_eligible} =
             AddonRolloutCoordinator.start(assignment(member), read_before_revocation,
               actor: @system,
               now: ctx.now,
               policy: batches(canary_size: 1, max_parallel: 1, soak_seconds: 300)
             )

    assert %{rollout_plugin_package_id: nil, rollout_id: nil} = assignment(member)
  end

  test "promotion keeps a package the owner was moved to during the rollout", ctx do
    member = manual_member!(ctx)
    chosen = package!(ctx.previous.plugin_id, "1.2.0")

    {:ok, rollout} =
      AddonRolloutCoordinator.start(assignment(member), ctx.candidate,
        actor: @system,
        now: ctx.now,
        policy: batches(canary_size: 1, max_parallel: 1, soak_seconds: 0)
      )

    # An operator selects another version for the assignment while the
    # candidate is still proving itself on it.
    Repo.query!(
      "UPDATE platform.plugin_assignments SET plugin_package_id = $2::text::uuid WHERE id = $1::text::uuid",
      [member.id, chosen.id]
    )

    result!(member, ctx.candidate, "OK", at(ctx, 1))
    assert :ok = AddonRolloutCoordinator.advance(rollout.id, actor: @system, now: at(ctx, 2))

    assert %{plugin_package_id: stable_id, rollout_plugin_package_id: nil, rollout_id: nil} =
             assignment(member)

    assert stable_id == chosen.id

    assert %{state: :superseded, blocked_reason: "owner_package_changed"} = reload(rollout)
    assert %{state: :canceled} = target(rollout, member)
  end

  test "revoking the candidate rolls its active rollout back", ctx do
    member = manual_member!(ctx)

    {:ok, rollout} =
      AddonRolloutCoordinator.start(assignment(member), ctx.candidate,
        actor: @system,
        now: ctx.now,
        policy: batches(canary_size: 1, max_parallel: 1, soak_seconds: 300)
      )

    assert assignment(member).rollout_plugin_package_id == ctx.candidate.id

    ctx.candidate
    |> Ash.Changeset.for_update(:revoke, %{denied_reason: "example revocation"})
    |> Ash.update!(actor: @system)

    assert %{state: :rolling_back, blocked_reason: "candidate_revoked"} = reload(rollout)

    assert %{plugin_package_id: stable_id, rollout_plugin_package_id: nil, rollout_id: nil} =
             assignment(member)

    assert stable_id == ctx.previous.id
    assert %{state: :rollback_pending} = target(rollout, member)
  end

  test "config delivery hands the agent the package a rollout override names", ctx do
    member = manual_member!(ctx)

    {:ok, rollout} =
      AddonRolloutCoordinator.start(assignment(member), ctx.candidate,
        actor: @system,
        now: ctx.now,
        policy: batches(canary_size: 1, max_parallel: 1, soak_seconds: 300)
      )

    assert delivered_package(member.agent_uid) == {ctx.candidate.id, "1.1.0"}
    assert config_pushes(member) == 1

    assert :ok = AddonRolloutCoordinator.cancel(rollout.id, actor: @system)
    assert delivered_package(member.agent_uid) == {ctx.previous.id, "1.0.0"}
    assert config_pushes(member) == 2
  end

  for state <- [:running, :paused] do
    test "deleting a manual assignment during its #{state} rollout cancels the rollout", ctx do
      member = manual_member!(ctx)

      {:ok, rollout} =
        AddonRolloutCoordinator.start(assignment(member), ctx.candidate,
          actor: @system,
          now: ctx.now,
          policy: batches(canary_size: 1, max_parallel: 1, soak_seconds: 300)
        )

      if unquote(state) == :paused do
        assert :ok = AddonRolloutCoordinator.pause(rollout.id, actor: @system, now: at(ctx, 1))
        assert %{state: :paused} = reload(rollout)
      end

      member
      |> assignment()
      |> Ash.Changeset.for_destroy(:destroy)
      |> Ash.destroy!(actor: @system)

      _ = AddonRolloutCoordinator.advance(rollout.id, actor: @system, now: at(ctx, 2))
      _ = AddonRolloutCoordinator.advance(rollout.id, actor: @system, now: at(ctx, 3))

      assert %{state: :canceled, paused_at: nil} = reload(rollout)

      assert [%{state: :canceled, reason_code: "assignment_deleted", plugin_assignment_id: nil}] =
               targets(rollout)
    end
  end

  # Run with the shipped setting, not one the case turns on: tracking owners
  # roll forward by default.
  describe "automatic rollouts for owners tracking the latest approved package" do
    test "approving a newer package starts rollouts for tracking owners only", ctx do
      tracking = member!(ctx, "agent-#{ctx.unique}-tracking", "manual", nil, tracking_owner(ctx))
      pinned = member!(ctx, "agent-#{ctx.unique}-pinned", "manual", nil, package: ctx.candidate)

      {policy, [policy_member]} = policy_with_members!(ctx, 1, tracking_owner(ctx))

      # A credential rule's assignment: step F moves these owners.
      rule_member =
        member!(
          ctx,
          "agent-#{ctx.unique}-rule",
          "policy",
          "network-credential-rule:example-#{ctx.unique}",
          package: ctx.candidate
        )

      newer = staged_package!(ctx.candidate.plugin_id, "1.2.0")
      reconcile!(ctx, 0)
      assert rollouts(:assignment, tracking) == []

      approve!(newer)
      reconcile!(ctx, 1)

      for {source_type, source, member} <- [
            {:assignment, tracking, tracking},
            {:target_policy, policy, policy_member}
          ] do
        assert [%AddonRollout{trigger: :track_latest, candidate_plugin_package_id: candidate_id}] =
                 rollouts(source_type, source)

        assert candidate_id == newer.id
        assert assignment(member).rollout_plugin_package_id == newer.id
      end

      for untouched <- [pinned, rule_member] do
        assert %{plugin_package_id: stable_id, rollout_plugin_package_id: nil} =
                 assignment(untouched)

        assert stable_id == ctx.candidate.id
        assert rollouts(:assignment, untouched) == []
      end
    end

    test "a reconcile re-run or a repeated approval starts no second rollout", ctx do
      tracking =
        member!(ctx, "agent-#{ctx.unique}-tracking", "manual", nil,
          update_policy: "track_latest_approved"
        )

      reconcile!(ctx, 0)
      assert {:error, _already_approved} = approve(ctx.candidate)
      reconcile!(ctx, 1)

      assert [%AddonRollout{state: :running} = rollout] = rollouts(:assignment, tracking)

      result!(tracking, ctx.candidate, "OK", at(ctx, 2))
      reconcile!(ctx, 3)
      reconcile!(ctx, 400)

      assert %AddonRollout{state: :completed} = reload(rollout)
      assert assignment(tracking).plugin_package_id == ctx.candidate.id

      reconcile!(ctx, 401)
      assert [%AddonRollout{id: only_id}] = rollouts(:assignment, tracking)
      assert only_id == rollout.id
    end

    test "a newer approval waits for a running rollout and supersedes a paused one", ctx do
      tracking =
        member!(ctx, "agent-#{ctx.unique}-tracking", "manual", nil,
          update_policy: "track_latest_approved"
        )

      reconcile!(ctx, 0)
      assert [%AddonRollout{state: :running} = running] = rollouts(:assignment, tracking)

      newer = approve!(staged_package!(ctx.candidate.plugin_id, "1.2.0"))
      reconcile!(ctx, 1)

      assert [%AddonRollout{id: running_id}] = rollouts(:assignment, tracking)
      assert running_id == running.id
      assert assignment(tracking).rollout_plugin_package_id == ctx.candidate.id

      assert :ok = AddonRolloutCoordinator.pause(running.id, actor: @system, now: at(ctx, 2))
      reconcile!(ctx, 3)

      assert %{state: :superseded, blocked_reason: "newer_candidate_approved"} = reload(running)

      assert [%AddonRollout{trigger: :track_latest, candidate_plugin_package_id: candidate_id}] =
               :assignment |> rollouts(tracking) |> Enum.reject(&(&1.id == running.id))

      assert candidate_id == newer.id
      assert assignment(tracking).rollout_plugin_package_id == newer.id
    end

    test "a prerelease moves an owner only when selected explicitly", ctx do
      tracking = member!(ctx, "agent-#{ctx.unique}-tracking", "manual", nil, tracking_owner(ctx))
      prerelease = approve!(staged_package!(ctx.candidate.plugin_id, "1.2.0-rc.1"))

      reconcile!(ctx, 0)
      assert rollouts(:assignment, tracking) == []

      assert {:ok, %AddonRollout{trigger: :manual}} =
               AddonRolloutCoordinator.start(assignment(tracking), prerelease,
                 actor: @system,
                 now: at(ctx, 1),
                 policy: batches(canary_size: 1, max_parallel: 1, soak_seconds: 300)
               )

      assert assignment(tracking).rollout_plugin_package_id == prerelease.id
    end
  end

  test "owners tracking the latest approved package stay put when automatic rollouts are turned off",
       ctx do
    set_automatic_rollouts(false)

    tracking =
      member!(ctx, "agent-#{ctx.unique}-tracking", "manual", nil,
        update_policy: "track_latest_approved"
      )

    reconcile!(ctx, 0)

    assert rollouts(:assignment, tracking) == []
    assert %{rollout_plugin_package_id: nil} = assignment(tracking)
  end

  # The setting is global, so the case restores whatever was configured before,
  # including leaving it unset.
  defp set_automatic_rollouts(enabled?) do
    previous = Application.fetch_env(:serviceradar_core, :wasm_plugin_automatic_rollouts)
    Application.put_env(:serviceradar_core, :wasm_plugin_automatic_rollouts, enabled?)

    on_exit(fn ->
      case previous do
        {:ok, value} ->
          Application.put_env(:serviceradar_core, :wasm_plugin_automatic_rollouts, value)

        :error ->
          Application.delete_env(:serviceradar_core, :wasm_plugin_automatic_rollouts)
      end
    end)
  end

  defp tracking_owner(ctx), do: [package: ctx.candidate, update_policy: "track_latest_approved"]

  defp reconcile!(ctx, seconds) do
    assert {:ok, _summary} =
             AddonRolloutCoordinator.reconcile(actor: @system, now: at(ctx, seconds))
  end

  defp rollouts(source_type, %{id: id}) do
    AddonRollout
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      artifact_kind == :wasm_plugin and source_type == ^source_type and source_id == ^id
    )
    |> Ash.read!(actor: @system)
  end

  defp targets(rollout) do
    AddonRolloutTarget
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(rollout_id == ^rollout.id)
    |> Ash.read!(actor: @system)
  end

  # Config pushes the agent-config dependency catalog dispatched for the
  # member's assignment.
  defp config_pushes(member) do
    ServiceRadar.TestSupport.drain_dependency_dispatcher_tasks()

    DependencyDiagnostics.recent()
    |> Enum.filter(fn diagnostic ->
      diagnostic.dependency_id == :plugin_assignment_agent_config and
        to_string(diagnostic.resource_id) == member.id and
        diagnostic.affected_agents == [member.agent_uid]
    end)
    |> length()
  end

  defp batches(opts) do
    %{
      "canary_size" => Keyword.fetch!(opts, :canary_size),
      "batch_size" => 1,
      "max_parallel" => Keyword.fetch!(opts, :max_parallel),
      "soak_seconds" => Keyword.fetch!(opts, :soak_seconds),
      "health_timeout_seconds" => 600
    }
  end

  defp at(ctx, seconds), do: DateTime.shift(ctx.now, second: seconds)

  defp delivered_package(agent_uid) do
    {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @partition)
    assert [plugin] = config.plugins
    {plugin.package_id, plugin.version}
  end

  defp policy_with_members!(ctx, count, opts \\ []) do
    package = Keyword.get(opts, :package, ctx.previous)

    policy =
      PluginTargetPolicy
      |> Ash.Changeset.for_create(:create, %{
        name: "example-rollout-policy-#{ctx.unique}",
        plugin_package_id: package.id,
        input_definitions: [],
        params_template: %{},
        enabled: true,
        update_policy: Keyword.get(opts, :update_policy, "pinned")
      })
      |> Ash.create!(actor: @system)

    members =
      for index <- 1..count do
        member!(ctx, "agent-#{ctx.unique}-#{index}", "policy", to_string(policy.id),
          package: package
        )
      end

    {policy, members}
  end

  defp manual_member!(ctx), do: member!(ctx, "agent-#{ctx.unique}-manual", "manual", nil)

  # Options: `:package` (default the previous package) and `:update_policy`
  # (default pinned, the column default).
  defp member!(ctx, agent_uid, source, policy_id, opts \\ []) do
    agent!(agent_uid)
    id = Ecto.UUID.generate()
    package = Keyword.get(opts, :package, ctx.previous)

    Repo.query!(
      """
      INSERT INTO platform.plugin_assignments
        (id, agent_uid, partition_id, plugin_package_id, plugin_id, source, source_key, policy_id,
         enabled, update_policy)
      VALUES ($1::text::uuid, $2, $3, $4::text::uuid, $5, $6, $7, $8, true, $9)
      """,
      [
        id,
        agent_uid,
        @partition,
        package.id,
        package.plugin_id,
        source,
        "example-source-key-#{id}",
        policy_id,
        Keyword.get(opts, :update_policy, "pinned")
      ]
    )

    %{id: id, agent_uid: agent_uid}
  end

  defp agent!(uid) do
    Agent
    |> Ash.Changeset.for_create(:register_connected, %{
      uid: uid,
      name: "Example rollout agent",
      version: "1.4.0",
      capabilities: [],
      host: "192.0.2.10",
      port: 50_051,
      metadata: %{"os" => "linux", "arch" => "amd64"}
    })
    |> Ash.create!(actor: @system)
  end

  # A plugin result as PluginResultIngestor stores it, stamped by the agent host
  # with the assignment, package and module hash that produced it.
  defp result!(member, package, status, received_at, observation \\ nil) do
    marker =
      Map.merge(
        %{"kind" => "reported", "provenance" => provenance(member, package)},
        observation_marker(observation)
      )

    details =
      Jason.encode!(%{
        "status" => status,
        "summary" => "example result",
        "_serviceradar_plugin_result" => marker
      })

    observed_at = if observation, do: observation.observed_at, else: received_at
    status_row!(member, package, observed_at, received_at, status == "OK", details)
  end

  # The marker row PluginResultIngestor writes when a downstream handler failed
  # for an observation: timestamped and created at the observation's time.
  defp downstream_failure!(member, package, observation),
    do: downstream_marker!(member, package, observation, "failed", 1)

  # The marker the ingestor writes when a retried downstream ingest succeeds for
  # an observation whose earlier attempt failed: timestamped after the failure.
  defp downstream_recovery!(member, package, observation),
    do: downstream_marker!(member, package, observation, "succeeded", 2)

  defp downstream_marker!(member, package, observation, status, offset_us) do
    marked_at = DateTime.add(observation.observed_at, offset_us, :microsecond)

    details =
      Jason.encode!(%{
        "status" => if(status == "failed", do: "CRITICAL", else: "OK"),
        "summary" => "example downstream #{status}",
        "downstream_ingest" =>
          Map.merge(
            %{"status" => status, "provenance" => provenance(member, package)},
            observation_marker(observation)
          )
      })

    status_row!(member, package, marked_at, marked_at, status != "failed", details)
  end

  defp provenance(member, package) do
    %{
      "assignment_id" => member.id,
      "plugin_id" => package.plugin_id,
      "plugin_package_id" => package.id,
      "plugin_version" => package.version,
      "content_hash" => package.content_hash
    }
  end

  defp observation_marker(nil), do: %{}

  defp observation_marker(observation) do
    %{
      "observation_timestamp" => DateTime.to_iso8601(observation.observed_at),
      "payload_digest" => observation.digest
    }
  end

  defp status_row!(member, package, observed_at, received_at, available, details) do
    Repo.query!(
      """
      INSERT INTO platform.service_status
        ("timestamp", gateway_id, agent_id, service_name, service_type, available,
         message, details, partition, created_at)
      VALUES ($1, $2, $3, $4, 'plugin', $5, 'example result', $6, $7, $8)
      """,
      [
        observed_at,
        "example-gateway-#{member.agent_uid}",
        member.agent_uid,
        package.name,
        available,
        details,
        @partition,
        received_at
      ]
    )
  end

  defp assignment(%{id: id}), do: Ash.get!(PluginAssignment, id, actor: @system)

  defp target(rollout, member) do
    AddonRolloutTarget
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(rollout_id == ^rollout.id and plugin_assignment_id == ^member.id)
    |> Ash.read_one!(actor: @system)
  end

  defp reload(%AddonRollout{id: id}), do: Ash.get!(AddonRollout, id, actor: @system)
  defp reload(%PluginTargetPolicy{id: id}), do: Ash.get!(PluginTargetPolicy, id, actor: @system)

  defp plugin!(plugin_id) do
    Plugin
    |> Ash.Changeset.for_create(:create, %{plugin_id: plugin_id, name: "Example Rollout"})
    |> Ash.create!(actor: @system)
  end

  defp package!(plugin_id, version), do: plugin_id |> staged_package!(version) |> approve!()

  defp approve!(package) do
    {:ok, approved} = approve(package)
    approved
  end

  defp approve(package) do
    package
    |> Ash.Changeset.for_update(:approve, %{approved_by: "example-reviewer"})
    |> Ash.update(actor: @system)
  end

  defp staged_package!(plugin_id, version) do
    PluginPackage
    |> Ash.Changeset.for_create(:create, %{
      plugin_id: plugin_id,
      name: "Example Rollout",
      version: version,
      entrypoint: "run_check",
      runtime: "wasi-preview1",
      outputs: "serviceradar.plugin_result.v1",
      manifest: %{
        "id" => plugin_id,
        "name" => "Example Rollout",
        "version" => version,
        "entrypoint" => "run_check",
        "runtime" => "wasi-preview1",
        "outputs" => "serviceradar.plugin_result.v1",
        "capabilities" => ["submit_result"],
        "resources" => %{"requested_memory_mb" => 32, "requested_cpu_ms" => 100}
      },
      config_schema: %{},
      display_contract: %{},
      content_hash: Base.encode16(:crypto.hash(:sha256, "#{plugin_id}:#{version}"), case: :lower),
      signature: %{},
      source_type: :upload
    })
    |> Ash.create!(actor: @system)
    |> Ash.Changeset.for_update(:update, %{
      wasm_object_key: "plugins/#{plugin_id}/#{version}/plugin.wasm"
    })
    |> Ash.update!(actor: @system)
  end
end
