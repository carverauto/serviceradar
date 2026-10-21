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

    {:ok,
     unique: unique,
     previous: package!(plugin_id, "1.0.0"),
     candidate: package!(plugin_id, "1.1.0"),
     now: DateTime.utc_now()}
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

    assert :ok = AddonRolloutCoordinator.cancel(rollout.id, actor: @system)
    assert delivered_package(member.agent_uid) == {ctx.previous.id, "1.0.0"}
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

  defp policy_with_members!(ctx, count) do
    policy =
      PluginTargetPolicy
      |> Ash.Changeset.for_create(:create, %{
        name: "example-rollout-policy-#{ctx.unique}",
        plugin_package_id: ctx.previous.id,
        input_definitions: [],
        params_template: %{},
        enabled: true
      })
      |> Ash.create!(actor: @system)

    members =
      for index <- 1..count do
        member!(ctx, "agent-#{ctx.unique}-#{index}", "policy", to_string(policy.id))
      end

    {policy, members}
  end

  defp manual_member!(ctx), do: member!(ctx, "agent-#{ctx.unique}-manual", "manual", nil)

  defp member!(ctx, agent_uid, source, policy_id) do
    agent!(agent_uid)
    id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO platform.plugin_assignments
        (id, agent_uid, partition_id, plugin_package_id, plugin_id, source, source_key, policy_id, enabled)
      VALUES ($1::text::uuid, $2, $3, $4::text::uuid, $5, $6, $7, $8, true)
      """,
      [
        id,
        agent_uid,
        @partition,
        ctx.previous.id,
        ctx.previous.plugin_id,
        source,
        "example-source-key-#{id}",
        policy_id
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
      %{"kind" => "reported", "provenance" => provenance(member, package)}
      |> Map.merge(observation_marker(observation))

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
  defp downstream_failure!(member, package, observation) do
    marked_at = DateTime.add(observation.observed_at, 1, :microsecond)

    details =
      Jason.encode!(%{
        "status" => "CRITICAL",
        "summary" => "example downstream failure",
        "downstream_ingest" =>
          %{"status" => "failed", "provenance" => provenance(member, package)}
          |> Map.merge(observation_marker(observation))
      })

    status_row!(member, package, marked_at, marked_at, false, details)
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

  defp package!(plugin_id, version) do
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
    |> Ash.Changeset.for_update(:approve, %{approved_by: "example-reviewer"})
    |> Ash.update!(actor: @system)
  end
end
