defmodule ServiceRadar.Plugins.WasmPluginRolloutArtifact do
  @moduledoc """
  Wasm plugin implementation of `ServiceRadar.Plugins.RolloutArtifact`.

  A source is a manual `PluginAssignment` or a `PluginTargetPolicy`, and its
  members are the enabled assignments it owns: the manual assignment itself, or
  the assignments the policy materialized. Credential-rule owners are not
  sources yet. Rollouts are started explicitly with
  `AddonRolloutCoordinator.start/3`; `managed_sources/1` returns none, so the
  periodic reconcile only advances rollouts that were started.

  ## Overrides and promotion

  The candidate reaches an agent as a per-assignment override
  (`rollout_plugin_package_id`), which config delivery reads as the effective
  package (`PluginAssignment.effective_package_id/1`). The stable
  `plugin_package_id` that owners and reconcilers write is never changed during
  a rollout. Promotion moves the stable package to the candidate and drops the
  override in the same write: on the manual assignment, or on the target policy
  and every enabled assignment it owns, in one transaction.

  ## Health gate

  Evidence is the plugin results the agent pushed for the target's assignment
  after the override, as stored in `service_status`, read only through the
  host-stamped provenance (`ServiceRadar.Observability.PluginResultProvenance`).
  Results without provenance, or stamped for another package, say nothing about
  the candidate: an agent can still flush results of the previous package after
  it acknowledged the candidate config.

    * **Verified.** The latest result stamped with the candidate package has the
      candidate's content hash and a determinate status (`OK`, `WARNING` or
      `CRITICAL`: the plugin ran and judged its target). The target records
      `candidate_health_verified`.
    * **Failed.** The latest result stamped with the candidate package is
      `UNKNOWN` (the plugin, or the host running it, could not complete the
      run), failed downstream ingest, or carries another module's hash.
    * **Verified by an invocation.** Without a stamped result that decides,
      an action the agent completed for the assignment also verifies the
      candidate, when its dispatch record names the candidate package and it
      was dispatched after the agent acknowledged a config newer than the
      override. An action invoked before that acknowledgement can still have
      run the previous package. This is how action-only plugins, which push no
      scheduled results, are verified.
    * **No version evidence.** The agent pushed no stamped result for the
      assignment since the override: it predates provenance, or the plugin only
      runs actions and none was invoked. The rollout's snapshotted `on_no_evidence` policy decides:
      `pass_after_soak` (the default) passes the target after the soak with the
      reason code `no_version_evidence`, which never counts as verified;
      `fail` lets the target time out. An agent that does stamp its results but
      only ever for the previous package has not loaded the candidate, so it
      gets no such pass.

  A failed target rolls the whole rollout back (`rolls_back_on_failure?/1`), and
  `tolerated_failures` is fixed at 0: turning a tolerated failure into a manual
  pin, as add-on profiles do, would conflict with policy reconcilers adopting
  and disabling manual duplicates.

  "Converged" means desired state: every in-scope assignment's stable package
  is at least the candidate.
  """

  @behaviour ServiceRadar.Plugins.RolloutArtifact

  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Observability.PluginResultProvenance
  alias ServiceRadar.Plugins.AddonRollout
  alias ServiceRadar.Plugins.AddonRolloutEligibility, as: Eligibility
  alias ServiceRadar.Plugins.AddonRolloutPolicy
  alias ServiceRadar.Plugins.AddonRolloutTarget
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.PluginTargetPolicy
  alias ServiceRadar.Repo

  require Ash.Query

  @verified_reason "candidate_health_verified"
  @no_evidence_reason "no_version_evidence"
  @default_on_no_evidence "pass_after_soak"
  @on_no_evidence_values [@default_on_no_evidence, "fail"]
  @determinate_statuses ["OK", "WARNING", "CRITICAL"]

  # Bounds the evidence read: the newest stamped results per target, and how far
  # an agent clock may run behind the server before its results are missed.
  @evidence_rows_per_target 20
  @agent_clock_skew_seconds 3_600

  # The command type the northbound dispatcher and producer schedules use to
  # invoke a plugin action.
  @plugin_action_command "plugin.run_action"

  @impl true
  def artifact_kind, do: :wasm_plugin

  # Sources and their stable package.

  @impl true
  def managed_sources(_actor), do: {:ok, []}

  @impl true
  def restore_managed_sources(_packages, _actor), do: {:ok, 0}

  @impl true
  def source_type(%PluginAssignment{}), do: :assignment
  def source_type(%PluginTargetPolicy{}), do: :target_policy

  @impl true
  def source_for_rollout(%AddonRollout{source_type: :assignment, source_id: id}, actor),
    do: get_by_id(PluginAssignment, id, actor)

  def source_for_rollout(%AddonRollout{source_type: :target_policy, source_id: id}, actor),
    do: get_by_id(PluginTargetPolicy, id, actor)

  @impl true
  def stable_package_id(source), do: source.plugin_package_id

  # Owners carry no rollout controls; a rollout gets them from start/3's
  # `:policy` option, or the defaults.
  @impl true
  def rollout_policy(_source), do: nil

  @impl true
  def normalize_policy(policy) do
    policy
    |> AddonRolloutPolicy.normalize()
    |> Map.put("tolerated_failures", 0)
    |> Map.put("on_no_evidence", on_no_evidence(policy))
  end

  # Packages.

  @impl true
  def list_packages(actor) do
    PluginPackage
    |> Ash.Query.for_read(:approved)
    |> Ash.read(actor: actor)
  end

  @impl true
  def get_package(id, actor), do: get_by_id(PluginPackage, id, actor)

  @impl true
  def packages_by_id(ids, actor) do
    PluginPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read(actor: actor)
  end

  @impl true
  def artifact_id(%PluginPackage{plugin_id: plugin_id}), do: plugin_id

  @impl true
  def package_attrs(previous, candidate),
    do: %{previous_plugin_package_id: previous.id, candidate_plugin_package_id: candidate.id}

  @impl true
  def previous_package_id(rollout_or_target), do: rollout_or_target.previous_plugin_package_id

  @impl true
  def candidate_package_id(rollout_or_target), do: rollout_or_target.candidate_plugin_package_id

  # Candidate eligibility: an approved, newer package of the same plugin.
  # Approval is the trust decision for every package origin, and the approved
  # grant is the capability boundary, so there is no separate ceiling.

  @impl true
  def same_lineage?(%PluginPackage{plugin_id: plugin_id}, %PluginPackage{plugin_id: plugin_id}),
    do: true

  def same_lineage?(_candidate, _current), do: false

  @impl true
  def trusted_approved?(%PluginPackage{status: status}), do: status == :approved

  @impl true
  def within_capability_ceiling?(_package, _source), do: true

  @impl true
  def incompatibility(_package, _agent), do: nil

  # Target materialization.

  @impl true
  def source_members(%PluginAssignment{source: :manual, enabled: true} = assignment, _actor),
    do: {:ok, [assignment]}

  # A policy-materialized row follows its owner; rolling it out alone would be
  # undone by the owner's next reconcile.
  def source_members(%PluginAssignment{source: :manual}, _actor),
    do: {:error, :assignment_disabled}

  def source_members(%PluginAssignment{}, _actor), do: {:error, :assignment_owned_by_policy}

  def source_members(%PluginTargetPolicy{enabled: true} = policy, actor),
    do: policy_members(policy, actor)

  def source_members(%PluginTargetPolicy{}, _actor), do: {:error, :target_policy_disabled}

  # The one-enabled-assignment-per-agent-and-plugin index keeps a manual row and
  # a policy row from both running a plugin on one agent, so no member is
  # outranked.
  @impl true
  def overridden_members(_source, _members, _actor), do: {:ok, MapSet.new()}

  @impl true
  def target_attrs(%PluginAssignment{} = assignment, previous) do
    %{
      plugin_assignment_id: assignment.id,
      partition_id: assignment.partition_id,
      agent_uid: assignment.agent_uid,
      addon_id: assignment.plugin_id,
      previous_plugin_package_id: assignment.plugin_package_id || previous.id,
      previous_params: assignment.params || %{}
    }
  end

  @impl true
  def member_id(%AddonRolloutTarget{plugin_assignment_id: assignment_id}), do: assignment_id

  # Overrides and promotion.

  @impl true
  def apply_override(target, rollout, now, actor) do
    with {:ok, assignment} <- get_by_id(PluginAssignment, target.plugin_assignment_id, actor),
         :ok <- require_enabled(assignment),
         {:ok, _} <-
           update(
             assignment,
             :apply_rollout_override,
             %{
               rollout_plugin_package_id: target.candidate_plugin_package_id,
               rollout_id: rollout.id,
               rollout_started_at: now
             },
             actor
           ) do
      :ok
    end
  end

  @impl true
  def clear_override(%AddonRolloutTarget{plugin_assignment_id: nil}, _actor), do: :ok

  def clear_override(target, actor) do
    with {:ok, assignment} <- get_by_id(PluginAssignment, target.plugin_assignment_id, actor) do
      if assignment.rollout_id == target.rollout_id do
        case update(assignment, :clear_rollout_override, cleared_override(), actor) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      else
        :ok
      end
    end
  end

  @impl true
  def tolerates_failures?(_rollout), do: false

  @impl true
  def rolls_back_on_failure?(_rollout), do: true

  @impl true
  def pin_failed_member(_target, _actor), do: {:error, :wasm_rollouts_tolerate_no_failures}

  @impl true
  def promote_source(%AddonRollout{source_type: :assignment} = rollout, actor) do
    with {:ok, assignment} <- get_by_id(PluginAssignment, rollout.source_id, actor),
         {:ok, _} <-
           update(
             assignment,
             :promote_rollout,
             Map.put(cleared_override(), :plugin_package_id, rollout.candidate_plugin_package_id),
             actor
           ) do
      :ok
    end
  end

  def promote_source(%AddonRollout{source_type: :target_policy} = rollout, actor) do
    fn ->
      with {:ok, policy} <- get_by_id(PluginTargetPolicy, rollout.source_id, actor),
           {:ok, _policy} <-
             policy
             |> Ash.Changeset.for_update(
               :promote_rollout,
               %{plugin_package_id: rollout.candidate_plugin_package_id},
               actor: actor
             )
             |> Ash.update(actor: actor, authorize?: true),
           {:ok, members} <- policy_members(policy, actor),
           {:ok, notifications} <- promote_members(members, rollout, actor) do
        notifications
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end
    |> Repo.transaction()
    |> case do
      {:ok, notifications} ->
        _unsent = Ash.Notifier.notify(notifications)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Health evidence.

  @impl true
  def load_evidence([], _rollout, _actor), do: %{}

  def load_evidence(targets, rollout, actor) do
    targets = Enum.reject(targets, &is_nil(&1.plugin_assignment_id))
    on_no_evidence = normalize_policy(rollout.policy)["on_no_evidence"]
    stable_versions = stable_versions(targets, actor)
    results = stamped_results(targets)
    invocations = completed_invocations(targets, actor)

    Map.new(targets, fn target ->
      id = target.plugin_assignment_id

      {id,
       %{
         stable_version: Map.get(stable_versions, id),
         on_no_evidence: on_no_evidence,
         results: Map.get(results, id, []),
         invocations: Map.get(invocations, id, [])
       }}
    end)
  end

  @impl true
  def evidence_key(%AddonRolloutTarget{plugin_assignment_id: assignment_id}), do: assignment_id

  @impl true
  def observed_at(%{results: [newest | _]}), do: newest.observed_at
  def observed_at(_evidence), do: nil

  @impl true
  def candidate_ready?(nil, _candidate, _applied_at), do: false

  def candidate_ready?(evidence, candidate, applied_at) do
    case verdict(evidence, candidate, applied_at) do
      :healthy -> true
      :failed -> false
      nil -> passes_without_evidence?(evidence, applied_at)
    end
  end

  @impl true
  def ready_reason(evidence, candidate, applied_at) do
    if verdict(evidence, candidate, applied_at) == :healthy,
      do: @verified_reason,
      else: @no_evidence_reason
  end

  @impl true
  def candidate_failed?(nil, _candidate, _applied_at), do: false

  def candidate_failed?(evidence, candidate, applied_at),
    do: verdict(evidence, candidate, applied_at) == :failed

  # Recovery needs stamped evidence too: without it the target stays pending
  # until its deadline and is recorded as rollback_recovery_unverified.
  @impl true
  def recovered?(nil, _previous, _since), do: false

  def recovered?(evidence, previous, since), do: verdict(evidence, previous, since) == :healthy

  @impl true
  def converged?(%{stable_version: version}, candidate),
    do: Eligibility.version_at_least?(version, candidate.version)

  def converged?(_evidence, _candidate), do: false

  # Audit and telemetry.

  @impl true
  def audit_resource_type, do: "wasm_plugin_rollout"

  @impl true
  def telemetry_event, do: [:serviceradar, :plugins, :wasm_plugin_rollout, :transition]

  # The newest result stamped with `package` and received since `since` that
  # says something about it decides: :healthy or :failed. Without one, a
  # completed invocation of `package` is :healthy. Otherwise nil.
  defp verdict(nil, _package, _since), do: nil

  defp verdict(evidence, package, since) do
    case evidence |> results_since(since) |> Enum.find_value(&classify(&1, package)) do
      nil -> invoked_verdict(evidence, package)
      stamped -> stamped
    end
  end

  # load_evidence/3 keeps only invocations dispatched after a config
  # acknowledgement that followed the target's override (or rollback).
  defp invoked_verdict(%{invocations: invocations}, package) do
    if Enum.any?(invocations, &same_id?(&1.package_id, package.id)), do: :healthy
  end

  defp invoked_verdict(_evidence, _package), do: nil

  defp passes_without_evidence?(evidence, applied_at) do
    evidence.on_no_evidence == @default_on_no_evidence and
      results_since(evidence, applied_at) == []
  end

  defp results_since(%{results: results}, %DateTime{} = since),
    do: Enum.filter(results, &(DateTime.compare(&1.received_at, since) != :lt))

  defp results_since(_evidence, _since), do: []

  defp classify(result, package) do
    if same_id?(result.package_id, package.id) do
      hash = normalize_hash(result.content_hash)
      expected = normalize_hash(package.content_hash)

      cond do
        result.outcome == :failed -> :failed
        not is_nil(hash) and hash != expected -> :failed
        result.outcome == :ran and not is_nil(hash) -> :healthy
        true -> nil
      end
    end
  end

  defp stable_versions([], _actor), do: %{}

  defp stable_versions(targets, actor) do
    ids = Enum.map(targets, & &1.plugin_assignment_id)

    PluginAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.load(:plugin_package)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, assignments} ->
        Map.new(assignments, fn assignment ->
          {assignment.id, package_version(assignment.plugin_package)}
        end)

      {:error, _} ->
        %{}
    end
  end

  defp package_version(%PluginPackage{version: version}), do: version
  defp package_version(_package), do: nil

  # Stamped results per assignment, newest first. A target is read from its
  # override (or, rolling back, from its rollback) onward; one with neither has
  # no evidence to read.
  defp stamped_results(targets) do
    scopes =
      Enum.flat_map(targets, fn target ->
        case evidence_since(target) do
          nil -> []
          since -> [{target.plugin_assignment_id, target.agent_uid, since}]
        end
      end)

    if scopes == [] do
      %{}
    else
      {ids, agents, sinces} = unzip3(scopes)

      case Repo.query(stamped_results_sql(), [
             ids,
             agents,
             sinces,
             @agent_clock_skew_seconds,
             @evidence_rows_per_target
           ]) do
        {:ok, %{rows: rows}} ->
          rows
          |> Enum.flat_map(&stamped_result/1)
          |> Enum.group_by(fn {id, _result} -> id end, fn {_id, result} -> result end)

        {:error, _reason} ->
          %{}
      end
    end
  end

  # Completed plugin actions per assignment, newest first, that were dispatched
  # after the agent acknowledged a config newer than the target's override or
  # rollback. The acknowledgement is the only sign the agent holds the config
  # that names the package; an action dispatched before it can have run the
  # previous one.
  defp completed_invocations(targets, actor) do
    acks = config_acks(targets, actor)

    scopes =
      Enum.flat_map(targets, fn target ->
        since = evidence_since(target)
        acked_at = Map.get(acks, target.agent_uid)

        if acknowledged_after?(acked_at, since),
          do: [{target.plugin_assignment_id, target.agent_uid, DateTime.to_naive(acked_at)}],
          else: []
      end)

    if scopes == [] do
      %{}
    else
      {ids, agents, acked} = unzip3(scopes)

      case Repo.query(completed_invocations_sql(), [
             ids,
             agents,
             acked,
             @plugin_action_command,
             @evidence_rows_per_target
           ]) do
        {:ok, %{rows: rows}} ->
          Enum.group_by(
            rows,
            fn [id, _dispatched_at, _package_id] -> id end,
            fn [_id, dispatched_at, package_id] ->
              %{dispatched_at: dispatched_at, package_id: package_id}
            end
          )

        {:error, _reason} ->
          %{}
      end
    end
  end

  # config_acked_at has second precision, so an acknowledgement in the same
  # second as the override may be of the config before it; only a later second
  # counts.
  defp acknowledged_after?(%DateTime{} = acked_at, %DateTime{} = since),
    do: DateTime.after?(acked_at, DateTime.truncate(since, :second))

  defp acknowledged_after?(_acked_at, _since), do: false

  defp config_acks(targets, actor) do
    uids = targets |> Enum.map(& &1.agent_uid) |> Enum.uniq()

    Agent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(uid in ^uids)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, agents} -> Map.new(agents, &{&1.uid, &1.config_acked_at})
      {:error, _} -> %{}
    end
  end

  defp completed_invocations_sql do
    """
    SELECT scope.assignment_id, command.inserted_at, command.context ->> 'plugin_package_id'
    FROM unnest($1::text[], $2::text[], $3::timestamp[]) AS scope(assignment_id, agent_id, acked_at)
    CROSS JOIN LATERAL (
      SELECT invocation.inserted_at, invocation.context
      FROM platform.agent_commands AS invocation
      WHERE invocation.status = 'completed'
        AND invocation.command_type = $4
        AND invocation.agent_id = scope.agent_id
        AND invocation.inserted_at > scope.acked_at
        AND invocation.context ->> 'plugin_assignment_id' = scope.assignment_id
      ORDER BY invocation.inserted_at DESC
      LIMIT $5
    ) AS command
    """
  end

  defp evidence_since(%AddonRolloutTarget{state: :rollback_pending} = target),
    do: target.rollback_started_at

  defp evidence_since(target), do: target.override_applied_at

  # Freshness is the server's receive time (created_at), comparable with the
  # override time; the agent-reported timestamp only narrows the index scan.
  # The assignment id must appear in a row's details for its provenance to name
  # it, which keeps the candidate rows to the target's own results.
  defp stamped_results_sql do
    """
    SELECT scope.assignment_id, status.created_at, status."timestamp", status.details
    FROM unnest($1::text[], $2::text[], $3::timestamptz[]) AS scope(assignment_id, agent_id, since)
    CROSS JOIN LATERAL (
      SELECT result.created_at, result."timestamp", result.details
      FROM platform.service_status AS result
      WHERE result.service_type = 'plugin'
        AND result.agent_id = scope.agent_id
        AND result."timestamp" >= scope.since - make_interval(secs => $4)
        AND result.created_at >= scope.since
        AND strpos(result.details, scope.assignment_id) > 0
      ORDER BY result.created_at DESC
      LIMIT $5
    ) AS status
    """
  end

  defp stamped_result([assignment_id, received_at, observed_at, details]) do
    decoded = decode(details)

    case PluginResultProvenance.from_details(decoded) do
      %{"assignment_id" => ^assignment_id} = provenance ->
        [
          {assignment_id,
           %{
             received_at: received_at,
             observed_at: observed_at,
             package_id: provenance["plugin_package_id"],
             content_hash: provenance["content_hash"],
             outcome: outcome(decoded)
           }}
        ]

      _unstamped_or_another_assignment ->
        []
    end
  end

  # A determinate status means the plugin ran and judged its target, whatever it
  # judged: a CRITICAL target is not a failed plugin. UNKNOWN is the plugin, or
  # the host running it, failing to complete the run.
  defp outcome(%{"downstream_ingest" => %{"status" => "failed"}}), do: :failed

  defp outcome(%{"status" => status}) when is_binary(status) do
    case String.upcase(String.trim(status)) do
      "UNKNOWN" -> :failed
      status when status in @determinate_statuses -> :ran
      _ -> :indeterminate
    end
  end

  defp outcome(_details), do: :indeterminate

  defp decode(details) when is_binary(details) do
    case Jason.decode(details) do
      {:ok, %{} = decoded} -> decoded
      _ -> %{}
    end
  end

  defp decode(_details), do: %{}

  defp normalize_hash(hash) when is_binary(hash) do
    case hash |> String.trim() |> String.downcase() |> String.replace_prefix("sha256:", "") do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_hash(_hash), do: nil

  defp same_id?(left, right) when is_binary(left) and is_binary(right),
    do: String.downcase(left) == String.downcase(right)

  defp same_id?(_left, _right), do: false

  defp on_no_evidence(policy) when is_map(policy) do
    value = Map.get(policy, "on_no_evidence", Map.get(policy, :on_no_evidence))

    if to_string(value) in @on_no_evidence_values,
      do: to_string(value),
      else: @default_on_no_evidence
  end

  defp on_no_evidence(_policy), do: @default_on_no_evidence

  defp policy_members(policy, actor) do
    PluginAssignment
    |> Ash.Query.for_read(:all_partitions_for_policy, %{policy_id: to_string(policy.id)},
      actor: actor
    )
    |> Ash.Query.filter(enabled == true)
    |> Ash.read(actor: actor)
  end

  defp promote_members(members, rollout, actor) do
    candidate_id = rollout.candidate_plugin_package_id

    Enum.reduce_while(members, {:ok, []}, fn member, {:ok, notifications} ->
      attrs =
        if member.rollout_id == rollout.id,
          do: Map.put(cleared_override(), :plugin_package_id, candidate_id),
          else: %{plugin_package_id: candidate_id}

      # The actor goes on the changeset too: AssignmentParams checks it when it
      # validates, and only a system actor may change a policy-owned row.
      member
      |> Ash.Changeset.for_update(:promote_rollout, attrs, actor: actor)
      |> Ash.update(actor: actor, authorize?: true, return_notifications?: true)
      |> case do
        {:ok, _member, member_notifications} ->
          {:cont, {:ok, member_notifications ++ notifications}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp require_enabled(%PluginAssignment{enabled: true}), do: :ok
  defp require_enabled(%PluginAssignment{}), do: {:error, :assignment_disabled}

  defp cleared_override,
    do: %{rollout_plugin_package_id: nil, rollout_id: nil, rollout_started_at: nil}

  defp unzip3(triples) do
    {Enum.map(triples, &elem(&1, 0)), Enum.map(triples, &elem(&1, 1)),
     Enum.map(triples, &elem(&1, 2))}
  end

  defp get_by_id(resource, id, actor) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} -> {:error, {:not_found, resource, id}}
      result -> result
    end
  end

  defp update(record, action, attrs, actor) do
    record
    |> Ash.Changeset.for_update(action, attrs, actor: actor)
    |> Ash.update(actor: actor, authorize?: true)
  end
end
