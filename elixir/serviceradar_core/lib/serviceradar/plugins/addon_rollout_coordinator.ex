defmodule ServiceRadar.Plugins.AddonRolloutCoordinator do
  @moduledoc """
  Creates and advances durable, health-gated native add-on fleet rollouts.

  The stable package on an assignment or profile is never changed during a
  canary. A per-assignment override is delivered to the agent, and only fresh
  status for the candidate version can pass the gate. A failed target has its
  override removed before the rollout is stopped.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonProfile
  alias ServiceRadar.Plugins.AddonProfileOps
  alias ServiceRadar.Plugins.AddonRollout
  alias ServiceRadar.Plugins.AddonRolloutEligibility, as: Eligibility
  alias ServiceRadar.Plugins.AddonRolloutPolicy
  alias ServiceRadar.Plugins.AddonRolloutTarget
  alias ServiceRadar.Plugins.AddonStatus
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @active_rollout_states [:pending, :running, :paused, :rolling_back]
  @active_target_states [:waiting_health, :healthy_soak, :rollback_pending]
  @failed_rollout_states [:failed, :rolled_back]

  @type source :: AddonAssignment.t() | AddonProfile.t()

  @spec reconcile(keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile(opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:addon_rollout_coordinator))
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, packages} <- read_all(AddonPackage, actor),
         {:ok, recovered_sources} <- restore_non_explicit_managed_sources(packages, actor),
         {:ok, assignments} <- managed_assignments(actor),
         {:ok, profiles} <- managed_profiles(actor),
         {:ok, rollouts} <- read_all(AddonRollout, actor) do
      package_by_id = Map.new(packages, &{to_string(&1.id), &1})

      created =
        assignments
        |> Enum.concat(profiles)
        |> Enum.reduce(%{started: 0, blocked: 0, skipped: 0}, fn source, stats ->
          reconcile_source(source, packages, package_by_id, rollouts, actor, now, stats)
        end)

      advanced = advance_active_rollouts(actor: actor, now: now)

      {:ok,
       created
       |> Map.put(:advanced, advanced)
       |> Map.put(:recovered_sources, recovered_sources)}
    end
  end

  @spec start(source(), AddonPackage.t(), keyword()) ::
          {:ok, AddonRollout.t()} | {:error, term()}
  def start(source, %AddonPackage{} = candidate, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:addon_rollout_start))
    now = Keyword.get(opts, :now, DateTime.utc_now())
    trigger = Keyword.get(opts, :trigger, :manual)

    with {:ok, previous} <- source_package(source, actor),
         :ok <- validate_candidate(source, previous, candidate),
         {:ok, targets} <- source_targets(source, actor),
         {:ok, agents} <- load_agents(targets, actor),
         {:ok, direct_overrides} <- direct_override_keys(source, targets, actor),
         {:ok, rollout} <-
           create_rollout_with_targets(
             source,
             previous,
             candidate,
             targets,
             agents,
             direct_overrides,
             actor,
             now,
             trigger
           ) do
      _ = advance(rollout.id, actor: actor, now: now)
      {:ok, rollout}
    end
  end

  @doc """
  Starts a fresh, manually authorized attempt for a terminal failed candidate.

  The original rollout remains immutable evidence. The new attempt still passes
  the normal provenance, compatibility, and capability-ceiling validation, so a
  retry cannot turn a privilege-expanding candidate into an implicit approval.
  """
  @spec retry(Ecto.UUID.t(), keyword()) :: {:ok, AddonRollout.t()} | {:error, term()}
  def retry(rollout_id, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:addon_rollout_retry))
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, rollout} <- get_rollout(rollout_id, actor),
         true <- rollout.state in @failed_rollout_states,
         :ok <- vacate_target_slots(rollout, actor),
         {:ok, source} <- source_for_rollout(rollout, actor),
         {:ok, candidate} <- get_package(rollout.candidate_package_id, actor),
         {:ok, retried} <- start(source, candidate, actor: actor, now: now, trigger: :retry) do
      audit(:retry, retried, %{retried_rollout_id: rollout.id})
      emit(:retried, retried, %{retried_rollout_id: rollout.id})
      {:ok, retried}
    else
      false -> {:error, :rollout_not_retryable}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec advance(Ecto.UUID.t(), keyword()) :: :ok | {:error, term()}
  def advance(rollout_id, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:addon_rollout_advance))
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, rollout} <- get_rollout(rollout_id, actor),
         true <- rollout.state in @active_rollout_states,
         {:ok, targets} <- rollout_targets(rollout.id, actor),
         {:ok, packages} <- packages_for_rollout(rollout, targets, actor),
         :continue <- supersede_if_converged(rollout, targets, packages, actor, now),
         {:ok, targets} <- evaluate_targets(rollout, targets, packages, actor, now) do
      finish_or_advance(rollout, targets, actor, now)
    else
      false -> :ok
      :superseded -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Runs before anything else in advance/2, and deliberately before
  # finish_or_advance/4's `rollout.state == :paused -> :ok` short-circuit: a
  # paused rollout is exactly the one that needs reaping, and that clause is why
  # four of them sat on the demo fleet for 19 days offering Resume / Roll back /
  # Cancel for work the fleet had already done.
  #
  # The decision reads OBSERVED fleet state rather than this rollout's own batch
  # progress, so convergence by any other route counts -- a later rollout, a
  # direct assignment, an operator reinstalling on the host.
  defp supersede_if_converged(rollout, targets, packages, actor, now) do
    candidate = Map.get(packages, to_string(rollout.candidate_package_id))
    # :rolled_back is terminal and belongs with :excluded/:canceled here. A target
    # whose agent never reports -- a decommissioned host still enrolled in
    # ocsf_agents, which is never deleted regardless of age -- fails its health
    # deadline, lands :rolled_back, and pauses the rollout. Keeping it in scope
    # then made convergence unprovable forever, because the reap asks every
    # in-scope target for a status >= the candidate and a dead agent has none.
    # The rollout could neither promote (finish_or_advance short-circuits on
    # :paused) nor fail forward, and reconcile_source skips any source with an
    # active rollout -- so ONE dead agent silently froze managed updates for its
    # whole fleet. Observed on demo: seven sources stuck 17-19 days behind.
    # If every target rolled back, in_scope is empty and the guard below keeps
    # the rollout paused, which is the real failure this must not mask.
    in_scope = Enum.reject(targets, &(&1.state in [:excluded, :canceled, :rolled_back]))

    cond do
      # Only a paused rollout is reaped. A rollout that can still make progress
      # must be allowed to: an in-flight rollout whose targets report the
      # candidate has just SUCCEEDED, and belongs in promote_source/4 as
      # :completed, not here as :superseded. Reaping on observed version alone
      # cannot tell those apart -- it hijacked three existing rollout tests
      # before this guard, turning healthy promotions into supersessions.
      rollout.state != :paused ->
        :continue

      is_nil(candidate) or in_scope == [] ->
        :continue

      converged_on_candidate?(in_scope, rollout.addon_id, candidate, actor) ->
        mark_superseded(rollout, candidate, length(in_scope), actor, now)

      true ->
        :continue
    end
  end

  defp converged_on_candidate?(targets, addon_id, candidate, actor) do
    statuses = load_statuses(targets, addon_id, actor)

    Enum.all?(targets, fn target ->
      case Map.get(statuses, target.agent_uid) do
        nil ->
          false

        status ->
          Eligibility.version_at_least?(status.version, candidate.version)
      end
    end)
  end

  defp mark_superseded(rollout, candidate, target_count, actor, now) do
    details = %{candidate_version: candidate.version, target_count: target_count}

    case update_rollout(
           rollout,
           %{
             state: :superseded,
             completed_at: now,
             paused_at: nil,
             blocked_reason: "fleet_already_on_candidate"
           },
           actor
         ) do
      {:ok, updated} ->
        audit(:supersede, updated, details)
        emit(:superseded, updated, details)
        :superseded

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec pause(Ecto.UUID.t(), keyword()) :: :ok | {:error, term()}
  def pause(rollout_id, opts \\ []) do
    transition_rollout(rollout_id, :paused, :paused_at, opts)
  end

  @spec resume(Ecto.UUID.t(), keyword()) :: :ok | {:error, term()}
  def resume(rollout_id, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:addon_rollout_resume))
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, rollout} <- get_rollout(rollout_id, actor),
         true <- rollout.state == :paused,
         {:ok, _} <- update_rollout(rollout, %{state: :running, paused_at: nil}, actor) do
      audit(:resume, rollout, %{})
      advance(rollout.id, actor: actor, now: now)
    else
      false -> {:error, :rollout_not_paused}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec cancel(Ecto.UUID.t(), keyword()) :: :ok | {:error, term()}
  def cancel(rollout_id, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:addon_rollout_cancel))
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, rollout} <- get_rollout(rollout_id, actor),
         true <- rollout.state in @active_rollout_states,
         {:ok, targets} <- rollout_targets(rollout.id, actor),
         :ok <- clear_all_overrides(targets, actor),
         :ok <- mark_targets_canceled(targets, actor, now),
         {:ok, _} <-
           update_rollout(
             rollout,
             %{state: :canceled, canceled_at: now, blocked_reason: "operator_canceled"},
             actor
           ) do
      audit(:cancel, rollout, %{target_count: length(targets)})
      emit(:canceled, rollout, %{target_count: length(targets)})
      :ok
    else
      false -> {:error, :rollout_not_active}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec rollback(Ecto.UUID.t(), keyword()) :: :ok | {:error, term()}
  def rollback(rollout_id, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:addon_rollout_rollback))
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, rollout} <- get_rollout(rollout_id, actor),
         true <- rollout.state in @active_rollout_states,
         {:ok, targets} <- rollout_targets(rollout.id, actor),
         {:ok, _} <- update_rollout(rollout, %{state: :rolling_back}, actor),
         :ok <-
           begin_whole_rollback(
             targets,
             actor,
             now,
             rollout.policy["health_timeout_seconds"] || 900
           ) do
      audit(:rollback, rollout, %{target_count: length(targets)})
      emit(:rolling_back, rollout, %{target_count: length(targets)})
      advance(rollout.id, actor: actor, now: now)
    else
      false -> {:error, :rollout_not_active}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_source(source, packages, package_by_id, rollouts, actor, now, stats) do
    current = Map.get(package_by_id, to_string(source.addon_package_id))
    source_rollouts = Enum.filter(rollouts, &same_source?(&1, source))

    if is_nil(current) or Enum.any?(source_rollouts, &(&1.state in @active_rollout_states)) do
      increment(stats, :skipped)
    else
      blocked_ids =
        source_rollouts
        |> Enum.filter(&(&1.state in @failed_rollout_states))
        |> Enum.map(& &1.candidate_package_id)

      case Eligibility.latest_candidate(current, packages, source,
             blocked_candidate_ids: blocked_ids
           ) do
        {:ok, candidate} ->
          case start(source, candidate, actor: actor, now: now, trigger: :track_latest) do
            {:ok, _} ->
              increment(stats, :started)

            {:error, :no_eligible_targets} ->
              # Not a failure: no agent for this source can take the candidate
              # right now. Reconcile runs every 30s, so warning here would spam
              # the log for as long as the fleet is offline.
              increment(stats, :skipped)

            {:error, reason} ->
              Logger.warning("Failed to start native add-on rollout",
                source_id: to_string(source.id),
                reason: inspect(reason)
              )

              increment(stats, :skipped)
          end

        {:blocked, reason, candidate} ->
          case record_blocked_candidate(source, current, candidate, reason, actor, now) do
            {:ok, _} -> increment(stats, :blocked)
            {:error, _} -> increment(stats, :skipped)
          end

        :none ->
          increment(stats, :skipped)
      end
    end
  end

  defp validate_candidate(source, previous, candidate) do
    case Eligibility.latest_candidate(previous, [candidate], source) do
      {:ok, ^candidate} -> :ok
      {:blocked, reason, _} -> {:error, reason}
      :none -> {:error, :candidate_not_eligible}
    end
  end

  defp create_rollout_with_targets(
         source,
         previous,
         candidate,
         assignments,
         agents,
         direct_overrides,
         actor,
         now,
         trigger
       ) do
    policy = AddonRolloutPolicy.normalize(source.rollout_policy)

    target_specs =
      target_specs(source, candidate, assignments, agents, direct_overrides, policy, now)

    # A source whose targets all exist but none of which can take the candidate
    # has nothing to prove: every target would be terminal the moment it is
    # created, finish_or_advance/4 would promote on the spot, and the source would
    # advance to a candidate version no agent has actually run. Refuse that; the
    # next reconcile retries once an agent reports in.
    #
    # A source with NO targets at all is deliberately exempt. A profile that
    # currently matches nothing has nothing to verify, and letting its pin track
    # the latest approved package means it is already correct the moment an agent
    # appears. That behaviour predates this guard and is covered by the "reconcile
    # repairs a non-explicit first-party profile stranded on a staged package"
    # test, which starts a rollout for a profile with zero targets.
    if target_specs == [] or Enum.any?(target_specs, &(&1.classification == :eligible)) do
      create_rollout_with_specs(
        source,
        previous,
        candidate,
        policy,
        target_specs,
        actor,
        now,
        trigger
      )
    else
      {:error, :no_eligible_targets}
    end
  end

  defp create_rollout_with_specs(
         source,
         previous,
         candidate,
         policy,
         target_specs,
         actor,
         now,
         trigger
       ) do
    rollout_attrs = %{
      addon_id: previous.addon_id,
      source_type: source_type(source),
      source_id: source.id,
      previous_package_id: previous.id,
      candidate_package_id: candidate.id,
      trigger: trigger,
      state: :running,
      policy: policy,
      target_snapshot: target_snapshot(target_specs),
      started_at: now
    }

    transaction_result =
      Repo.transaction(fn ->
        with {:ok, rollout, rollout_notifications} <-
               create_rollout_with_notifications(rollout_attrs, actor),
             {:ok, target_notifications} <-
               create_targets(rollout, target_specs, previous, candidate, actor) do
          {rollout, rollout_notifications ++ target_notifications}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case unwrap_transaction(transaction_result) do
      {:ok, {rollout, notifications}} ->
        _ = Ash.Notifier.notify(notifications)
        audit(:start, rollout, rollout.target_snapshot)
        emit(:started, rollout, rollout.target_snapshot)
        {:ok, rollout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp target_specs(_source, candidate, assignments, agents, direct_overrides, policy, now) do
    classified =
      assignments
      |> Enum.sort_by(& &1.agent_uid)
      |> Enum.map(fn assignment ->
        override_key = {assignment.agent_uid, assignment.addon_id}

        {classification, reason} =
          if MapSet.member?(direct_overrides, override_key) do
            {:overridden, "direct_assignment_precedence"}
          else
            Eligibility.classify_target(candidate, Map.get(agents, assignment.agent_uid), now)
          end

        %{assignment: assignment, classification: classification, reason_code: reason}
      end)

    # Only :eligible targets are batched. An agent that is not reporting must not
    # consume a canary slot -- it cannot demonstrate the candidate is healthy, so
    # spending the canary on it means the batch behind it waits on a host that
    # will never answer.
    advanceable = Enum.filter(classified, &(&1.classification == :eligible))
    batch_by_assignment = batch_indexes(advanceable, policy)

    Enum.map(classified, fn spec ->
      Map.put(spec, :batch_index, Map.get(batch_by_assignment, spec.assignment.id, 0))
    end)
  end

  defp batch_indexes(specs, policy) do
    canary_size = min(policy["canary_size"], length(specs))
    batch_size = policy["batch_size"]

    specs
    |> Enum.with_index()
    |> Map.new(fn {spec, index} ->
      batch = if index < canary_size, do: 0, else: 1 + div(index - canary_size, batch_size)
      {spec.assignment.id, batch}
    end)
  end

  defp create_targets(rollout, specs, previous, candidate, actor) do
    Enum.reduce_while(specs, {:ok, []}, fn spec, {:ok, notifications} ->
      assignment = spec.assignment
      # :unavailable belongs with :incompatible, not with :eligible. An agent that
      # is not reporting cannot run the candidate now, and making it a :pending
      # target means the rollout waits out its health deadline and then pauses --
      # which is how one retired agent identity froze managed updates for a whole
      # fleet for 19 days. Exclude it with its reason recorded, and let the next
      # rollout pick the agent up once it reports in. Operators should never have
      # to hand-write target queries to route around an agent the system can
      # already see is not there.
      state = if spec.classification == :eligible, do: :pending, else: :excluded

      attrs = %{
        rollout_id: rollout.id,
        assignment_id: assignment.id,
        agent_uid: assignment.agent_uid,
        addon_id: assignment.addon_id,
        source_type: rollout.source_type,
        source_id: rollout.source_id,
        previous_package_id: assignment.addon_package_id || previous.id,
        candidate_package_id: candidate.id,
        previous_params: assignment.params || %{},
        previous_args: assignment.args || [],
        batch_index: spec.batch_index,
        classification: spec.classification,
        state: state,
        reason_code: spec.reason_code
      }

      case create_target_with_notifications(attrs, actor) do
        {:ok, _target, target_notifications} ->
          {:cont, {:ok, notifications ++ target_notifications}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp evaluate_targets(rollout, targets, packages, actor, now) do
    evaluating = Enum.filter(targets, &(&1.state in @active_target_states))
    statuses = load_statuses(evaluating, rollout.addon_id, actor)

    targets
    |> Enum.reduce_while({:ok, []}, fn target, {:ok, acc} ->
      result =
        case target.state do
          state when state in [:waiting_health, :healthy_soak] ->
            evaluate_candidate_target(
              rollout,
              target,
              Map.get(statuses, target.agent_uid),
              Map.fetch!(packages, to_string(target.candidate_package_id)),
              actor,
              now
            )

          :rollback_pending ->
            evaluate_rollback_target(
              target,
              Map.get(statuses, target.agent_uid),
              Map.fetch!(packages, to_string(target.previous_package_id)),
              actor,
              now
            )

          _ ->
            {:ok, target}
        end

      case result do
        {:ok, updated} -> {:cont, {:ok, [updated | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, evaluated} -> {:ok, Enum.reverse(evaluated)}
      error -> error
    end
  end

  defp evaluate_candidate_target(rollout, target, status, candidate, actor, now) do
    cond do
      explicit_failure?(status, target.override_applied_at) ->
        fail_and_rollback_target(rollout, target, "candidate_reported_unhealthy", actor, now)

      candidate_ready?(status, candidate, target.override_applied_at) ->
        evaluate_soak(target, status, rollout.policy, actor, now)

      deadline_elapsed?(target.deadline_at, now) ->
        fail_and_rollback_target(rollout, target, "candidate_health_timeout", actor, now)

      true ->
        {:ok, target}
    end
  end

  defp evaluate_soak(target, status, policy, actor, now) do
    soak_seconds = policy["soak_seconds"] || 300
    observed_at = status.reported_at

    cond do
      is_nil(target.healthy_since) and soak_seconds == 0 ->
        update_target(
          target,
          %{
            state: :succeeded,
            healthy_since: now,
            completed_at: now,
            health_observed_at: observed_at
          },
          actor
        )

      is_nil(target.healthy_since) ->
        update_target(
          target,
          %{state: :healthy_soak, healthy_since: now, health_observed_at: observed_at},
          actor
        )

      DateTime.diff(now, target.healthy_since, :second) >= soak_seconds ->
        update_target(
          target,
          %{state: :succeeded, completed_at: now, health_observed_at: observed_at},
          actor
        )

      true ->
        update_target(target, %{health_observed_at: observed_at}, actor)
    end
  end

  defp fail_and_rollback_target(rollout, target, reason, actor, now) do
    with :ok <- clear_assignment_override(target, actor),
         {:ok, target} <-
           update_target(
             target,
             %{
               state: :rollback_pending,
               reason_code: reason,
               rollback_started_at: now,
               deadline_at: DateTime.add(now, rollout.policy["health_timeout_seconds"] || 900)
             },
             actor
           ),
         {:ok, _} <-
           update_rollout(
             rollout,
             %{state: :paused, paused_at: now, blocked_reason: reason},
             actor
           ) do
      emit(:target_failed, rollout, %{target_id: target.id, reason_code: reason})
      {:ok, target}
    end
  end

  defp evaluate_rollback_target(target, status, previous, actor, now) do
    recovered? =
      fresh_status?(status, target.rollback_started_at) and status.version == previous.version and
        Eligibility.supervision_ready?(previous, status)

    cond do
      recovered? ->
        update_target(
          target,
          %{state: :rolled_back, rolled_back_at: now, health_observed_at: status.reported_at},
          actor
        )

      deadline_elapsed?(target.deadline_at, now) ->
        update_target(
          target,
          %{
            state: :rolled_back,
            rolled_back_at: now,
            reason_code: "rollback_recovery_unverified"
          },
          actor
        )

      true ->
        {:ok, target}
    end
  end

  defp finish_or_advance(rollout, targets, actor, now) do
    cond do
      Enum.any?(targets, &(&1.state == :rollback_pending)) ->
        :ok

      rollout.state == :rolling_back and Enum.any?(targets, &(&1.state == :rolled_back)) ->
        finish_failed_rollout(rollout, :rolled_back, actor, now)

      rollout.state == :paused ->
        :ok

      Enum.any?(targets, &(&1.state in [:waiting_health, :healthy_soak])) ->
        :ok

      Enum.any?(targets, &(&1.state == :rolled_back)) and
          not tolerated_failures?(rollout, targets) ->
        finish_failed_rollout(rollout, :failed, actor, now)

      Enum.any?(targets, &(&1.state == :pending)) ->
        launch_next_batch(rollout, targets, actor, now)

      Enum.all?(targets, fn target ->
        target.state in [:succeeded, :promoted, :rolled_back, :excluded, :canceled]
      end) ->
        promote_source(rollout, targets, actor, now)

      true ->
        :ok
    end
  end

  defp launch_next_batch(rollout, targets, actor, now) do
    policy = AddonRolloutPolicy.normalize(rollout.policy)
    next_batch = targets |> Enum.filter(&(&1.state == :pending)) |> Enum.min_by(& &1.batch_index)

    selected =
      targets
      |> Enum.filter(&(&1.state == :pending and &1.batch_index == next_batch.batch_index))
      |> Enum.sort_by(& &1.agent_uid)
      |> Enum.take(policy["max_parallel"])

    selected
    |> Enum.reduce_while(:ok, fn target, :ok ->
      deadline = DateTime.add(now, policy["health_timeout_seconds"])

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
             ),
           {:ok, _} <-
             update_target(
               target,
               %{
                 state: :waiting_health,
                 override_applied_at: now,
                 deadline_at: deadline,
                 reason_code: "waiting_for_fresh_candidate_health"
               },
               actor
             ) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      :ok ->
        emit(:batch_started, rollout, %{
          batch_index: next_batch.batch_index,
          target_count: length(selected)
        })

        :ok

      {:error, reason} ->
        _ = update_rollout(rollout, %{state: :paused, error: inspect(reason)}, actor)
        {:error, reason}
    end
  end

  defp promote_source(rollout, targets, actor, now) do
    with :ok <- pin_tolerated_profile_failures(rollout, targets, actor),
         :ok <- promote_authoritative_source(rollout, actor),
         :ok <- clear_all_overrides(targets, actor),
         :ok <- mark_targets_promoted(targets, actor, now),
         {:ok, completed} <-
           update_rollout(rollout, %{state: :completed, completed_at: now}, actor) do
      audit(:complete, completed, completed.target_snapshot)
      emit(:completed, completed, completed.target_snapshot)
      :ok
    else
      {:error, reason} ->
        _ = update_rollout(rollout, %{state: :paused, error: inspect(reason)}, actor)
        {:error, reason}
    end
  end

  defp finish_failed_rollout(rollout, terminal, actor, now) do
    case update_rollout(
           rollout,
           %{state: terminal, completed_at: now, error: rollout.blocked_reason},
           actor
         ) do
      {:ok, _} ->
        audit(terminal, rollout, %{reason: rollout.blocked_reason})
        emit(terminal, rollout, %{reason: rollout.blocked_reason})
        # Vacate the unique (agent, add-on) slots so a later retry — or another
        # source — can insert fresh targets. A 1/2 canary otherwise keeps the
        # succeeded agent in the partial unique index forever.
        vacate_target_slots(rollout, actor)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tolerated_failures?(%AddonRollout{source_type: :profile} = rollout, targets) do
    tolerated = rollout.policy["tolerated_failures"] || 0
    rolled_back = Enum.count(targets, &(&1.state == :rolled_back))
    rolled_back > 0 and rolled_back <= tolerated
  end

  defp tolerated_failures?(_rollout, _targets), do: false

  defp pin_tolerated_profile_failures(
         %AddonRollout{source_type: :profile} = rollout,
         targets,
         actor
       ) do
    if tolerated_failures?(rollout, targets) do
      targets
      |> Enum.filter(&(&1.state == :rolled_back))
      |> Enum.reduce_while(:ok, fn target, :ok ->
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
          {:cont, :ok}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      :ok
    end
  end

  defp pin_tolerated_profile_failures(_rollout, _targets, _actor), do: :ok

  defp promote_authoritative_source(%AddonRollout{source_type: :assignment} = rollout, actor) do
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

  defp promote_authoritative_source(%AddonRollout{source_type: :profile} = rollout, actor) do
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

  defp begin_whole_rollback(targets, actor, now, health_timeout_seconds) do
    Enum.reduce_while(targets, :ok, fn target, :ok ->
      cond do
        target.state in [:waiting_health, :healthy_soak, :succeeded] ->
          with :ok <- clear_assignment_override(target, actor),
               {:ok, _} <-
                 update_target(
                   target,
                   %{
                     state: :rollback_pending,
                     rollback_started_at: now,
                     deadline_at: DateTime.add(now, health_timeout_seconds),
                     reason_code: "whole_rollout_rollback"
                   },
                   actor
                 ) do
            {:cont, :ok}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end

        target.state == :pending ->
          case update_target(target, %{state: :canceled, completed_at: now}, actor) do
            {:ok, _} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp advance_active_rollouts(opts) do
    actor = Keyword.fetch!(opts, :actor)

    case active_rollouts(actor) do
      {:ok, rollouts} ->
        Enum.reduce(rollouts, %{ok: 0, failed: 0}, fn rollout, stats ->
          case advance(rollout.id, opts) do
            :ok -> increment(stats, :ok)
            {:error, _} -> increment(stats, :failed)
          end
        end)

      {:error, _} ->
        %{ok: 0, failed: 1}
    end
  end

  defp record_blocked_candidate(source, previous, candidate, reason, actor, now) do
    attrs = %{
      addon_id: previous.addon_id,
      source_type: source_type(source),
      source_id: source.id,
      previous_package_id: previous.id,
      candidate_package_id: candidate.id,
      trigger: :track_latest,
      state: :failed,
      policy: AddonRolloutPolicy.normalize(source.rollout_policy),
      target_snapshot: %{},
      blocked_reason: to_string(reason),
      error: to_string(reason),
      started_at: now,
      completed_at: now
    }

    case create_rollout(attrs, actor) do
      {:ok, rollout} = ok ->
        audit(:blocked, rollout, %{reason: reason})
        emit(:blocked, rollout, %{reason: reason})
        ok

      error ->
        error
    end
  end

  defp transition_rollout(rollout_id, state, timestamp_field, opts) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:addon_rollout_transition))
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, rollout} <- get_rollout(rollout_id, actor),
         true <- rollout.state in @active_rollout_states,
         {:ok, _} <- update_rollout(rollout, %{timestamp_field => now, state: state}, actor) do
      audit(state, rollout, %{})
      emit(state, rollout, %{})
      :ok
    else
      false -> {:error, :rollout_not_active}
      {:error, reason} -> {:error, reason}
    end
  end

  defp source_targets(%AddonAssignment{} = assignment, _actor), do: {:ok, [assignment]}

  defp source_targets(%AddonProfile{} = profile, actor) do
    AddonAssignment
    |> Ash.Query.for_read(:by_profile, %{addon_profile_id: profile.id}, actor: actor)
    |> Ash.Query.filter(enabled == true)
    |> Ash.read(actor: actor)
  end

  defp direct_override_keys(%AddonAssignment{}, _targets, _actor), do: {:ok, MapSet.new()}
  defp direct_override_keys(%AddonProfile{}, [], _actor), do: {:ok, MapSet.new()}

  defp direct_override_keys(%AddonProfile{}, targets, actor) do
    agent_uids = Enum.map(targets, & &1.agent_uid)
    addon_id = targets |> List.first() |> Map.get(:addon_id)

    AddonAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      source == :manual and enabled == true and addon_id == ^addon_id and agent_uid in ^agent_uids
    )
    |> Ash.read(actor: actor)
    |> case do
      {:ok, rows} -> {:ok, MapSet.new(rows, &{&1.agent_uid, &1.addon_id})}
      error -> error
    end
  end

  defp load_agents([], _actor), do: {:ok, %{}}

  defp load_agents(targets, actor) do
    uids = targets |> Enum.map(& &1.agent_uid) |> Enum.uniq()

    Agent
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(uid in ^uids)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, agents} -> {:ok, Map.new(agents, &{&1.uid, &1})}
      error -> error
    end
  end

  defp load_statuses([], _addon_id, _actor), do: %{}

  defp load_statuses(targets, addon_id, actor) do
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

  # Readiness deliberately uses supervision_state_ready?/2, not supervision_ready?/2:
  # an advisory degradation must not keep a candidate that has come up from ever
  # being considered ready. Otherwise the target sits un-ready until its deadline
  # and fails as `candidate_health_timeout`, which is how a host-level cgroup
  # misconfiguration held anomaly three versions behind for a week.
  defp candidate_ready?(status, candidate, applied_at) do
    fresh_status?(status, applied_at) and status.version == candidate.version and
      Eligibility.supervision_state_ready?(candidate, status)
  end

  defp explicit_failure?(nil, _applied_at), do: false

  # A candidate fails on its reported STATE. It does not fail merely because the
  # add-on also reported a degradation reason: that reason is advisory, describes
  # the deployment around the add-on as often as the add-on itself, and is
  # identical before and after an upgrade -- so gating on it could only ever wedge
  # the rollout, never protect it. The reason is still recorded and surfaced; see
  # advisory_degradation/1 and the fleet row.
  defp explicit_failure?(status, applied_at) do
    state = status.state |> to_string() |> String.downcase()

    fresh_status?(status, applied_at) and
      state in ["circuit_open", "failed", "unhealthy", "verification_failed"]
  end

  defp fresh_status?(%AddonStatus{reported_at: %DateTime{} = reported_at}, %DateTime{} = since),
    do: DateTime.compare(reported_at, since) in [:gt, :eq]

  defp fresh_status?(_, _), do: false

  defp deadline_elapsed?(%DateTime{} = deadline, %DateTime{} = now),
    do: DateTime.compare(now, deadline) in [:gt, :eq]

  defp deadline_elapsed?(_, _), do: false

  defp source_package(source, actor), do: get_package(source.addon_package_id, actor)

  defp source_for_rollout(%AddonRollout{source_type: :assignment, source_id: source_id}, actor),
    do: get_assignment(source_id, actor)

  defp source_for_rollout(%AddonRollout{source_type: :profile, source_id: source_id}, actor),
    do: get_profile(source_id, actor)

  defp packages_for_rollout(rollout, targets, actor) do
    ids =
      [rollout.previous_package_id, rollout.candidate_package_id]
      |> Enum.concat(Enum.map(targets, & &1.previous_package_id))
      |> Enum.uniq()

    AddonPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, packages} when length(packages) == length(ids) ->
        {:ok, Map.new(packages, &{to_string(&1.id), &1})}

      {:ok, _} ->
        {:error, :rollout_package_missing}

      error ->
        error
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

  # Older releases could leave verified first-party sources on `manual_pin`
  # even though no operator selected a pin. Recover only those non-explicit
  # sources, and only once a genuinely newer approved package exists. The
  # approved candidate's capabilities become the ceiling, so a later
  # permission expansion remains blocked for review.
  defp restore_non_explicit_managed_sources(packages, actor) do
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
    |> Enum.filter(&Eligibility.trusted_approved?/1)
    |> Enum.filter(&(&1.addon_id == current.addon_id))
    |> Enum.flat_map(&(&1.approved_capabilities || []))
    |> Enum.uniq()
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

  defp active_rollouts(actor) do
    AddonRollout
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(state in ^@active_rollout_states)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read(actor: actor)
  end

  defp rollout_targets(rollout_id, actor) do
    AddonRolloutTarget
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(rollout_id == ^rollout_id)
    |> Ash.Query.sort(batch_index: :asc, agent_uid: :asc)
    |> Ash.read(actor: actor)
  end

  defp get_rollout(id, actor), do: get_by_id(AddonRollout, id, actor)
  defp get_assignment(id, actor), do: get_by_id(AddonAssignment, id, actor)
  defp get_profile(id, actor), do: get_by_id(AddonProfile, id, actor)
  defp get_package(id, actor), do: get_by_id(AddonPackage, id, actor)

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

  defp read_all(resource, actor) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.read(actor: actor)
  end

  defp create_rollout(attrs, actor) do
    AddonRollout
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(actor: actor, authorize?: true)
  end

  defp create_rollout_with_notifications(attrs, actor) do
    AddonRollout
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(actor: actor, authorize?: true, return_notifications?: true)
    |> normalize_ash_result_with_notifications()
  end

  defp create_target_with_notifications(attrs, actor) do
    AddonRolloutTarget
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(actor: actor, authorize?: true, return_notifications?: true)
    |> normalize_ash_result_with_notifications()
  end

  defp update_rollout(rollout, attrs, actor) do
    rollout
    |> Ash.Changeset.for_update(:update, attrs)
    |> Ash.update(actor: actor, authorize?: true)
  end

  defp update_target(target, attrs, actor) do
    target
    |> Ash.Changeset.for_update(:update, attrs)
    |> Ash.update(actor: actor, authorize?: true)
  end

  defp update_assignment(assignment, action, attrs, actor) do
    assignment
    |> Ash.Changeset.for_update(action, attrs)
    |> Ash.update(actor: actor, authorize?: true)
  end

  defp clear_assignment_override(target, actor) do
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

  defp clear_all_overrides(targets, actor) do
    Enum.reduce_while(targets, :ok, fn target, :ok ->
      case clear_assignment_override(target, actor) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # :succeeded belongs in this list even though the target's own work is done.
  # addon_rollout_targets_one_active_target_index treats succeeded as an ACTIVE
  # target for (agent_uid, addon_id), and only promote_source/4 ever moves it to
  # :promoted. Cancelling a rollout therefore used to strand every succeeded
  # target as permanently active, and the next rollout for that source died in
  # create_targets/5 on a unique-constraint violation -- which reconcile_source
  # only logs, so the source silently never advanced again. Observed on demo:
  # cancelling seven wedged rollouts stranded 26 succeeded targets and no
  # replacement rollout could be created for any of them.
  defp mark_targets_canceled(targets, actor, now) do
    Enum.reduce_while(targets, :ok, fn target, :ok ->
      if target.state in [:pending, :waiting_health, :healthy_soak, :rollback_pending, :succeeded] do
        case update_target(target, %{state: :canceled, completed_at: now}, actor) do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp mark_targets_promoted(targets, actor, now) do
    Enum.reduce_while(targets, :ok, fn target, :ok ->
      if target.state == :succeeded do
        case update_target(target, %{state: :promoted, completed_at: now}, actor) do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp target_snapshot(specs) do
    counts = specs |> Enum.map(& &1.classification) |> Enum.frequencies()

    %{
      "total" => length(specs),
      "eligible" => Map.get(counts, :eligible, 0),
      "unavailable" => Map.get(counts, :unavailable, 0),
      "incompatible" => Map.get(counts, :incompatible, 0),
      "overridden" => Map.get(counts, :overridden, 0),
      "unresolved" => Map.get(counts, :unresolved, 0)
    }
  end

  defp same_source?(rollout, source),
    do: rollout.source_type == source_type(source) and rollout.source_id == source.id

  defp source_type(%AddonAssignment{}), do: :assignment
  defp source_type(%AddonProfile{}), do: :profile

  defp increment(map, key), do: Map.update!(map, key, &(&1 + 1))

  # Partial unique index addon_rollout_targets_one_active_target_index covers
  # these states. A failed 1/2 canary leaves the healthy agent as :succeeded,
  # which blocks the next create for the same (agent_uid, addon_id).
  @slot_holding_target_states [
    :pending,
    :waiting_health,
    :healthy_soak,
    :succeeded,
    :rollback_pending
  ]

  defp vacate_target_slots(rollout, actor) do
    with {:ok, targets} <- rollout_targets(rollout.id, actor) do
      Enum.reduce_while(targets, :ok, fn target, :ok ->
        case vacate_target_slot(target, actor) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp vacate_target_slot(target, actor) do
    if target.state in @slot_holding_target_states do
      attrs =
        if target.state == :succeeded do
          %{state: :promoted, completed_at: target.completed_at || DateTime.utc_now()}
        else
          %{state: :canceled, completed_at: DateTime.utc_now()}
        end

      case update_target(target, attrs, actor) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp normalize_ash_result_with_notifications({:ok, record, %{notifications: notifications}}) do
    {:ok, record, notifications}
  end

  defp normalize_ash_result_with_notifications({:ok, record, notifications})
       when is_list(notifications) do
    {:ok, record, notifications}
  end

  defp normalize_ash_result_with_notifications({:ok, record}), do: {:ok, record, []}
  defp normalize_ash_result_with_notifications({:error, reason}), do: {:error, reason}

  defp audit(action, rollout, details) do
    AuditWriter.write_async(
      action: action,
      resource_type: "native_addon_rollout",
      resource_id: rollout.id,
      resource_name: rollout.addon_id,
      details:
        Map.merge(
          %{
            source_type: rollout.source_type,
            source_id: rollout.source_id,
            previous_package_id: rollout.previous_package_id,
            candidate_package_id: rollout.candidate_package_id
          },
          Map.new(details)
        )
    )
  end

  defp emit(state, rollout, metadata) do
    :telemetry.execute(
      [:serviceradar, :plugins, :addon_rollout, :transition],
      %{count: 1},
      Map.merge(
        %{
          state: state,
          rollout_id: rollout.id,
          addon_id: rollout.addon_id,
          source_type: rollout.source_type,
          source_id: rollout.source_id
        },
        metadata
      )
    )

    :ok
  end
end
