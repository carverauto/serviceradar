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
    * **No version evidence.** The agent pushed no stamped result for the
      assignment since the override: it predates provenance, or the plugin only
      runs actions and ingests no result for them. The rollout's snapshotted
      `on_no_evidence` policy decides:
      `pass_after_soak` (the default) passes the target after the soak with the
      reason code `no_version_evidence`, which never counts as verified;
      `fail` lets the target time out. An agent that does stamp its results but
      only ever for the previous package has not loaded the candidate, so it
      gets no such pass.

  Evidence is classified per observation, not per row. The ingestor stores a
  downstream-ingest outcome as a separate row keyed by the reported row's
  observation timestamp and payload digest, so a failed downstream ingest fails
  that observation wherever its row sorts. Freshness and order are the reported
  row's server receipt time.

  An action-only plugin that ingests its action results is verified through
  those stamped results. A completed action command is no evidence: nothing
  records which package the agent ran it with.

  A failed evidence read is not an empty one: the targets it covers neither
  pass, fail, recover nor converge, so they wait and eventually time out.

  A failed target rolls the whole rollout back (`rolls_back_on_failure?/1`), and
  `tolerated_failures` is fixed at 0: turning a tolerated failure into a manual
  pin, as add-on profiles do, would conflict with policy reconcilers adopting
  and disabling manual duplicates.

  "Converged" means desired state: every in-scope assignment's stable package
  is at least the candidate.
  """

  @behaviour ServiceRadar.Plugins.RolloutArtifact

  alias ServiceRadar.Observability.PluginResultProvenance
  alias ServiceRadar.Plugins.AddonRollout
  alias ServiceRadar.Plugins.AddonRolloutEligibility, as: Eligibility
  alias ServiceRadar.Plugins.AddonRolloutPolicy
  alias ServiceRadar.Plugins.AddonRolloutTarget
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.PluginTargetPolicy
  alias ServiceRadar.Repo

  require Ash.Expr
  require Ash.Query
  require Logger

  @verified_reason "candidate_health_verified"
  @no_evidence_reason "no_version_evidence"
  @default_on_no_evidence "pass_after_soak"
  @on_no_evidence_values [@default_on_no_evidence, "fail"]
  @determinate_statuses ["OK", "WARNING", "CRITICAL"]

  # Bounds the evidence read to the newest stamped results per target.
  @evidence_rows_per_target 20

  # How far from its observation's timestamp the ingestor writes a downstream
  # ingest marker, with room to spare.
  @downstream_marker_window_seconds 1

  @reported_marker_key "_serviceradar_plugin_result"

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
  def lock_candidate(%PluginPackage{id: id}, actor) do
    PluginPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock("FOR SHARE")
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, %PluginPackage{} = package} ->
        if trusted_approved?(package), do: :ok, else: {:error, :candidate_not_eligible}

      {:ok, nil} ->
        {:error, :candidate_not_eligible}

      {:error, reason} ->
        {:error, reason}
    end
  end

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

  @impl true
  def lock_members(rollout, targets, actor) do
    ids = targets |> Enum.map(& &1.plugin_assignment_id) |> Enum.reject(&is_nil/1)

    with :ok <- lock_owner(rollout, actor) do
      PluginAssignment
      |> Ash.Query.for_read(:read)
      |> filter_members(rollout, ids)
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.lock("FOR UPDATE")
      |> Ash.read(actor: actor)
      |> locked()
    end
  end

  defp lock_owner(%AddonRollout{source_type: :target_policy, source_id: owner_id}, actor) do
    PluginTargetPolicy
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^owner_id)
    |> Ash.Query.lock("FOR UPDATE")
    |> Ash.read(actor: actor)
    |> locked()
  end

  defp lock_owner(_rollout, _actor), do: :ok

  defp filter_members(query, %AddonRollout{source_type: :target_policy} = rollout, ids) do
    owner_id = to_string(rollout.source_id)
    Ash.Query.filter(query, id in ^ids or (source == :policy and policy_id == ^owner_id))
  end

  defp filter_members(query, %AddonRollout{source_id: source_id}, ids),
    do: Ash.Query.filter(query, id in ^[source_id | ids])

  defp locked({:ok, _rows}), do: :ok
  defp locked({:error, reason}), do: {:error, reason}

  # Overrides and promotion.

  @impl true
  def apply_override(target, rollout, now, actor) do
    with {:ok, assignment} <- lock_assignment(target.plugin_assignment_id, actor),
         :ok <- require_enabled(assignment) do
      assignment
      |> Ash.Changeset.for_update(
        :apply_rollout_override,
        %{
          rollout_plugin_package_id: target.candidate_plugin_package_id,
          rollout_id: rollout.id,
          rollout_started_at: now
        },
        actor: actor
      )
      |> Ash.update(actor: actor, authorize?: true, return_notifications?: true)
      |> case do
        {:ok, _assignment, notifications} -> {:ok, notifications}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def clear_override(%AddonRolloutTarget{plugin_assignment_id: nil}, _actor), do: {:ok, []}

  # The UPDATE itself requires the override to still belong to this rollout, so
  # an override another rollout has put on the assignment since is left alone.
  def clear_override(target, actor) do
    owner = target.rollout_id

    with {:ok, assignment} <- get_by_id(PluginAssignment, target.plugin_assignment_id, actor) do
      assignment
      |> Ash.Changeset.for_update(:clear_rollout_override, cleared_override(), actor: actor)
      |> Ash.Changeset.filter(Ash.Expr.expr(rollout_id == ^owner))
      |> Ash.update(actor: actor, authorize?: true, return_notifications?: true)
      |> case do
        {:ok, _assignment, notifications} -> {:ok, notifications}
        {:error, error} -> if stale_write?(error), do: {:ok, []}, else: {:error, error}
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
    with {:ok, assignment} <- get_by_id(PluginAssignment, rollout.source_id, actor) do
      update(
        assignment,
        :promote_rollout,
        Map.put(cleared_override(), :plugin_package_id, rollout.candidate_plugin_package_id),
        actor
      )
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
  end

  # Health evidence.

  @impl true
  def load_evidence([], _rollout, _actor), do: %{}

  def load_evidence(targets, rollout, actor) do
    targets = Enum.reject(targets, &is_nil(&1.plugin_assignment_id))
    on_no_evidence = normalize_policy(rollout.policy)["on_no_evidence"]

    with {:ok, stable_versions} <- stable_versions(targets, actor),
         {:ok, results} <- stamped_results(targets) do
      Map.new(targets, fn target ->
        id = target.plugin_assignment_id

        {id,
         %{
           stable_version: Map.get(stable_versions, id),
           on_no_evidence: on_no_evidence,
           results: Map.get(results, id, [])
         }}
      end)
    else
      {:error, reason} ->
        Logger.warning("Wasm plugin rollout evidence read failed",
          rollout_id: rollout.id,
          reason: inspect(reason)
        )

        Map.new(targets, &{&1.plugin_assignment_id, %{unavailable: true}})
    end
  end

  @impl true
  def evidence_key(%AddonRolloutTarget{plugin_assignment_id: assignment_id}), do: assignment_id

  @impl true
  def observed_at(%{results: [newest | _]}), do: newest.observed_at
  def observed_at(_evidence), do: nil

  @impl true
  def candidate_ready?(nil, _candidate, _applied_at), do: false
  def candidate_ready?(%{unavailable: true}, _candidate, _applied_at), do: false

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
  def candidate_failed?(%{unavailable: true}, _candidate, _applied_at), do: false

  def candidate_failed?(evidence, candidate, applied_at),
    do: verdict(evidence, candidate, applied_at) == :failed

  # Recovery needs stamped evidence too: without it the target stays pending
  # until its deadline and is recorded as rollback_recovery_unverified.
  @impl true
  def recovered?(nil, _previous, _since), do: false
  def recovered?(%{unavailable: true}, _previous, _since), do: false

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

  # The newest observation stamped with `package` and received since `since`
  # that says something about it decides: :healthy or :failed. Otherwise nil.
  defp verdict(nil, _package, _since), do: nil

  defp verdict(evidence, package, since),
    do: evidence |> results_since(since) |> Enum.find_value(&classify(&1, package))

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

  defp stable_versions([], _actor), do: {:ok, %{}}

  defp stable_versions(targets, actor) do
    ids = Enum.map(targets, & &1.plugin_assignment_id)

    PluginAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.load(:plugin_package)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, assignments} ->
        {:ok,
         Map.new(assignments, fn assignment ->
           {assignment.id, package_version(assignment.plugin_package)}
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp package_version(%PluginPackage{version: version}), do: version
  defp package_version(_package), do: nil

  # Stamped observations per assignment, newest first. A target is read from
  # its override (or, rolling back, from its rollback) onward; one with neither
  # has no evidence to read.
  defp stamped_results(targets) do
    scopes =
      Enum.flat_map(targets, fn target ->
        case evidence_since(target) do
          nil -> []
          since -> [{target.plugin_assignment_id, target.agent_uid, since}]
        end
      end)

    with {:ok, reported} <- reported_observations(scopes),
         {:ok, failed} <- failed_downstream(reported) do
      {:ok,
       reported
       |> Enum.map(fn {id, _agent, result} ->
         if MapSet.member?(failed, {id, result.observation_key}),
           do: {id, %{result | outcome: :failed}},
           else: {id, result}
       end)
       |> Enum.group_by(fn {id, _result} -> id end, fn {_id, result} -> result end)}
    end
  end

  defp evidence_since(%AddonRolloutTarget{state: :rollback_pending} = target),
    do: target.rollback_started_at

  defp evidence_since(target), do: target.override_applied_at

  defp reported_observations([]), do: {:ok, []}

  defp reported_observations(scopes) do
    {ids, agents, sinces} = unzip3(scopes)

    case Repo.query(reported_observations_sql(), [
           ids,
           agents,
           sinces,
           @evidence_rows_per_target
         ]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.flat_map(rows, &reported_observation/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Each reported row is one observation. Freshness, order and the limit are the
  # server's receive time (created_at), comparable with the override time. The
  # agent-reported timestamp bounds nothing: an agent clock running behind would
  # otherwise hide the very results that decide the target. The assignment id
  # must appear in a row's details for its provenance to name it, which keeps
  # the rows to the target's own results.
  defp reported_observations_sql do
    """
    SELECT scope.assignment_id, scope.agent_id, status.created_at, status."timestamp", status.details
    FROM unnest($1::text[], $2::text[], $3::timestamptz[]) AS scope(assignment_id, agent_id, since)
    CROSS JOIN LATERAL (
      SELECT result.created_at, result."timestamp", result.details
      FROM platform.service_status AS result
      WHERE result.service_type = 'plugin'
        AND result.agent_id = scope.agent_id
        AND result.created_at >= scope.since
        AND strpos(result.details, scope.assignment_id) > 0
        AND strpos(result.details, '"#{@reported_marker_key}"') > 0
      ORDER BY result.created_at DESC
      LIMIT $4
    ) AS status
    """
  end

  defp reported_observation([assignment_id, agent_id, received_at, observed_at, details]) do
    decoded = decode(details)

    case {PluginResultProvenance.from_details(decoded), Map.get(decoded, @reported_marker_key)} do
      {%{"assignment_id" => ^assignment_id} = provenance, %{} = marker} ->
        [
          {assignment_id, agent_id,
           %{
             received_at: received_at,
             observed_at: observed_at,
             observation_key: observation_key(marker),
             package_id: provenance["plugin_package_id"],
             content_hash: provenance["content_hash"],
             outcome: outcome(decoded)
           }}
        ]

      _unstamped_or_another_assignment ->
        []
    end
  end

  # The {assignment, observation} pairs among `reported` whose downstream ingest
  # failed. The ingestor writes a downstream marker just after its observation's
  # timestamp and names the observation's timestamp and payload digest.
  defp failed_downstream(reported) do
    keyed =
      for {id, agent, %{observation_key: {_observed, digest}} = result} <- reported,
          do: {id, agent, result.observed_at, digest}

    if keyed == [] do
      {:ok, MapSet.new()}
    else
      {ids, agents, observed, digests} = unzip4(keyed)

      case Repo.query(failed_downstream_sql(), [
             ids,
             agents,
             observed,
             digests,
             @downstream_marker_window_seconds
           ]) do
        {:ok, %{rows: rows}} ->
          {:ok, rows |> Enum.flat_map(&failed_downstream_key/1) |> MapSet.new()}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp failed_downstream_sql do
    """
    SELECT scope.assignment_id, result.details
    FROM unnest($1::text[], $2::text[], $3::timestamptz[], $4::text[])
      AS scope(assignment_id, agent_id, observed_at, payload_digest)
    JOIN platform.service_status AS result
      ON result.service_type = 'plugin'
     AND result.agent_id = scope.agent_id
     AND result."timestamp" >= scope.observed_at - make_interval(secs => $5)
     AND result."timestamp" <= scope.observed_at + make_interval(secs => $5)
     AND strpos(result.details, scope.assignment_id) > 0
     AND strpos(result.details, scope.payload_digest) > 0
     AND strpos(result.details, '"downstream_ingest"') > 0
    """
  end

  defp failed_downstream_key([assignment_id, details]) do
    decoded = decode(details)

    with %{"assignment_id" => ^assignment_id} <- PluginResultProvenance.from_details(decoded),
         %{"downstream_ingest" => %{"status" => "failed"} = ingest} <- decoded,
         {_observed, _digest} = key <- observation_key(ingest) do
      [{assignment_id, key}]
    else
      _ -> []
    end
  end

  defp observation_key(%{"observation_timestamp" => observed, "payload_digest" => digest})
       when is_binary(observed) and is_binary(digest),
       do: {observed, digest}

  defp observation_key(_marker), do: nil

  # A determinate status means the plugin ran and judged its target, whatever it
  # judged: a CRITICAL target is not a failed plugin. UNKNOWN is the plugin, or
  # the host running it, failing to complete the run.
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

  defp unzip4(quads) do
    {Enum.map(quads, &elem(&1, 0)), Enum.map(quads, &elem(&1, 1)), Enum.map(quads, &elem(&1, 2)),
     Enum.map(quads, &elem(&1, 3))}
  end

  defp lock_assignment(id, actor) do
    PluginAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock("FOR UPDATE")
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} -> {:error, {:not_found, PluginAssignment, id}}
      result -> result
    end
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

  defp stale_write?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

  defp stale_write?(_error), do: false

  defp update(record, action, attrs, actor) do
    record
    |> Ash.Changeset.for_update(action, attrs, actor: actor)
    |> Ash.update(actor: actor, authorize?: true, return_notifications?: true)
    |> case do
      {:ok, _record, notifications} -> {:ok, notifications}
      {:error, reason} -> {:error, reason}
    end
  end
end
