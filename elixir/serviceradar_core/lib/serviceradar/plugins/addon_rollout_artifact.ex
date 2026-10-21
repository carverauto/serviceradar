defmodule ServiceRadar.Plugins.AddonRolloutArtifact do
  @moduledoc """
  Native add-on implementation of `ServiceRadar.Plugins.RolloutArtifact`.

  A source is a direct `AddonAssignment` or an `AddonProfile`, and its members
  are the enabled assignments it owns. The stable package on an assignment or
  profile is never changed during a canary: the candidate reaches the agent as
  a per-assignment override (`rollout_package_id`), and only fresh
  `AddonStatus` for the candidate version can pass the gate.

  Compatibility and readiness follow the package's supervision model, so the
  host and health predicates the fleet view and the profile reconciler share
  live here too.
  """

  @behaviour ServiceRadar.Plugins.RolloutArtifact

  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonProfile
  alias ServiceRadar.Plugins.AddonProfileOps
  alias ServiceRadar.Plugins.AddonRollout
  alias ServiceRadar.Plugins.AddonRolloutEligibility, as: Eligibility
  alias ServiceRadar.Plugins.AddonRolloutPolicy
  alias ServiceRadar.Plugins.AddonRolloutTarget
  alias ServiceRadar.Plugins.AddonStatus

  require Ash.Query

  # Reported by an agent that actually accepts native add-on assignments. Kept as a
  # positive/negative pair so an agent that genuinely can host them opts in, and one
  # that knows it cannot opts out, without either relying on the deployment-type
  # guess below.
  @native_addon_host_capability "addon.native.host"
  @native_addon_host_unavailable_capability "addon.native.host.unavailable"

  @containerized_deployment_types ~w(kubernetes docker lxc container)

  @impl true
  def artifact_kind, do: :native_addon

  # Sources and their stable package.

  @impl true
  def managed_sources(actor) do
    with {:ok, assignments} <- managed_assignments(actor),
         {:ok, profiles} <- managed_profiles(actor) do
      {:ok, Enum.concat(assignments, profiles)}
    end
  end

  # Older releases could leave verified first-party sources on `manual_pin`
  # even though no operator selected a pin. Recover only those non-explicit
  # sources, and only once a genuinely newer approved package exists. The
  # approved candidate's capabilities become the ceiling, so a later
  # permission expansion remains blocked for review.
  @impl true
  def restore_managed_sources(packages, actor) do
    with {:ok, assignments} <- recoverable_assignments(actor),
         {:ok, profiles} <- recoverable_profiles(actor) do
      assignments
      |> Enum.concat(profiles)
      |> Enum.reduce_while({:ok, 0}, fn source, {:ok, count} ->
        case restore_non_explicit_source(source, packages, actor) do
          :unchanged -> {:cont, {:ok, count}}
          {:ok, _source} -> {:cont, {:ok, count + 1}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  @impl true
  def source_type(%AddonAssignment{}), do: :assignment
  def source_type(%AddonProfile{}), do: :profile

  @impl true
  def source_for_rollout(%AddonRollout{source_type: :assignment, source_id: source_id}, actor),
    do: get_assignment(source_id, actor)

  def source_for_rollout(%AddonRollout{source_type: :profile, source_id: source_id}, actor),
    do: get_profile(source_id, actor)

  @impl true
  def stable_package_id(source), do: source.addon_package_id

  @impl true
  def rollout_policy(source), do: source.rollout_policy

  @impl true
  def normalize_policy(policy), do: AddonRolloutPolicy.normalize(policy)

  # Packages.

  @impl true
  def list_packages(actor) do
    AddonPackage
    |> Ash.Query.for_read(:read)
    |> Ash.read(actor: actor)
  end

  @impl true
  def get_package(id, actor), do: get_by_id(AddonPackage, id, actor)

  @impl true
  def packages_by_id(ids, actor) do
    AddonPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read(actor: actor)
  end

  @impl true
  def artifact_id(%AddonPackage{addon_id: addon_id}), do: addon_id

  @impl true
  def package_attrs(previous, candidate),
    do: %{previous_package_id: previous.id, candidate_package_id: candidate.id}

  @impl true
  def previous_package_id(rollout_or_target), do: rollout_or_target.previous_package_id

  @impl true
  def candidate_package_id(rollout_or_target), do: rollout_or_target.candidate_package_id

  # Candidate eligibility.

  @impl true
  def same_lineage?(candidate, current),
    do: same_addon?(candidate, current) and same_source_origin?(candidate, current)

  @impl true
  @spec trusted_approved?(AddonPackage.t()) :: boolean()
  def trusted_approved?(%AddonPackage{} = package) do
    package.status == :approved and package.verification_status == "verified" and
      is_nil(package.verification_error) and
      is_binary(package.source_oci_digest) and package.source_oci_digest != ""
  end

  @impl true
  @spec within_capability_ceiling?(AddonPackage.t(), map()) :: boolean()
  def within_capability_ceiling?(%AddonPackage{} = package, source) do
    ceiling = source |> value(:capability_ceiling, []) |> normalize_strings() |> MapSet.new()
    requested = package.approved_capabilities |> normalize_strings() |> MapSet.new()
    MapSet.subset?(requested, ceiling)
  end

  @impl true
  def incompatibility(%AddonPackage{} = package, agent) do
    cond do
      not platform_allowed?(package, agent) -> "unsupported_platform"
      not artifact_available?(package, agent) -> "missing_platform_artifact"
      not agent_version_allowed?(package, agent) -> "incompatible_base_agent_version"
      missing_required_capabilities(package, agent) != [] -> "missing_required_agent_capability"
      not hostable_addon?(package.supervision, agent) -> "agent_cannot_host_native_addons"
      true -> nil
    end
  end

  # Target materialization.

  @impl true
  def source_members(%AddonAssignment{} = assignment, _actor), do: {:ok, [assignment]}

  def source_members(%AddonProfile{} = profile, actor) do
    AddonAssignment
    |> Ash.Query.for_read(:by_profile, %{addon_profile_id: profile.id}, actor: actor)
    |> Ash.Query.filter(enabled == true)
    |> Ash.read(actor: actor)
  end

  # A manual assignment for the same agent and add-on outranks the profile, so
  # the profile's member for that agent is not the profile's to move.
  @impl true
  def overridden_members(%AddonAssignment{}, _members, _actor), do: {:ok, MapSet.new()}
  def overridden_members(%AddonProfile{}, [], _actor), do: {:ok, MapSet.new()}

  def overridden_members(%AddonProfile{}, members, actor) do
    agent_uids = Enum.map(members, & &1.agent_uid)
    addon_id = members |> List.first() |> Map.get(:addon_id)

    AddonAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      source == :manual and enabled == true and addon_id == ^addon_id and agent_uid in ^agent_uids
    )
    |> Ash.read(actor: actor)
    |> case do
      {:ok, rows} ->
        direct_keys = MapSet.new(rows, &{&1.agent_uid, &1.addon_id})

        {:ok,
         members
         |> Enum.filter(&MapSet.member?(direct_keys, {&1.agent_uid, &1.addon_id}))
         |> MapSet.new(& &1.id)}

      error ->
        error
    end
  end

  @impl true
  def target_attrs(%AddonAssignment{} = assignment, previous) do
    %{
      assignment_id: assignment.id,
      agent_uid: assignment.agent_uid,
      addon_id: assignment.addon_id,
      previous_package_id: assignment.addon_package_id || previous.id,
      previous_params: assignment.params || %{},
      previous_args: assignment.args || []
    }
  end

  @impl true
  def member_id(%AddonRolloutTarget{assignment_id: assignment_id}), do: assignment_id

  # Overrides and promotion.

  @impl true
  def apply_override(target, rollout, now, actor) do
    with {:ok, assignment} <- get_assignment(target.assignment_id, actor),
         {:ok, _} <-
           update_assignment(
             assignment,
             :apply_rollout_override,
             %{
               rollout_package_id: target.candidate_package_id,
               rollout_id: rollout.id,
               rollout_started_at: now
             },
             actor
           ) do
      :ok
    end
  end

  @impl true
  def clear_override(%AddonRolloutTarget{assignment_id: nil}, _actor), do: :ok

  def clear_override(target, actor) do
    with {:ok, assignment} <- get_assignment(target.assignment_id, actor) do
      if assignment.rollout_id == target.rollout_id do
        assignment
        |> update_assignment(
          :clear_rollout_override,
          %{rollout_package_id: nil, rollout_id: nil, rollout_started_at: nil},
          actor
        )
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      else
        :ok
      end
    end
  end

  @impl true
  def tolerates_failures?(%AddonRollout{source_type: :profile}), do: true
  def tolerates_failures?(_rollout), do: false

  # A failed add-on target pauses the rollout; a profile may then absorb it as a
  # tolerated failure, which a whole-rollout rollback would take away.
  @impl true
  def rolls_back_on_failure?(_rollout), do: false

  @impl true
  def pin_failed_member(target, actor) do
    with {:ok, assignment} <- get_assignment(target.assignment_id, actor),
         {:ok, _} <-
           update_assignment(
             assignment,
             :update,
             %{
               source: :manual,
               source_key: nil,
               addon_profile_id: nil,
               update_policy: :manual_pin,
               explicit_version_pin: true
             },
             actor
           ) do
      :ok
    end
  end

  @impl true
  def promote_source(%AddonRollout{source_type: :assignment} = rollout, actor) do
    with {:ok, assignment} <- get_assignment(rollout.source_id, actor),
         {:ok, _} <-
           update_assignment(
             assignment,
             :promote_rollout,
             %{
               addon_package_id: rollout.candidate_package_id,
               rollout_package_id: nil,
               rollout_id: nil,
               rollout_started_at: nil
             },
             actor
           ) do
      :ok
    end
  end

  def promote_source(%AddonRollout{source_type: :profile} = rollout, actor) do
    with {:ok, profile} <- get_profile(rollout.source_id, actor),
         {:ok, _} <-
           profile
           |> Ash.Changeset.for_update(:promote_rollout, %{
             addon_package_id: rollout.candidate_package_id
           })
           |> Ash.update(actor: actor, authorize?: true),
         {:ok, _summary} <- AddonProfileOps.reconcile_by_id(profile.id, actor: actor) do
      :ok
    end
  end

  # Health evidence.

  @impl true
  def load_evidence([], _rollout, _actor), do: %{}

  def load_evidence(targets, rollout, actor) do
    addon_id = rollout.addon_id
    uids = targets |> Enum.map(& &1.agent_uid) |> Enum.uniq()

    AddonStatus
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(addon_id == ^addon_id and agent_uid in ^uids)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, statuses} -> Map.new(statuses, &{&1.agent_uid, &1})
      {:error, _} -> %{}
    end
  end

  @impl true
  def evidence_key(%AddonRolloutTarget{agent_uid: agent_uid}), do: agent_uid

  @impl true
  def observed_at(%AddonStatus{reported_at: reported_at}), do: reported_at

  # Add-on readiness is always status for the candidate version, so a ready
  # target keeps the reason code it has.
  @impl true
  def ready_reason(_status, _candidate, _applied_at), do: nil

  # Readiness deliberately uses supervision_state_ready?/2, not supervision_ready?/2:
  # an advisory degradation must not keep a candidate that has come up from ever
  # being considered ready. Otherwise the target sits un-ready until its deadline
  # and fails as `candidate_health_timeout`, which is how a host-level cgroup
  # misconfiguration held anomaly three versions behind for a week.
  @impl true
  def candidate_ready?(status, candidate, applied_at) do
    fresh_status?(status, applied_at) and status.version == candidate.version and
      supervision_state_ready?(candidate, status)
  end

  # A candidate fails on its reported STATE. It does not fail merely because the
  # add-on also reported a degradation reason: that reason is advisory, describes
  # the deployment around the add-on as often as the add-on itself, and is
  # identical before and after an upgrade -- so gating on it could only ever wedge
  # the rollout, never protect it. The reason is still recorded and surfaced; see
  # advisory_degradation/1 and the fleet row.
  #
  # And it fails only on a report ABOUT the candidate. The agent reports the add-on
  # it is running; until it has applied the override that is still the previous
  # version, so a fresh "unhealthy" from it says nothing about the candidate. On demo
  # a wedged 0.3.10 failed the 0.3.11 target for its host 31 s after the override,
  # before the agent had even polled for the new assignment. An agent that never
  # applies the candidate still fails, as candidate_health_timeout.
  @impl true
  def candidate_failed?(nil, _candidate, _applied_at), do: false

  def candidate_failed?(status, candidate, applied_at) do
    state = status.state |> to_string() |> String.downcase()

    fresh_status?(status, applied_at) and status.version == candidate.version and
      state in ["circuit_open", "failed", "unhealthy", "verification_failed"]
  end

  @impl true
  def recovered?(status, previous, since) do
    fresh_status?(status, since) and status.version == previous.version and
      supervision_ready?(previous, status)
  end

  @impl true
  def converged?(nil, _candidate), do: false

  def converged?(status, candidate),
    do: Eligibility.version_at_least?(status.version, candidate.version)

  # Audit and telemetry.

  @impl true
  def audit_resource_type, do: "native_addon_rollout"

  @impl true
  def telemetry_event, do: [:serviceradar, :plugins, :addon_rollout, :transition]

  # Supervision-model predicates, shared with the fleet view and the profile
  # reconciler.

  @spec supervision_ready?(AddonPackage.t(), map()) :: boolean()
  def supervision_ready?(%AddonPackage{} = package, status) do
    supervision_state_ready?(package, status) and not degraded?(status)
  end

  @doc """
  Whether the reported lifecycle state satisfies the package's supervision model,
  ignoring any advisory degradation the add-on also reported.

  Split out from `supervision_ready?/2` because the two questions have different
  answers and different audiences. Rollout gating asks only whether the candidate
  came up under its supervision model -- a running add-on that also reports, say,
  an unenforceable host cgroup policy has still come up, and treating that note as
  "not ready" let a host misconfiguration hold a rollout open until it timed out.
  Convergence display still wants the stricter question, so `supervision_ready?/2`
  keeps its meaning and is defined in terms of this.
  """
  @spec supervision_state_ready?(AddonPackage.t(), map()) :: boolean()
  def supervision_state_ready?(%AddonPackage{supervision: supervision}, status) do
    state = status |> value(:state, "") |> to_string() |> String.downcase()
    active? = value(status, :active, false) == true

    case supervision do
      # "degraded" is a RUNNING add-on that reported something worth attention.
      # The agent reports it distinctly from "unhealthy" precisely so this
      # question -- did the candidate come up? -- can answer yes. The reason is
      # still carried on the status and still shown on the fleet row; only the
      # rollout gate stops treating it as a failed candidate.
      model when model in [:agent_sidecar, :systemd_service] ->
        active? and state in ["active", "degraded", "healthy", "running"]

      :systemd_timer ->
        state in ["active", "degraded", "enabled", "healthy", "ready", "running", "waiting"]

      :ephemeral_helper ->
        state in ["healthy", "ready", "registered", "staged", "verified"]

      :config_toggle ->
        state in ["active", "applied", "healthy", "ready", "running"]

      _ ->
        false
    end
  end

  @doc "Whether the add-on reported an advisory degradation alongside its state."
  @spec degraded?(map()) :: boolean()
  def degraded?(status), do: present?(value(status, :degradation_reason))

  @doc """
  Whether `agent` can host an add-on with this supervision model.

  `addon.native.host.unavailable` means the agent cannot install SYSTEMD-supervised
  add-ons: writing unit files into the host's system unit dir and enabling them goes
  through the root-owned agent-updater, which a containerized agent does not have.
  It does not mean the agent refuses every add-on. An agent-sidecar add-on is just a
  subprocess of the agent, and containerized agents (LXC, Docker) run them; the
  agent applies sidecar, helper and config-toggle assignments wherever it runs.

  The one agent that refuses the whole assignment set is the in-cluster Kubernetes
  agent, so a Kubernetes deployment that reports the capability is excluded from
  every supervision model.

  An agent that reports `addon.native.host` is believed outright. One that reports
  neither predates the capability, and then only the airtight claim is made: a
  container cannot host a `systemd_service` or `systemd_timer`.

  The control plane must agree with the agent or the rollout never ends. A rollout's
  default policy is `tolerated_failures: 0`, so one target that can never report
  add-on health ages out at `candidate_health_timeout` and fails the rollout for the
  ENTIRE fleet -- the source's package is then never advanced, which is what makes
  `track_latest_approved` look dead while every bare-metal host was in fact ready.
  Excluding a container that CAN run a sidecar is the opposite failure: profiles and
  rollouts skip the host, so the add-on never reaches it.

  Public because `AddonProfileReconciler` gates assignment materialization on the
  same question and must not answer it differently -- an agent kept out of rollouts
  but still handed the assignment just fails in a different place.
  """
  @spec hostable_addon?(atom() | String.t() | nil, map()) :: boolean()
  def hostable_addon?(supervision, agent) do
    capabilities = agent |> value(:capabilities, []) |> normalize_strings() |> MapSet.new()

    cond do
      MapSet.member?(capabilities, @native_addon_host_capability) ->
        true

      MapSet.member?(capabilities, @native_addon_host_unavailable_capability) ->
        not systemd_supervised?(supervision) and deployment_type(agent) != "kubernetes"

      systemd_supervised?(supervision) ->
        not containerized?(agent)

      true ->
        true
    end
  end

  defp managed_assignments(actor) do
    AddonAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      enabled == true and source != :profile and update_policy == :track_latest_approved and
        explicit_version_pin == false
    )
    |> Ash.read(actor: actor)
  end

  defp managed_profiles(actor) do
    AddonProfile
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      enabled == true and update_policy == :track_latest_approved and
        explicit_version_pin == false
    )
    |> Ash.read(actor: actor)
  end

  defp recoverable_assignments(actor) do
    AddonAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      enabled == true and source != :profile and update_policy == :manual_pin and
        explicit_version_pin == false
    )
    |> Ash.read(actor: actor)
  end

  defp recoverable_profiles(actor) do
    AddonProfile
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      enabled == true and update_policy == :manual_pin and explicit_version_pin == false
    )
    |> Ash.read(actor: actor)
  end

  defp restore_non_explicit_source(source, packages, actor) do
    current = Enum.find(packages, &(to_string(&1.id) == to_string(source.addon_package_id)))

    if recoverable_first_party_package?(current) do
      ceiling = recovery_capability_ceiling(current, packages)
      source_with_ceiling = Map.put(source, :capability_ceiling, ceiling)

      case Eligibility.latest_candidate(current, packages, source_with_ceiling) do
        {:ok, candidate} ->
          source
          |> Ash.Changeset.for_update(:restore_managed_update_policy, %{
            update_policy: :track_latest_approved,
            capability_ceiling: candidate.approved_capabilities || []
          })
          |> Ash.update(actor: actor, authorize?: true)

        _ ->
          :unchanged
      end
    else
      :unchanged
    end
  end

  defp recoverable_first_party_package?(%AddonPackage{} = package) do
    package.source_type == :first_party and package.verification_status == "verified" and
      is_nil(package.verification_error)
  end

  defp recoverable_first_party_package?(_package), do: false

  defp recovery_capability_ceiling(current, packages) do
    packages
    |> Enum.filter(&trusted_approved?/1)
    |> Enum.filter(&(&1.addon_id == current.addon_id))
    |> Enum.flat_map(&(&1.approved_capabilities || []))
    |> Enum.uniq()
  end

  defp same_addon?(%AddonPackage{addon_id: addon_id}, %AddonPackage{addon_id: addon_id}), do: true

  defp same_addon?(_candidate, _current), do: false

  defp same_source_origin?(candidate, current) do
    candidate.source_type == current.source_type and
      oci_repository(candidate.source_oci_ref) == oci_repository(current.source_oci_ref)
  end

  defp oci_repository(value) when is_binary(value) do
    value
    |> String.split("@", parts: 2)
    |> List.first()
    |> String.replace(~r/:[^\/:]+$/, "")
  end

  defp oci_repository(_value), do: nil

  defp platform_allowed?(package, agent) do
    supported = package.requires |> value(:platforms, []) |> normalize_strings()
    os = agent_component(agent, :os)
    supported == [] or (is_binary(os) and os in supported)
  end

  defp artifact_available?(%AddonPackage{delivery: delivery}, _agent)
       when delivery != :pushed_artifact, do: true

  defp artifact_available?(package, agent) do
    os = agent_component(agent, :os)
    arch = agent_component(agent, :arch)

    if is_binary(os) and is_binary(arch) do
      case Map.get(package.artifacts || %{}, "#{os}/#{arch}") do
        artifact when is_map(artifact) ->
          present?(value(artifact, :object_key)) and present?(value(artifact, :sha256))

        _ ->
          false
      end
    else
      false
    end
  end

  defp agent_version_allowed?(package, agent) do
    case value(package.requires || %{}, :base_agent) do
      nil -> true
      "" -> true
      requirement -> version_matches?(value(agent, :version), requirement)
    end
  end

  defp systemd_supervised?(supervision) do
    supervision in [:systemd_service, :systemd_timer, "systemd_service", "systemd_timer"]
  end

  # Only a deployment type the agent actually reported as containerized blocks.
  # Agents older than deployment-type reporting send nothing here, and failing
  # closed on that would strand every bare-metal host in an existing fleet.
  defp containerized?(agent), do: deployment_type(agent) in @containerized_deployment_types

  defp deployment_type(agent) do
    metadata = value(agent, :metadata, %{}) || %{}
    labels = value(metadata, :labels, %{}) || %{}

    case value(agent, :deployment_type) || value(metadata, :deployment_type) ||
           value(labels, :deployment_type) do
      type when is_binary(type) -> type |> String.trim() |> String.downcase()
      _ -> nil
    end
  end

  defp missing_required_capabilities(package, agent) do
    actual = agent |> value(:capabilities, []) |> normalize_strings() |> MapSet.new()

    package.requires
    |> value(:agent_capabilities, [])
    |> normalize_strings()
    |> Enum.reject(&MapSet.member?(actual, &1))
  end

  defp agent_component(agent, component) do
    metadata = value(agent, :metadata, %{}) || %{}

    normalize_component(
      value(agent, component) || value(metadata, component) ||
        value(metadata, String.to_atom("platform_#{component}"))
    )
  end

  defp normalize_component(nil), do: nil

  defp normalize_component(value) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp version_matches?(version, requirement)
       when is_binary(version) and is_binary(requirement) do
    with {:ok, parsed_version} <- Eligibility.parse_version(version),
         {:ok, parsed_requirement} <- Version.parse_requirement(requirement) do
      Version.match?(parsed_version, parsed_requirement)
    else
      _ -> false
    end
  end

  defp version_matches?(_, _), do: false

  defp fresh_status?(%AddonStatus{reported_at: %DateTime{} = reported_at}, %DateTime{} = since),
    do: DateTime.compare(reported_at, since) in [:gt, :eq]

  defp fresh_status?(_, _), do: false

  defp get_assignment(id, actor), do: get_by_id(AddonAssignment, id, actor)
  defp get_profile(id, actor), do: get_by_id(AddonProfile, id, actor)

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

  defp update_assignment(assignment, action, attrs, actor) do
    assignment
    |> Ash.Changeset.for_update(action, attrs)
    |> Ash.update(actor: actor, authorize?: true)
  end

  defp normalize_strings(values),
    do: values |> List.wrap() |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.uniq()

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp value(_, _, default), do: default

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
