defmodule ServiceRadar.Plugins.AddonRolloutCoordinator do
  @moduledoc """
  Creates and advances durable, health-gated fleet rollouts.

  The stable package on a source is never changed during a canary. Each target
  receives a per-target override, and only fresh evidence for the candidate
  version can pass the gate. A failed target has its override removed before the
  rollout is stopped.

  The state machine here is artifact-agnostic. Where packages, sources, overrides
  and health evidence live is the `ServiceRadar.Plugins.RolloutArtifact`
  implementation's concern, resolved from each rollout or source. So is the
  column a row keeps its package pair and member pointer in, which is why the
  coordinator never reads those fields directly.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.AddonRollout
  alias ServiceRadar.Plugins.AddonRolloutEligibility, as: Eligibility
  alias ServiceRadar.Plugins.AddonRolloutTarget
  alias ServiceRadar.Plugins.RolloutArtifact
  alias ServiceRadar.Repo

  require Ash.Expr
  require Ash.Query
  require Logger

  @active_rollout_states [:pending, :running, :paused, :rolling_back]
  @active_target_states [:waiting_health, :healthy_soak, :rollback_pending]
  @failed_rollout_states [:failed, :rolled_back]

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

  @type source :: RolloutArtifact.source()

  @spec reconcile(keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile(opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:addon_rollout_coordinator))
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, created} <- reconcile_artifacts(actor, now) do
      advanced = advance_active_rollouts(actor: actor, now: now)
      {:ok, Map.put(created, :advanced, advanced)}
    end
  end

  defp reconcile_artifacts(actor, now) do
    empty = %{started: 0, blocked: 0, skipped: 0, repaired: 0, recovered_sources: 0}

    Enum.reduce_while(RolloutArtifact.implementations(), {:ok, empty}, fn artifact, {:ok, acc} ->
      case reconcile_artifact(artifact, actor, now) do
        {:ok, stats} ->
          {:cont, {:ok, Map.merge(acc, stats, fn _key, left, right -> left + right end)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp reconcile_artifact(artifact, actor, now) do
    with {:ok, packages} <- artifact.list_packages(actor),
         {:ok, recovered_sources} <- artifact.restore_managed_sources(packages, actor),
         {:ok, sources} <- artifact.managed_sources(actor),
         {:ok, rollouts} <- rollouts_of_kind(artifact.artifact_kind(), actor) do
      package_by_id = Map.new(packages, &{to_string(&1.id), &1})

      created =
        Enum.reduce(sources, %{started: 0, blocked: 0, skipped: 0, repaired: 0}, fn source,
                                                                                    stats ->
          reconcile_source(source, packages, package_by_id, rollouts, actor, now, stats)
        end)

      {:ok, Map.put(created, :recovered_sources, recovered_sources)}
    end
  end

  @doc """
  Starts a rollout of `candidate` for `source`.

  Options: `:actor`, `:now`, `:trigger` (default `:manual`) and `:policy`, the
  rollout controls to snapshot instead of the source's own
  (`RolloutArtifact.rollout_policy/1`).
  """
  @spec start(source(), RolloutArtifact.package(), keyword()) ::
          {:ok, AddonRollout.t()} | {:error, term()}
  def start(source, candidate, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:addon_rollout_start))
    now = Keyword.get(opts, :now, DateTime.utc_now())
    trigger = Keyword.get(opts, :trigger, :manual)
    artifact = RolloutArtifact.implementation(source)

    policy =
      artifact.normalize_policy(Keyword.get(opts, :policy) || artifact.rollout_policy(source))

    with {:ok, previous} <- stable_package(source, actor),
         :ok <- validate_candidate(source, previous, candidate, trigger),
         {:ok, members} <- artifact.source_members(source, actor),
         {:ok, agents} <- load_agents(members, actor),
         {:ok, overridden} <- artifact.overridden_members(source, members, actor),
         {:ok, rollout} <-
           create_rollout_with_targets(
             source,
             previous,
             candidate,
             members,
             agents,
             overridden,
             policy,
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
         artifact = RolloutArtifact.implementation(rollout),
         {:ok, source} <- artifact.source_for_rollout(rollout, actor),
         {:ok, candidate} <- artifact.get_package(artifact.candidate_package_id(rollout), actor),
         {:ok, retried} <-
           start(source, candidate,
             actor: actor,
             now: now,
             trigger: :retry,
             # A source without controls of its own retries with the ones the
             # failed attempt snapshotted.
             policy: artifact.rollout_policy(source) || rollout.policy
           ) do
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

    # Promotion writes the source, which an owner disable also locks, so it runs
    # as a unit of its own once the evaluation unit's writes have committed.
    case in_locked_rollout(rollout_id, actor, &advance_locked(&1, &2, actor, now)) do
      {:ok, :promote, notifications} ->
        send_notifications(notifications)

        rollout_id
        |> in_locked_rollout(actor, &promote_locked(&1, &2, actor, now))
        |> finish_unit(rollout_id, actor)

      result ->
        finish_unit(result, rollout_id, actor)
    end
  end

  defp finish_unit({:ok, _result, notifications}, _rollout_id, _actor),
    do: send_notifications(notifications)

  defp finish_unit({:error, :stale_target}, _rollout_id, _actor), do: :ok

  defp finish_unit({:error, {:pause_rollout, reason}}, rollout_id, actor) do
    _ = pause_after_failure(rollout_id, reason, actor)
    {:error, reason}
  end

  defp finish_unit({:error, reason}, _rollout_id, _actor), do: {:error, reason}

  defp advance_locked(rollout, targets, actor, now) do
    if rollout.state in @active_rollout_states do
      case RolloutArtifact.implementation(rollout).source_for_rollout(rollout, actor) do
        {:error, {:not_found, _resource, _id}} ->
          with {:ok, notifications} <- cancel_deleted_source(rollout, targets, actor, now),
               do: {:ok, :canceled, notifications}

        _source ->
          advance_active(rollout, targets, actor, now)
      end
    else
      {:ok, :inactive, []}
    end
  end

  defp advance_active(rollout, targets, actor, now) do
    with {:ok, packages} <- packages_for_rollout(rollout, targets, actor),
         :continue <- supersede_if_converged(rollout, targets, packages, actor, now),
         {:ok, targets, finished} <- finish_rolling_back(rollout, targets, actor, now),
         {:ok, rollout, targets, evaluated} <-
           evaluate_targets(rollout, targets, packages, actor, now),
         {:ok, next, advanced} <- finish_or_advance(rollout, targets, actor, now) do
      {:ok, next, finished ++ evaluated ++ advanced}
    end
  end

  defp promote_locked(rollout, targets, actor, now) do
    if rollout.state in @active_rollout_states and next_step(rollout, targets) == :promote do
      with {:ok, notifications} <- promote_source(rollout, targets, actor, now),
           do: {:ok, :promoted, notifications}
    else
      {:ok, :unchanged, []}
    end
  end

  # A failed launch or promotion rolled its whole pass back. The rollout then
  # pauses with the error for an operator, unless it moved meanwhile.
  defp pause_after_failure(rollout_id, reason, actor) do
    in_locked_rollout(rollout_id, actor, fn rollout, _targets ->
      if rollout.state == :running do
        with {:ok, paused} <-
               update_rollout(rollout, %{state: :paused, error: inspect(reason)}, actor),
             do: {:ok, paused, []}
      else
        {:refuse, :rollout_changed}
      end
    end)
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
    candidate =
      Map.get(
        packages,
        to_string(RolloutArtifact.implementation(rollout).candidate_package_id(rollout))
      )

    # :rolled_back is terminal and belongs with :excluded/:canceled here. A target
    # whose agent never reports -- a decommissioned host still enrolled in
    # ocsf_agents, which is never deleted regardless of age -- fails its health
    # deadline, lands :rolled_back, and pauses the rollout. Keeping it in scope
    # then made convergence unprovable forever, because the reap asks every
    # in-scope target for a status >= the candidate and a dead agent has none.
    # The rollout could neither promote (finish_or_advance short-circuits on
    # :paused) nor fail forward, and reconcile_source used to skip any source
    # with an active rollout -- so ONE dead agent silently froze managed updates
    # for its whole fleet. Observed on demo: seven sources stuck 17-19 days
    # behind. A sole paused rollout is now superseded by a strictly newer
    # eligible candidate instead of blocking it.
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

      converged_on_candidate?(rollout, in_scope, candidate, actor) ->
        mark_superseded(rollout, candidate, targets, length(in_scope), actor, now)

      true ->
        :continue
    end
  end

  defp converged_on_candidate?(rollout, targets, candidate, actor) do
    artifact = RolloutArtifact.implementation(rollout)
    evidence = artifact.load_evidence(targets, rollout, actor)

    Enum.all?(
      targets,
      &artifact.converged?(Map.get(evidence, artifact.evidence_key(&1)), candidate)
    )
  end

  defp mark_superseded(rollout, candidate, targets, target_count, actor, now) do
    details = %{candidate_version: candidate.version, target_count: target_count}

    with {:ok, notifications} <-
           finish_superseded_source(rollout, candidate, targets, actor, now),
         {:ok, updated} <-
           update_rollout(
             rollout,
             %{
               state: :superseded,
               completed_at: now,
               paused_at: nil,
               blocked_reason: "fleet_already_on_candidate"
             },
             actor
           ) do
      audit(:supersede, updated, details)
      emit(:superseded, updated, details)
      {:ok, :superseded, notifications}
    end
  end

  # Superseding ENDS a rollout, so it has to leave the source where completing it
  # would have: on the candidate, overrides cleared, target slots released. It used
  # to do none of that. On demo the anomaly profile stayed on 0.3.10 while seven
  # agents ran 0.3.11 through orphaned overrides, the catalog showed 0.3.11 as
  # assigned to nobody (and refused a second profile), and reconcile_source tried
  # to start the same rollout every 30 s into the slots this one still held.
  #
  # This mirrors promote_source/4. The one difference is promote_source_if_behind/3:
  # a superseded rollout can be older than the source's current package (a later
  # rollout already moved it), and finishing it must never move the source back.
  defp finish_superseded_source(rollout, candidate, targets, actor, now) do
    with {:ok, pinned} <- pin_tolerated_failures(rollout, targets, actor),
         {:ok, promoted} <- promote_source_if_behind(rollout, candidate, actor),
         {:ok, cleared} <- clear_all_overrides(rollout, targets, actor),
         :ok <- release_superseded_slots(targets, actor, now) do
      {:ok, pinned ++ promoted ++ cleared}
    end
  end

  defp promote_source_if_behind(rollout, candidate, actor) do
    artifact = RolloutArtifact.implementation(rollout)

    with {:ok, source} <- artifact.source_for_rollout(rollout, actor),
         {:ok, current} <- stable_package(source, actor) do
      if Eligibility.version_at_least?(current.version, candidate.version) do
        {:ok, []}
      else
        case artifact.promote_source(rollout, actor) do
          {:error, :owner_package_changed} -> {:ok, []}
          result -> result
        end
      end
    end
  end

  # A target still holding its slot when the rollout is superseded is one of the
  # in-scope targets that just proved convergence on the candidate, so it is
  # promoted rather than canceled.
  defp release_superseded_slots(targets, actor, now) do
    Enum.reduce_while(targets, :ok, fn target, :ok ->
      cond do
        deleted_slot_holder?(target) ->
          case cancel_deleted_target(target, actor, now) do
            {:ok, _} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        target.state in @slot_holding_target_states ->
          case transition_target(
                 target,
                 %{state: :promoted, completed_at: target.completed_at || now},
                 actor
               ) do
            {:ok, _} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        true ->
          {:cont, :ok}
      end
    end)
  end

  # Rollouts superseded before supersede finished its source are terminal, so
  # advance/2 never revisits them and their targets keep holding slots. Every
  # deployment that hit one would stay stranded until someone edited rows by hand,
  # so reconcile finishes them the way supersede now does. Returns :repaired when
  # it changed anything, because the caller's copy of the source is then stale.
  # Supersessions with blocked_reason "newer_candidate_approved" are excluded:
  # they intentionally leave the stable source on the previous package until the
  # replacement proves health, so there is no stranded promotion to repair.
  defp repair_stranded_supersessions(source_rollouts, package_by_id, actor, now) do
    source_rollouts
    |> Enum.filter(&(&1.state == :superseded and &1.blocked_reason != "newer_candidate_approved"))
    |> Enum.reduce(:none, fn rollout, acc ->
      candidate = Map.get(package_by_id, to_string(candidate_package_id(rollout)))

      with %{} <- candidate,
           {:ok, :repaired, notifications} <-
             in_locked_rollout(
               rollout.id,
               actor,
               &repair_superseded(&1, &2, candidate, actor, now)
             ) do
        send_notifications(notifications)

        Logger.info("Finished superseded native add-on rollout that still held its source",
          rollout_id: to_string(rollout.id),
          addon_id: rollout.addon_id,
          candidate_version: candidate.version
        )

        :repaired
      else
        {:error, reason} ->
          Logger.warning("Failed to finish superseded native add-on rollout",
            rollout_id: to_string(rollout.id),
            reason: inspect(reason)
          )

          acc

        _ ->
          acc
      end
    end)
  end

  defp repair_superseded(rollout, targets, candidate, actor, now) do
    if rollout.state == :superseded and
         Enum.any?(targets, &(&1.state in @slot_holding_target_states)) do
      with {:ok, notifications} <-
             finish_superseded_source(rollout, candidate, targets, actor, now),
           do: {:ok, :repaired, notifications}
    else
      {:ok, :unchanged, []}
    end
  end

  @spec pause(Ecto.UUID.t(), keyword()) :: :ok | {:error, term()}
  def pause(rollout_id, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:addon_rollout_transition))
    now = Keyword.get(opts, :now, DateTime.utc_now())

    rollout_id
    |> in_locked_rollout(actor, fn rollout, _targets ->
      if rollout.state in @active_rollout_states do
        with {:ok, paused} <- update_rollout(rollout, %{state: :paused, paused_at: now}, actor),
             do: {:ok, paused, []}
      else
        {:refuse, :rollout_not_active}
      end
    end)
    |> case do
      {:ok, rollout, _notifications} ->
        audit(:paused, rollout, %{})
        emit(:paused, rollout, %{})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec resume(Ecto.UUID.t(), keyword()) :: :ok | {:error, term()}
  def resume(rollout_id, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:addon_rollout_resume))
    now = Keyword.get(opts, :now, DateTime.utc_now())

    rollout_id
    |> in_locked_rollout(actor, fn rollout, _targets ->
      if rollout.state == :paused do
        with {:ok, resumed} <-
               update_rollout(rollout, %{state: :running, paused_at: nil}, actor),
             do: {:ok, resumed, []}
      else
        {:refuse, :rollout_not_paused}
      end
    end)
    |> case do
      {:ok, rollout, _notifications} ->
        audit(:resume, rollout, %{})
        advance(rollout.id, actor: actor, now: now)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec cancel(Ecto.UUID.t(), keyword()) :: :ok | {:error, term()}
  def cancel(rollout_id, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:addon_rollout_cancel))
    now = Keyword.get(opts, :now, DateTime.utc_now())

    rollout_id
    |> in_locked_rollout(actor, fn rollout, targets ->
      if rollout.state in @active_rollout_states do
        with {:ok, canceled} <-
               update_rollout(
                 rollout,
                 %{state: :canceled, canceled_at: now, blocked_reason: "operator_canceled"},
                 actor
               ),
             {:ok, notifications} <- clear_all_overrides(canceled, targets, actor),
             :ok <- mark_targets_canceled(targets, actor, now) do
          {:ok, {canceled, length(targets)}, notifications}
        end
      else
        {:refuse, :rollout_not_active}
      end
    end)
    |> case do
      {:ok, {rollout, target_count}, notifications} ->
        send_notifications(notifications)
        audit(:cancel, rollout, %{target_count: target_count})
        emit(:canceled, rollout, %{target_count: target_count})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Rolls every target of an active rollout back to its previous package.

  `:reason` is recorded as the rollout's blocked reason, and so as its error once
  the rollback finishes; without it the rollout keeps the reason it has.

  With `return_notifications?: true` the rollback is for a caller that holds a
  transaction of its own: it returns `{:ok, notifications}` for the caller to
  send once that transaction commits, and leaves the next advance to the
  reconcile pass.
  """
  @spec rollback(Ecto.UUID.t(), keyword()) ::
          :ok | {:ok, [Ash.Notifier.Notification.t()]} | {:error, term()}
  def rollback(rollout_id, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:addon_rollout_rollback))
    now = Keyword.get(opts, :now, DateTime.utc_now())

    rollout_attrs =
      case Keyword.get(opts, :reason) do
        nil -> %{state: :rolling_back}
        reason -> %{state: :rolling_back, blocked_reason: to_string(reason)}
      end

    rollout_id
    |> in_locked_rollout(actor, fn rollout, targets ->
      if rollout.state in @active_rollout_states do
        with {:ok, rolling_back} <- update_rollout(rollout, rollout_attrs, actor),
             {:ok, notifications} <- begin_whole_rollback(rolling_back, targets, actor, now) do
          {:ok, {rolling_back, length(targets)}, notifications}
        end
      else
        {:refuse, :rollout_not_active}
      end
    end)
    |> case do
      {:ok, {rollout, target_count}, notifications} ->
        audit(:rollback, rollout, %{target_count: target_count, reason: opts[:reason]})
        emit(:rolling_back, rollout, %{target_count: target_count})

        if Keyword.get(opts, :return_notifications?, false) do
          {:ok, notifications}
        else
          send_notifications(notifications)
          advance(rollout.id, actor: actor, now: now)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_source(source, packages, package_by_id, rollouts, actor, now, stats) do
    current = Map.get(package_by_id, to_string(stable_package_id(source)))
    source_rollouts = Enum.filter(rollouts, &same_source?(&1, source))
    active = Enum.filter(source_rollouts, &(&1.state in @active_rollout_states))

    cond do
      is_nil(current) ->
        increment(stats, :skipped)

      match?([%AddonRollout{state: :paused}], active) ->
        replace_paused_candidate(
          source,
          hd(active),
          packages,
          package_by_id,
          source_rollouts,
          actor,
          now,
          stats
        )

      active != [] ->
        increment(stats, :skipped)

      repair_stranded_supersessions(source_rollouts, package_by_id, actor, now) == :repaired ->
        # The source row just moved; start nothing from the stale copy read above.
        increment(stats, :repaired)

      true ->
        start_next_candidate(source, current, packages, source_rollouts, actor, now, stats)
    end
  end

  defp replace_paused_candidate(
         source,
         paused,
         packages,
         package_by_id,
         source_rollouts,
         actor,
         now,
         stats
       ) do
    previous_candidate = Map.get(package_by_id, to_string(candidate_package_id(paused)))

    with %{} <- previous_candidate,
         {:ok, candidate} <-
           Eligibility.latest_candidate(previous_candidate, packages, source,
             blocked_candidate_ids: blocked_candidate_ids(source_rollouts)
           ),
         {:ok, superseded} <- supersede_failed_candidate(paused, candidate, actor, now),
         {:ok, refreshed_source} <-
           RolloutArtifact.implementation(superseded).source_for_rollout(superseded, actor) do
      # Re-read after clearing overrides. The failed candidate is never promoted;
      # the replacement must prove health before the stable source moves.
      current = Map.get(package_by_id, to_string(stable_package_id(refreshed_source)))

      rollouts =
        Enum.map(source_rollouts, fn rollout ->
          if rollout.id == superseded.id, do: superseded, else: rollout
        end)

      start_next_candidate(refreshed_source, current, packages, rollouts, actor, now, stats)
    else
      {:error, reason} ->
        Logger.warning("Failed to replace paused fleet rollout",
          rollout_id: to_string(paused.id),
          reason: inspect(reason)
        )

        increment(stats, :skipped)

      _ ->
        increment(stats, :skipped)
    end
  end

  defp supersede_failed_candidate(paused, candidate, actor, now) do
    # Release overrides and unique target slots together with terminalizing the
    # old rollout. A failed write must leave the paused attempt recoverable.
    paused.id
    |> in_locked_rollout(actor, fn rollout, targets ->
      if rollout.state == :paused do
        with {:ok, notifications} <- clear_all_overrides(rollout, targets, actor),
             :ok <- mark_targets_canceled(targets, actor, now),
             {:ok, updated} <-
               update_rollout(
                 rollout,
                 %{
                   state: :superseded,
                   completed_at: now,
                   paused_at: nil,
                   blocked_reason: "newer_candidate_approved",
                   error: rollout.error || rollout.blocked_reason
                 },
                 actor
               ) do
          {:ok, updated, notifications}
        end
      else
        {:refuse, :rollout_not_paused}
      end
    end)
    |> case do
      {:ok, updated, notifications} ->
        send_notifications(notifications)

        details = %{
          replacement_candidate_version: candidate.version,
          previous_blocked_reason: paused.blocked_reason
        }

        audit(:supersede, updated, details)
        emit(:superseded, updated, details)
        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp blocked_candidate_ids(source_rollouts) do
    source_rollouts
    |> Enum.filter(fn rollout ->
      rollout.state in @failed_rollout_states or
        (rollout.state == :superseded and rollout.blocked_reason == "newer_candidate_approved")
    end)
    |> Enum.map(&candidate_package_id/1)
  end

  defp start_next_candidate(source, current, packages, source_rollouts, actor, now, stats) do
    blocked_ids = blocked_candidate_ids(source_rollouts)

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
            Logger.warning("Failed to start fleet rollout",
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

  # A reconcile chose the candidate of a :track_latest start; every other
  # trigger names its candidate.
  defp validate_candidate(source, previous, candidate, trigger) do
    case Eligibility.latest_candidate(previous, [candidate], source,
           selected: trigger != :track_latest
         ) do
      {:ok, ^candidate} -> :ok
      {:blocked, reason, _} -> {:error, reason}
      :none -> {:error, :candidate_not_eligible}
    end
  end

  defp create_rollout_with_targets(
         source,
         previous,
         candidate,
         members,
         agents,
         overridden,
         policy,
         actor,
         now,
         trigger
       ) do
    target_specs = target_specs(candidate, members, agents, overridden, policy, now)

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
    rollout_attrs =
      source
      |> rollout_identity(previous, candidate)
      |> Map.merge(%{
        trigger: trigger,
        state: :running,
        policy: policy,
        target_snapshot: target_snapshot(target_specs),
        started_at: now
      })

    artifact = RolloutArtifact.implementation(source)

    # The candidate is re-read under a share lock before the rollout exists:
    # revocation locks the package and then looks for its rollouts, so either it
    # commits first and the candidate is refused here, or it waits and finds this
    # rollout.
    transaction_result =
      Repo.transaction(fn ->
        with :ok <- artifact.lock_candidate(candidate, actor),
             {:ok, rollout, rollout_notifications} <-
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
        send_notifications(notifications)
        audit(:start, rollout, rollout.target_snapshot)
        emit(:started, rollout, rollout.target_snapshot)
        {:ok, rollout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp target_specs(candidate, members, agents, overridden, policy, now) do
    # Drop superseded identities before a target row exists. Classifying them
    # as excluded would still insert a row, and a rollout that counts every
    # target would keep waiting on an identity that will not report.
    members = Enum.reject(members, &superseded_agent?(&1, agents))

    classified =
      members
      |> Enum.sort_by(& &1.agent_uid)
      |> Enum.map(fn member ->
        {classification, reason} =
          if MapSet.member?(overridden, member.id) do
            {:overridden, "direct_assignment_precedence"}
          else
            Eligibility.classify_target(candidate, Map.get(agents, member.agent_uid), now)
          end

        %{member: member, classification: classification, reason_code: reason}
      end)

    # Only :eligible targets are batched. An agent that is not reporting must not
    # consume a canary slot -- it cannot demonstrate the candidate is healthy, so
    # spending the canary on it means the batch behind it waits on a host that
    # will never answer.
    advanceable = Enum.filter(classified, &(&1.classification == :eligible))
    batch_by_member = batch_indexes(advanceable, policy)

    Enum.map(classified, fn spec ->
      Map.put(spec, :batch_index, Map.get(batch_by_member, spec.member.id, 0))
    end)
  end

  defp superseded_agent?(member, agents) do
    case Map.get(agents, member.agent_uid) do
      %{status: :superseded} -> true
      %{status: "superseded"} -> true
      %{"status" => "superseded"} -> true
      %{"status" => :superseded} -> true
      _ -> false
    end
  end

  defp batch_indexes(specs, policy) do
    canary_size = min(policy["canary_size"], length(specs))
    batch_size = policy["batch_size"]

    specs
    |> Enum.with_index()
    |> Map.new(fn {spec, index} ->
      batch = if index < canary_size, do: 0, else: 1 + div(index - canary_size, batch_size)
      {spec.member.id, batch}
    end)
  end

  defp create_targets(rollout, specs, previous, candidate, actor) do
    artifact = RolloutArtifact.implementation(rollout)

    Enum.reduce_while(specs, {:ok, []}, fn spec, {:ok, notifications} ->
      # :unavailable belongs with :incompatible, not with :eligible. An agent that
      # is not reporting cannot run the candidate now, and making it a :pending
      # target means the rollout waits out its health deadline and then pauses --
      # which is how one retired agent identity froze managed updates for a whole
      # fleet for 19 days. Exclude it with its reason recorded, and let the next
      # rollout pick the agent up once it reports in. Operators should never have
      # to hand-write target queries to route around an agent the system can
      # already see is not there.
      state = if spec.classification == :eligible, do: :pending, else: :excluded

      attrs =
        previous
        |> artifact.package_attrs(candidate)
        |> Map.merge(artifact.target_attrs(spec.member, previous))
        |> Map.merge(%{
          artifact_kind: rollout.artifact_kind,
          rollout_id: rollout.id,
          source_type: rollout.source_type,
          source_id: rollout.source_id,
          batch_index: spec.batch_index,
          classification: spec.classification,
          state: state,
          reason_code: spec.reason_code
        })

      case create_target_with_notifications(attrs, actor) do
        {:ok, _target, target_notifications} ->
          {:cont, {:ok, notifications ++ target_notifications}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp evaluate_targets(rollout, targets, packages, actor, now) do
    artifact = RolloutArtifact.implementation(rollout)
    evaluating = Enum.filter(targets, &(&1.state in @active_target_states))
    evidence = artifact.load_evidence(evaluating, rollout, actor)

    targets
    |> Enum.reduce_while({:ok, rollout, [], []}, fn target, {:ok, rollout, acc, notifications} ->
      result =
        if deleted_slot_holder?(target) do
          cancel_deleted_target(target, actor, now)
        else
          case target.state do
            state when state in [:waiting_health, :healthy_soak] ->
              evaluate_candidate_target(
                rollout,
                target,
                Map.get(evidence, artifact.evidence_key(target)),
                Map.fetch!(packages, to_string(artifact.candidate_package_id(target))),
                actor,
                now
              )

            :rollback_pending ->
              evaluate_rollback_target(
                rollout,
                target,
                Map.get(evidence, artifact.evidence_key(target)),
                Map.fetch!(packages, to_string(artifact.previous_package_id(target))),
                actor,
                now
              )

            _ ->
              {:ok, target}
          end
        end

      case result do
        {:ok, updated, rollout, cleared} ->
          {:cont, {:ok, rollout, [updated | acc], notifications ++ cleared}}

        {:ok, updated} ->
          {:cont, {:ok, rollout, [updated | acc], notifications}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rollout, evaluated, notifications} ->
        {:ok, rollout, Enum.reverse(evaluated), notifications}

      error ->
        error
    end
  end

  defp evaluate_candidate_target(rollout, target, evidence, candidate, actor, now) do
    artifact = RolloutArtifact.implementation(rollout)

    cond do
      artifact.candidate_failed?(evidence, candidate, target.override_applied_at) ->
        fail_and_rollback_target(rollout, target, "candidate_reported_unhealthy", actor, now)

      artifact.candidate_ready?(evidence, candidate, target.override_applied_at) ->
        evaluate_soak(
          target,
          artifact.observed_at(evidence),
          artifact.ready_reason(evidence, candidate, target.override_applied_at),
          rollout.policy,
          actor,
          now
        )

      deadline_elapsed?(target.deadline_at, now) ->
        fail_and_rollback_target(rollout, target, "candidate_health_timeout", actor, now)

      true ->
        {:ok, target}
    end
  end

  # `reason` is the implementation's account of what made the target ready. It
  # is recorded on every soak step, so a target that passes carries the reason
  # that applied when it passed.
  defp evaluate_soak(target, observed_at, reason, policy, actor, now) do
    soak_seconds = policy["soak_seconds"] || 300
    observed = with_reason(%{health_observed_at: observed_at}, reason)

    cond do
      is_nil(target.healthy_since) and soak_seconds == 0 ->
        transition_target(
          target,
          Map.merge(observed, %{state: :succeeded, healthy_since: now, completed_at: now}),
          actor
        )

      is_nil(target.healthy_since) ->
        transition_target(
          target,
          Map.merge(observed, %{state: :healthy_soak, healthy_since: now}),
          actor
        )

      DateTime.diff(now, target.healthy_since, :second) >= soak_seconds ->
        transition_target(
          target,
          Map.merge(observed, %{state: :succeeded, completed_at: now}),
          actor
        )

      true ->
        transition_target(target, observed, actor)
    end
  end

  defp with_reason(attrs, nil), do: attrs
  defp with_reason(attrs, reason), do: Map.put(attrs, :reason_code, reason)

  defp fail_and_rollback_target(rollout, target, reason, actor, now) do
    artifact = RolloutArtifact.implementation(rollout)

    # An implementation that rolls back on failure moves the whole rollout to
    # :rolling_back; finish_rolling_back/4 sends its other targets back on the
    # next pass. Otherwise the rollout pauses for an operator decision.
    rollout_attrs =
      if artifact.rolls_back_on_failure?(rollout),
        do: %{state: :rolling_back, blocked_reason: reason},
        else: %{state: :paused, paused_at: now, blocked_reason: reason}

    with {:ok, notifications} <- artifact.clear_override(target, actor),
         {:ok, target} <-
           transition_target(
             target,
             %{
               state: :rollback_pending,
               reason_code: reason,
               rollback_started_at: now,
               deadline_at:
                 DateTime.shift(now, second: rollout.policy["health_timeout_seconds"] || 900)
             },
             actor
           ),
         {:ok, rollout} <- update_rollout(rollout, rollout_attrs, actor) do
      emit(:target_failed, rollout, %{target_id: target.id, reason_code: reason})
      {:ok, target, rollout, notifications}
    end
  end

  defp evaluate_rollback_target(rollout, target, evidence, previous, actor, now) do
    artifact = RolloutArtifact.implementation(rollout)

    cond do
      artifact.recovered?(evidence, previous, target.rollback_started_at) ->
        transition_target(
          target,
          %{
            state: :rolled_back,
            rolled_back_at: now,
            health_observed_at: artifact.observed_at(evidence)
          },
          actor
        )

      deadline_elapsed?(target.deadline_at, now) ->
        transition_target(
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
    case next_step(rollout, targets) do
      :wait ->
        {:ok, :advanced, []}

      {:finish, terminal} ->
        with {:ok, notifications} <- finish_failed_rollout(rollout, terminal, actor, now),
             do: {:ok, :advanced, notifications}

      :launch ->
        with {:ok, notifications} <- launch_next_batch(rollout, targets, actor, now),
             do: {:ok, :advanced, notifications}

      :promote ->
        {:ok, :promote, []}
    end
  end

  defp next_step(rollout, targets) do
    cond do
      Enum.any?(targets, &(&1.state == :rollback_pending)) ->
        :wait

      # Nothing is waiting to recover, so the rollback is over. That holds even
      # when no target rolled back -- every one was still pending, or was
      # canceled -- and such a rollout must end here: falling through would
      # find every target terminal and promote the candidate it was rolling
      # back from.
      rollout.state == :rolling_back ->
        {:finish, :rolled_back}

      rollout.state == :paused ->
        :wait

      Enum.any?(targets, &(&1.state in [:waiting_health, :healthy_soak])) ->
        :wait

      Enum.any?(targets, &(&1.state == :rolled_back)) and
          not tolerated_failures?(rollout, targets) ->
        {:finish, :failed}

      Enum.any?(targets, &(&1.state == :pending)) ->
        :launch

      Enum.all?(targets, fn target ->
        target.state in [:succeeded, :promoted, :rolled_back, :excluded, :canceled]
      end) ->
        :promote

      true ->
        :wait
    end
  end

  defp launch_next_batch(rollout, targets, actor, now) do
    artifact = RolloutArtifact.implementation(rollout)
    policy = artifact.normalize_policy(rollout.policy)
    next_batch = targets |> Enum.filter(&(&1.state == :pending)) |> Enum.min_by(& &1.batch_index)

    selected =
      targets
      |> Enum.filter(&(&1.state == :pending and &1.batch_index == next_batch.batch_index))
      |> Enum.sort_by(& &1.agent_uid)
      |> Enum.take(policy["max_parallel"])

    selected
    |> Enum.reduce_while({:ok, []}, fn target, {:ok, notifications} ->
      result =
        if is_nil(artifact.member_id(target)) do
          # The assignment was deleted after this target was created (its FK is
          # ON DELETE SET NULL). There is nothing left to override, so the target
          # stops holding its slot instead of pausing the whole rollout.
          case cancel_deleted_target(target, actor, now) do
            {:ok, _} -> {:ok, []}
            {:error, reason} -> {:error, reason}
          end
        else
          launch_target(target, rollout, policy, actor, now)
        end

      case result do
        {:ok, launched} -> {:cont, {:ok, notifications ++ launched}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, notifications} ->
        emit(:batch_started, rollout, %{
          batch_index: next_batch.batch_index,
          target_count: length(selected)
        })

        {:ok, notifications}

      {:error, :stale_target} ->
        {:error, :stale_target}

      {:error, reason} ->
        {:error, {:pause_rollout, reason}}
    end
  end

  # apply_override/4 locks the member before the target moves: a retraction
  # locks the member and then cancels its targets, and taking them in the same
  # order cannot deadlock. A member disabled meanwhile cancels its target as
  # assignment_retracted.
  defp launch_target(target, rollout, policy, actor, now) do
    case RolloutArtifact.implementation(rollout).apply_override(target, rollout, now, actor) do
      {:ok, notifications} ->
        with {:ok, _target} <-
               transition_target(
                 target,
                 %{
                   state: :waiting_health,
                   override_applied_at: now,
                   deadline_at: DateTime.shift(now, second: policy["health_timeout_seconds"]),
                   reason_code: "waiting_for_fresh_candidate_health"
                 },
                 actor
               ),
             do: {:ok, notifications}

      {:error, :assignment_disabled} ->
        with {:ok, _target} <-
               transition_target(
                 target,
                 %{state: :canceled, reason_code: "assignment_retracted", completed_at: now},
                 actor
               ),
             do: {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp promote_source(rollout, targets, actor, now) do
    with {:ok, pinned} <- pin_tolerated_failures(rollout, targets, actor),
         {:ok, promoted} <-
           RolloutArtifact.implementation(rollout).promote_source(rollout, actor),
         {:ok, cleared} <- clear_all_overrides(rollout, targets, actor),
         :ok <- mark_targets_promoted(targets, actor, now),
         {:ok, completed} <-
           update_rollout(rollout, %{state: :completed, completed_at: now}, actor) do
      audit(:complete, completed, completed.target_snapshot)
      emit(:completed, completed, completed.target_snapshot)
      {:ok, pinned ++ promoted ++ cleared}
    else
      {:error, :owner_package_changed} -> supersede_moved_owner(rollout, targets, actor, now)
      {:error, :source_deleted} -> cancel_deleted_source(rollout, targets, actor, now)
      {:error, :stale_target} -> {:error, :stale_target}
      {:error, reason} -> {:error, {:pause_rollout, reason}}
    end
  end

  # The source was moved to another package while the rollout ran. The
  # candidate does not overwrite that choice: the rollout releases its
  # overrides and target slots and ends superseded.
  defp supersede_moved_owner(rollout, targets, actor, now) do
    details = %{reason: "owner_package_changed"}

    with {:ok, notifications} <- clear_all_overrides(rollout, targets, actor),
         :ok <- mark_targets_canceled(targets, actor, now),
         {:ok, updated} <-
           update_rollout(
             rollout,
             %{state: :superseded, completed_at: now, blocked_reason: "owner_package_changed"},
             actor
           ) do
      audit(:supersede, updated, details)
      emit(:superseded, updated, details)
      {:ok, notifications}
    end
  end

  # The source row was deleted while the rollout ran, so there is nothing left
  # to promote. Pausing would keep the rollout active for a source no reconcile
  # will ever revisit; it ends canceled instead, releasing what it still holds.
  defp cancel_deleted_source(rollout, targets, actor, now) do
    with {:ok, notifications} <- clear_all_overrides(rollout, targets, actor),
         :ok <- mark_targets_canceled(targets, actor, now),
         {:ok, updated} <-
           update_rollout(
             rollout,
             %{
               state: :canceled,
               canceled_at: now,
               paused_at: nil,
               blocked_reason: "source_deleted"
             },
             actor
           ) do
      audit(:cancel, updated, %{reason: "source_deleted"})
      emit(:canceled, updated, %{reason: "source_deleted"})
      {:ok, notifications}
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
        with :ok <- vacate_target_slots(rollout, actor), do: {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tolerated_failures?(rollout, targets) do
    if RolloutArtifact.implementation(rollout).tolerates_failures?(rollout) do
      tolerated = rollout.policy["tolerated_failures"] || 0

      rolled_back = Enum.count(targets, &rolled_back_member?/1)

      rolled_back > 0 and rolled_back <= tolerated
    else
      false
    end
  end

  defp pin_tolerated_failures(rollout, targets, actor) do
    if tolerated_failures?(rollout, targets) do
      artifact = RolloutArtifact.implementation(rollout)

      targets
      |> Enum.filter(&rolled_back_member?/1)
      |> Enum.reduce_while({:ok, []}, fn target, {:ok, notifications} ->
        case artifact.pin_failed_member(target, actor) do
          {:ok, pinned} -> {:cont, {:ok, notifications ++ pinned}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      {:ok, []}
    end
  end

  defp rolled_back_member?(target),
    do: target.state == :rolled_back and not is_nil(member_id(target))

  # A rollout that is rolling back must not leave any target on the candidate.
  # rollback/2 sends every target back when it starts the rollback, but a failed
  # target that moves the rollout to :rolling_back (rolls_back_on_failure?/1)
  # does so mid-pass, while the rest of that pass still evaluates the other
  # targets from the copies it read before. This picks those up on the next
  # pass. For a rollout rollback/2 started it finds nothing to do.
  defp finish_rolling_back(%AddonRollout{state: :rolling_back} = rollout, targets, actor, now) do
    if Enum.any?(targets, &(&1.state in [:pending, :waiting_health, :healthy_soak, :succeeded])) do
      with {:ok, notifications} <- begin_whole_rollback(rollout, targets, actor, now),
           {:ok, targets} <- rollout_targets(rollout, actor) do
        {:ok, targets, notifications}
      end
    else
      {:ok, targets, []}
    end
  end

  defp finish_rolling_back(_rollout, targets, _actor, _now), do: {:ok, targets, []}

  defp begin_whole_rollback(rollout, targets, actor, now) do
    artifact = RolloutArtifact.implementation(rollout)
    health_timeout_seconds = rollout.policy["health_timeout_seconds"] || 900

    Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, notifications} = acc ->
      cond do
        deleted_slot_holder?(target) ->
          case cancel_deleted_target(target, actor, now) do
            {:ok, _} -> {:cont, acc}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        target.state in [:waiting_health, :healthy_soak, :succeeded] ->
          with {:ok, cleared} <- artifact.clear_override(target, actor),
               {:ok, _} <-
                 transition_target(
                   target,
                   %{
                     state: :rollback_pending,
                     rollback_started_at: now,
                     deadline_at: DateTime.shift(now, second: health_timeout_seconds),
                     reason_code: "whole_rollout_rollback"
                   },
                   actor
                 ) do
            {:cont, {:ok, notifications ++ cleared}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end

        target.state == :pending ->
          case transition_target(target, %{state: :canceled, completed_at: now}, actor) do
            {:ok, _} -> {:cont, acc}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        true ->
          {:cont, acc}
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
    attrs =
      source
      |> rollout_identity(previous, candidate)
      |> Map.merge(%{
        trigger: :track_latest,
        state: :failed,
        policy: normalized_source_policy(source),
        target_snapshot: %{},
        blocked_reason: to_string(reason),
        error: to_string(reason),
        started_at: now,
        completed_at: now
      })

    case create_rollout(attrs, actor) do
      {:ok, rollout} = ok ->
        audit(:blocked, rollout, %{reason: reason})
        emit(:blocked, rollout, %{reason: reason})
        ok

      error ->
        error
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

  defp deadline_elapsed?(%DateTime{} = deadline, %DateTime{} = now),
    do: DateTime.compare(now, deadline) in [:gt, :eq]

  defp deadline_elapsed?(_, _), do: false

  defp stable_package(source, actor) do
    artifact = RolloutArtifact.implementation(source)
    artifact.get_package(artifact.stable_package_id(source), actor)
  end

  defp stable_package_id(source),
    do: RolloutArtifact.implementation(source).stable_package_id(source)

  defp normalized_source_policy(source) do
    artifact = RolloutArtifact.implementation(source)
    artifact.normalize_policy(artifact.rollout_policy(source))
  end

  defp previous_package_id(rollout_or_target),
    do: RolloutArtifact.implementation(rollout_or_target).previous_package_id(rollout_or_target)

  defp candidate_package_id(rollout_or_target),
    do: RolloutArtifact.implementation(rollout_or_target).candidate_package_id(rollout_or_target)

  defp member_id(target), do: RolloutArtifact.implementation(target).member_id(target)

  defp rollout_identity(source, previous, candidate) do
    artifact = RolloutArtifact.implementation(source)

    previous
    |> artifact.package_attrs(candidate)
    |> Map.merge(%{
      artifact_kind: artifact.artifact_kind(),
      addon_id: artifact.artifact_id(previous),
      source_type: artifact.source_type(source),
      source_id: source.id
    })
  end

  defp packages_for_rollout(rollout, targets, actor) do
    ids =
      [previous_package_id(rollout), candidate_package_id(rollout)]
      |> Enum.concat(Enum.map(targets, &previous_package_id/1))
      |> Enum.uniq()

    case RolloutArtifact.implementation(rollout).packages_by_id(ids, actor) do
      {:ok, packages} when length(packages) == length(ids) ->
        {:ok, Map.new(packages, &{to_string(&1.id), &1})}

      {:ok, _} ->
        {:error, :rollout_package_missing}

      error ->
        error
    end
  end

  # Every rollout read is limited to artifact kinds that have an implementation
  # (RolloutArtifact.kinds/0), so a row of any other kind is never acted on.
  defp active_rollouts(actor) do
    AddonRollout
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      state in ^@active_rollout_states and artifact_kind in ^RolloutArtifact.kinds()
    )
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read(actor: actor)
  end

  defp rollouts_of_kind(artifact_kind, actor) do
    AddonRollout
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(artifact_kind == ^artifact_kind)
    |> Ash.read(actor: actor)
  end

  defp rollout_targets(rollout, actor) do
    AddonRolloutTarget
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(rollout_id == ^rollout.id and artifact_kind == ^rollout.artifact_kind)
    |> Ash.Query.sort(batch_index: :asc, agent_uid: :asc)
    |> Ash.read(actor: actor)
  end

  defp get_rollout(id, actor) do
    AddonRollout
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id and artifact_kind in ^RolloutArtifact.kinds())
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} -> {:error, {:not_found, AddonRollout, id}}
      result -> result
    end
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

  # Every change to an existing rollout runs here: one transaction that locks
  # the rollout row, reads its targets, and locks the owner and member rows
  # (RolloutArtifact.lock_members/3) before writing anything. Every unit so
  # takes rows in one order -- rollout, owner, members, targets -- the order a
  # retraction or owner disable takes members and targets in. `fun` returns
  # {:ok, result, notifications}; {:refuse, reason} when the rollout is not in a
  # state it acts on, having written nothing; or {:error, reason}, which rolls
  # the whole unit back, so no partial clear, transition or terminal state
  # commits. The notifications of a committed unit are returned for the caller
  # to send.
  defp in_locked_rollout(rollout_id, actor, fun) do
    fn ->
      with {:ok, rollout} <- lock_rollout(rollout_id, actor),
           {:ok, targets} <- rollout_targets(rollout, actor),
           :ok <-
             RolloutArtifact.implementation(rollout).lock_members(rollout, targets, actor) do
        case fun.(rollout, targets) do
          {:ok, result, notifications} -> {:done, result, notifications}
          {:refuse, reason} -> {:refused, reason}
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end
    |> Repo.transaction()
    |> case do
      {:ok, {:done, result, notifications}} -> {:ok, result, notifications}
      {:ok, {:refused, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_rollout(id, actor) do
    AddonRollout
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id and artifact_kind in ^RolloutArtifact.kinds())
    |> Ash.Query.lock("FOR UPDATE")
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} -> {:error, {:not_found, AddonRollout, id}}
      result -> result
    end
  end

  # Moves a target only from the state this unit read. A retraction can move a
  # target without the rollout lock; that returns {:error, :stale_target}, which
  # aborts the unit for the next pass to read again.
  defp transition_target(target, attrs, actor) do
    read_state = target.state

    target
    |> Ash.Changeset.for_update(:update, attrs)
    |> Ash.Changeset.filter(Ash.Expr.expr(state == ^read_state))
    |> Ash.update(actor: actor, authorize?: true)
    |> case do
      {:ok, updated} ->
        {:ok, updated}

      {:error, error} ->
        if RolloutArtifact.stale_write?(error), do: {:error, :stale_target}, else: {:error, error}
    end
  end

  # Rollout transactions collect member-write notifications and send them here,
  # after the outermost transaction commits.
  defp send_notifications(notifications) do
    _unsent = Ash.Notifier.notify(notifications)
    :ok
  end

  defp clear_all_overrides(rollout, targets, actor) do
    artifact = RolloutArtifact.implementation(rollout)

    Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, notifications} ->
      case artifact.clear_override(target, actor) do
        {:ok, cleared} -> {:cont, {:ok, notifications ++ cleared}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp deleted_slot_holder?(%AddonRolloutTarget{state: state} = target),
    do: state in @slot_holding_target_states and is_nil(member_id(target))

  defp cancel_deleted_target(target, actor, now) do
    transition_target(
      target,
      %{state: :canceled, reason_code: "assignment_deleted", completed_at: now},
      actor
    )
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
      cond do
        deleted_slot_holder?(target) ->
          case cancel_deleted_target(target, actor, now) do
            {:ok, _} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        target.state in [:pending, :waiting_health, :healthy_soak, :rollback_pending, :succeeded] ->
          case transition_target(target, %{state: :canceled, completed_at: now}, actor) do
            {:ok, _} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp mark_targets_promoted(targets, actor, now) do
    Enum.reduce_while(targets, :ok, fn target, :ok ->
      cond do
        deleted_slot_holder?(target) ->
          case cancel_deleted_target(target, actor, now) do
            {:ok, _} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        target.state == :succeeded ->
          case transition_target(target, %{state: :promoted, completed_at: now}, actor) do
            {:ok, _} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        true ->
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

  defp same_source?(rollout, source) do
    rollout.source_type == RolloutArtifact.implementation(source).source_type(source) and
      rollout.source_id == source.id
  end

  defp increment(map, key), do: Map.update!(map, key, &(&1 + 1))

  defp vacate_target_slots(rollout, actor) do
    with {:ok, targets} <- rollout_targets(rollout, actor) do
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
        cond do
          deleted_slot_holder?(target) ->
            %{
              state: :canceled,
              reason_code: "assignment_deleted",
              completed_at: DateTime.utc_now()
            }

          target.state == :succeeded ->
            %{state: :promoted, completed_at: target.completed_at || DateTime.utc_now()}

          true ->
            %{state: :canceled, completed_at: DateTime.utc_now()}
        end

      case transition_target(target, attrs, actor) do
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

  # `automatic` marks a rollout the reconcile started for a source tracking the
  # latest approved package, as opposed to one an operator or a retry started.
  defp audit(action, rollout, details) do
    AuditWriter.write_async(
      action: action,
      resource_type: RolloutArtifact.implementation(rollout).audit_resource_type(),
      resource_id: rollout.id,
      resource_name: rollout.addon_id,
      details:
        Map.merge(
          %{
            trigger: rollout.trigger,
            automatic: rollout.trigger == :track_latest,
            source_type: rollout.source_type,
            source_id: rollout.source_id,
            previous_package_id: previous_package_id(rollout),
            candidate_package_id: candidate_package_id(rollout)
          },
          Map.new(details)
        )
    )
  end

  defp emit(state, rollout, metadata) do
    :telemetry.execute(
      RolloutArtifact.implementation(rollout).telemetry_event(),
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
