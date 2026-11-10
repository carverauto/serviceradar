defmodule ServiceRadar.SweepJobs.LeasePass do
  @moduledoc """
  Keeps every sweep schedule lease matching its group, its agents and the edge pipeline
  settings.

  For each group the pass decides who holds a lease and what its unrun slots are:

    * a group that is not eligible (`ServiceRadar.SweepJobs.LeaseEligibility`) holds no lease:
      every active assignment is revoked, which drops its unrun slots and returns the agents to
      their local ticker;
    * an agent the group no longer runs on (`ServiceRadar.SweepJobs.LeaseAgents`), whose
      partition has no row, or whose reported capabilities leave it no check it can lease
      (`LeaseEligibility.agent_checks/3`), is revoked the same way. Leasing has no switch: the
      horizon comes from `ServiceRadar.Edge.PipelineSettings`;
    * every other agent holds an active assignment (`ProducerAssignments.ensure/3`) whose unrun
      slots are exactly the schedule's slots between now and the agent's horizon, planned under
      the assignment's current epoch, that agent's check set and the group's targets.

  The check set is per agent: it is the check set of the sweep config that agent is delivered
  for the group, which withholds the modes the agent reports it cannot run. A capability
  change therefore changes the planned check set and re-plans the agent's unrun slots.

  An unrun slot that no longer matches (its epoch was bumped, its check set, network scope or
  planned targets changed, or the schedule or horizon moved) is dropped and planned again, so
  the next pass re-plans a lease rather than leaving it on the old targets. A slot that has
  started is never touched. Becoming eligible again after a revoke reissues the assignment
  under a new epoch, which is a new lease.

  The lease id is derived from the assignment and its epoch, so every pass names the same lease
  without storing it, and a bump starts a new one.

  A pass mints at most `max_new_slots_per_assignment/0` slots per assignment, nearest first; a
  longer horizon fills over the following passes. A schedule whose slots in the horizon include
  one shorter than `LeaseSchedule.min_interval_seconds/0` (a dense cron) is not leased.

  The pass is idempotent and keeps no state of its own: running it twice, or after a crash
  part-way through, converges on the same slots. A delivery row outlives its group, so a pass
  with one still revokes it.

  After the horizon is refilled, `LeaseMisses.mark/2` closes scheduled slots that
  are past grace with no sweep execution. A group that hit any error in this pass
  (its profile, candidates, assignments, slot listing, drop, refill or delivery)
  is left unmarked until a later pass plans it cleanly. The mark runs even when
  the pass is otherwise idle, so a slot that expires after its lease was withdrawn
  is still closed. `LeaseMisses` owns what counts as committed and which missed
  state applies.
  """

  alias Ash.Error.Query.NotFound
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Edge.PipelineSettings
  alias ServiceRadar.Edge.SweepPlan
  alias Serviceradar.Edge.V1.ScheduledPlanPageV1
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ExecutionSlots
  alias ServiceRadar.SweepJobs.LeaseAgents
  alias ServiceRadar.SweepJobs.LeaseDelivery
  alias ServiceRadar.SweepJobs.LeaseEligibility
  alias ServiceRadar.SweepJobs.LeaseMisses
  alias ServiceRadar.SweepJobs.LeaseSchedule
  alias ServiceRadar.SweepJobs.ProducerAssignments
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepProducerAssignment
  alias ServiceRadar.SweepJobs.SweepProfile

  require Ash.Query
  require Logger

  @max_new_slots_per_assignment 1_000

  @type summary :: %{
          groups: non_neg_integer(),
          leases: non_neg_integer(),
          revoked: non_neg_integer(),
          scheduled: non_neg_integer(),
          dropped: non_neg_integer(),
          pushed: non_neg_integer(),
          withdrawn: non_neg_integer(),
          missed_offline: non_neg_integer(),
          missed_exhausted: non_neg_integer(),
          errors: non_neg_integer()
        }

  @type delivery :: %{
          required(:authority) => LeaseDelivery.authority(),
          required(:sender) => LeaseDelivery.sender(),
          optional(:refresh) => String.t()
        }

  @doc "The most slots one pass mints for one assignment."
  @spec max_new_slots_per_assignment() :: pos_integer()
  def max_new_slots_per_assignment, do: @max_new_slots_per_assignment

  @doc """
  Runs the pass over every sweep group.

  With a delivery context, each group is delivered and then deliveries whose assignment or
  group is gone are revoked. `delivery` overrides `delivery_context/0`.
  """
  @spec run(DateTime.t(), delivery() | nil) :: {:ok, summary()} | {:error, term()}
  def run(now \\ DateTime.utc_now(), delivery \\ :context)

  def run(%DateTime{} = now, :context), do: execute(now, delivery_context())

  def run(%DateTime{} = now, delivery), do: execute(now, delivery)

  @doc """
  Runs the pass over one sweep group. With a `delivery` context (the issuer authority and a
  sender, see `delivery_context/0`) it also pushes each agent the lease it is missing and
  withdraws the lease from agents the group no longer leases to; without one it only plans.
  `group` only names the group: the pass decides from the row as committed.
  """
  @spec reconcile_group(SweepGroup.t(), DateTime.t(), delivery() | nil) :: summary()
  def reconcile_group(%SweepGroup{} = group, now \\ DateTime.utc_now(), delivery \\ nil) do
    Map.delete(plan_group(group, now, delivery), :failed_groups)
  end

  # A group whose planning hit any error keeps its closed slots unmarked this pass:
  # a horizon that was not refilled would make an offline slot look exhausted.
  #
  # Selection and revocation run in one short transaction holding the group row, the row a
  # group update locks while it revokes. Each leased agent is then planned under its delivery
  # lock in a second such transaction, and delivered after it commits.
  defp plan_group(%SweepGroup{} = group, now, delivery) do
    summary =
      case select_group(group, now) do
        {:ok, :gone} ->
          empty()

        {:ok, {:leased, current, leased, revoked}} ->
          keep = Enum.map(leased, & &1.agent_id)

          Enum.reduce(
            leased,
            add(count_revoked(revoked, current), withdraw(current, keep, now, delivery)),
            fn agent, acc ->
              add(acc, lease_agent(current.id, agent.agent_id, now, delivery))
            end
          )

        {:ok, {:ineligible, current, revoked}} ->
          add(count_revoked(revoked, current), withdraw(current, [], now, delivery))

        {:error, {:profile, reason}} ->
          Logger.warning("Sweep lease pass: profile of group #{group.id}: #{inspect(reason)}")
          %{empty() | groups: 1, errors: 1}

        {:error, reason} ->
          skip_group(group, reason)
      end

    mark_failed(summary, group)
  rescue
    error ->
      Logger.error("Sweep lease pass failed for group #{group.id}: #{Exception.message(error)}")
      mark_failed(%{empty() | groups: 1, errors: 1}, group)
  end

  defp select_group(group, now) do
    Repo.transaction(fn ->
      case selection(group, now) do
        {:error, reason} -> Repo.rollback(reason)
        selected -> selected
      end
    end)
  end

  defp selection(group, now) do
    with {:ok, %SweepGroup{} = current} <- locked_group(group.id),
         {:ok, profile} <- group_profile(current) do
      case LeaseEligibility.evaluate_group(current, profile) do
        {:ok, inputs} ->
          with {:ok, leased} <- leased_agents(current, profile, inputs, now) do
            keep = Enum.map(leased, & &1.agent_id)
            {:leased, current, leased, ProducerAssignments.revoke_all_except(current.id, keep)}
          end

        {:error, _reason} ->
          {:ineligible, current, ProducerAssignments.revoke_all_except(current.id, [])}
      end
    else
      {:ok, nil} -> :gone
      {:error, reason} -> {:error, reason}
    end
  end

  # The group row as committed, read under `FOR UPDATE`. Every lease decision is made from it
  # rather than from the struct the caller read earlier.
  defp locked_group(group_id) do
    SweepGroup
    |> Ash.Query.filter(id == ^group_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(actor: actor())
  end

  defp group_profile(group) do
    case load_profile(group.profile_id) do
      {:ok, profile} -> {:ok, profile}
      {:error, reason} -> {:error, {:profile, reason}}
    end
  end

  defp leased_agents(group, profile, inputs, now) do
    with {:ok, candidates} <- LeaseAgents.candidates(group) do
      candidates
      |> Enum.reduce_while({:ok, []}, fn candidate, {:ok, acc} ->
        case leased_agent(group, profile, inputs, candidate, now) do
          {:leased, agent} -> {:cont, {:ok, [agent | acc]}}
          :not_leased -> {:cont, {:ok, acc}}
          {:failed, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, leased} -> {:ok, Enum.reverse(leased)}
        error -> error
      end
    end
  end

  defp mark_failed(%{errors: 0} = summary, _group), do: summary

  defp mark_failed(summary, group),
    do: %{summary | failed_groups: MapSet.put(summary.failed_groups, group.id)}

  @doc """
  Pushes `agent_id` a fresh full window of every group it holds an active assignment in, using
  `delivery`'s authority and sender. Only this agent is evaluated, planned and delivered: no
  other agent's assignment, slots or delivery is touched and nothing is withdrawn, so
  `delivery`'s sender may be the agent's own control session. An agent the group no longer
  leases to is left for the next pass to revoke. A new control session calls this: the agent
  cannot run authority it cached before core recorded issuance evidence, so an acknowledged
  delivery must not leave it waiting for the next tail.

  The refresh succeeds only when every group planned cleanly and every push reached the session.
  Without lease authority (`nil`), or when any group or push failed, it returns an error so the
  caller retries rather than leaving the acknowledged window unpushed.
  """
  @spec refresh_agent(String.t(), delivery() | nil, DateTime.t()) ::
          {:ok, summary()} | {:error, term()}
  def refresh_agent(agent_id, delivery, now \\ DateTime.utc_now())

  def refresh_agent(agent_id, nil, _now) when is_binary(agent_id),
    do: {:error, :lease_authority_unavailable}

  def refresh_agent(agent_id, %{authority: _, sender: _} = delivery, now)
      when is_binary(agent_id) do
    delivery = Map.put(delivery, :refresh, agent_id)

    with {:ok, assignments} <-
           SweepProducerAssignment
           |> Ash.Query.for_read(:active_for_agent, %{agent_id: agent_id}, actor: actor())
           |> Ash.read(actor: actor()) do
      summary =
        Enum.reduce(assignments, empty(), fn assignment, acc ->
          add(acc, lease_agent(assignment.sweep_group_id, agent_id, now, delivery))
        end)

      case Map.delete(summary, :failed_groups) do
        %{errors: 0} = summary -> {:ok, summary}
        %{errors: errors} -> {:error, {:lease_refresh_incomplete, errors}}
      end
    end
  end

  @doc """
  The delivery context of a pass: the issuer authority (`LeaseDelivery.authority/0`) and the
  control-stream sender, or `nil` when core issues no lease authority (no issuer key, or no
  active sweep contract), in which case leases are planned but not delivered.
  """
  @spec delivery_context() :: delivery() | nil
  def delivery_context do
    case LeaseDelivery.authority() do
      nil -> nil
      authority -> %{authority: authority, sender: &AgentCommandBus.push_sweep_lease/3}
    end
  end

  @doc """
  The lease id of an assignment at its current epoch: a UUID (version 8) made from the first
  16 bytes of SHA-256 over the assignment id and the epoch.
  """
  @spec lease_id(SweepProducerAssignment.t()) :: Ecto.UUID.t()
  def lease_id(%SweepProducerAssignment{id: id, authority_epoch: epoch}) do
    <<a::48, _::4, b::12, _::2, c::62, _::binary>> =
      :crypto.hash(
        :sha256,
        ["serviceradar.sweep.lease.v1", Ecto.UUID.dump!(id), <<epoch::unsigned-64>>]
      )

    Ecto.UUID.cast!(<<a::48, 8::4, b::12, 2::2, c::62>>)
  end

  @doc false
  @spec classify_lease(
          {:ok, term()} | {:error, term()},
          {:ok, map()} | {:error, term()} | :unread,
          LeaseSchedule.spec(),
          DateTime.t()
        ) ::
          {:leased, %{scope_id: term(), slots: [LeaseSchedule.slot()]}}
          | :not_leased
          | {:failed, term()}
  def classify_lease(scope, settings, schedule, now)

  def classify_lease({:error, :partition_not_found}, _settings, _schedule, _now), do: :not_leased

  def classify_lease({:error, reason}, _settings, _schedule, _now), do: {:failed, reason}

  def classify_lease({:ok, _scope_id}, {:error, reason}, _schedule, _now), do: {:failed, reason}

  def classify_lease({:ok, scope_id}, {:ok, %{horizon_seconds: horizon}}, schedule, now) do
    slots = desired_slots(schedule, now, horizon)

    if too_dense?(slots) do
      :not_leased
    else
      {:leased, %{scope_id: scope_id, slots: slots}}
    end
  end

  defp execute(now, delivery) do
    planned =
      with {:ok, groups} <- Ash.read(SweepGroup, actor: actor()) do
        {:ok,
         groups
         |> Enum.reduce(empty(), &add(&2, plan_group(&1, now, delivery)))
         |> add(orphan_withdrawals(now, delivery))}
      end

    finish(planned, now)
  end

  defp finish({:error, reason}, _now), do: {:error, reason}

  defp finish({:ok, planned}, now) do
    {skipped, planned} = failed_groups(planned)
    log_failed_groups(skipped)

    case LeaseMisses.mark(now, skipped) do
      {:ok, misses} ->
        {:ok, add(planned, misses)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp orphan_withdrawals(_now, nil), do: empty()

  defp orphan_withdrawals(now, %{sender: sender}) do
    case LeaseDelivery.withdraw_orphans(now, sender) do
      {:ok, count} ->
        %{empty() | withdrawn: count}

      {:error, reason} ->
        Logger.warning("Sweep lease pass: withdrawing orphaned leases: #{inspect(reason)}")
        %{empty() | errors: 1}
    end
  end

  defp skip_group(group, reason) do
    Logger.warning("Sweep lease pass: agents of group #{group.id}: #{inspect(reason)}")
    %{empty() | groups: 1, errors: 1}
  end

  defp leased_agent(group, profile, inputs, %{agent_id: agent_id} = candidate, now) do
    scope = ProducerAssignments.network_scope_id_for_partition(candidate.partition)

    settings =
      case scope do
        {:ok, scope_id} -> PipelineSettings.resolve(agent_id, scope_id)
        _ -> :unread
      end

    case classify_lease(scope, settings, inputs.schedule, now) do
      {:leased, window} ->
        agent_window(group, profile, inputs, candidate, window)

      decision ->
        warn_unresolved_partition(scope, group, candidate)
        decision
    end
  end

  # An agent reporting a partition that has no row stays on the status path. Nothing else
  # reports why, so say it here.
  defp warn_unresolved_partition({:error, :partition_not_found = reason}, group, candidate) do
    Logger.warning(
      "Sweep lease pass: group #{group.id} is not leased to #{candidate.agent_id} in partition " <>
        "#{candidate.partition}: #{inspect(reason)}"
    )
  end

  defp warn_unresolved_partition(_scope, _group, _candidate), do: :ok

  # The agent's own check set: what its delivered sweep config carries for the group.
  defp agent_window(group, profile, inputs, candidate, window) do
    case LeaseEligibility.agent_checks(group, profile, candidate.capabilities) do
      {:ok, checks} ->
        {:leased,
         window
         |> Map.put(:agent_id, candidate.agent_id)
         |> Map.put(:inputs, Map.merge(inputs, checks))}

      {:error, reason} ->
        Logger.debug(
          "Sweep lease pass: group #{group.id} is not leased to #{candidate.agent_id}: #{inspect(reason)}"
        )

        :not_leased
    end
  end

  # The pass and a refresh plan and deliver one agent's lease under the same cluster-wide
  # delivery lock, so neither reads delivery state, commits issuance or sends while the other
  # is mid-way. Under that lock a short transaction holds the group row while it decides from
  # the current group, profile, candidate and settings and assigns and plans the agent, so a
  # group update's revocation either commits first and the agent is skipped, or commits after
  # and fences the epoch planned here. Delivery runs after that transaction commits.
  defp lease_agent(group_id, agent_id, now, delivery) do
    LeaseDelivery.serialize(group_id, agent_id, fn ->
      case plan_agent(group_id, agent_id, now, mode(delivery)) do
        {:ok, {assignment, agent, planned}} ->
          add(planned, deliver(assignment, agent.inputs.checks, now, delivery))

        {:ok, :not_selected} ->
          empty()

        {:error, reason} ->
          lease_failed(group_id, agent_id, reason)
      end
    end)
  end

  defp mode(%{refresh: _}), do: :refresh
  defp mode(_delivery), do: :pass

  defp plan_agent(group_id, agent_id, now, mode) do
    Repo.transaction(fn ->
      with {:ok, group, agent} <- selected_agent(group_id, agent_id, now),
           {:ok, assignment} <- assignment_for(group, agent, mode),
           {:ok, unrun} <- ExecutionSlots.list_unrun(assignment.id, now) do
        {assignment, agent, sync_slots(assignment, agent.inputs, agent.slots, unrun)}
      else
        :not_selected -> :not_selected
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp selected_agent(group_id, agent_id, now) do
    with {:ok, %SweepGroup{} = group} <- locked_group(group_id),
         {:ok, profile} <- load_profile(group.profile_id),
         {:ok, inputs} <- eligible(group, profile),
         {:ok, candidates} <- LeaseAgents.candidates(group),
         %{} = candidate <- Enum.find(candidates, &(&1.agent_id == agent_id)),
         {:leased, agent} <- leased_agent(group, profile, inputs, candidate, now) do
      {:ok, group, agent}
    else
      {:failed, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      _gone_ineligible_or_not_leased -> :not_selected
    end
  end

  defp eligible(group, profile) do
    case LeaseEligibility.evaluate_group(group, profile) do
      {:ok, inputs} -> {:ok, inputs}
      {:error, _reason} -> :not_selected
    end
  end

  # A pass assigns a selected agent, reactivating it if it was revoked. A refresh only renews
  # an assignment that is still active in the agent's scope; it never creates or reactivates.
  defp assignment_for(group, agent, :pass),
    do: ProducerAssignments.ensure(group.id, agent.agent_id, agent.scope_id)

  defp assignment_for(group, agent, :refresh) do
    case ProducerAssignments.get(group.id, agent.agent_id) do
      {:ok, %SweepProducerAssignment{state: :active, network_scope_id: scope} = assignment}
      when scope == agent.scope_id ->
        {:ok, assignment}

      {:ok, _not_active} ->
        :not_selected

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lease_failed(group_id, agent_id, reason) do
    Logger.warning(
      "Sweep lease pass: lease of group #{group_id} on #{agent_id}: #{inspect(reason)}"
    )

    %{empty() | errors: 1}
  end

  defp deliver(_assignment, _checks, _now, nil), do: empty()

  defp deliver(assignment, checks, now, %{refresh: _} = delivery),
    do: push(assignment, checks, now, delivery, fresh: true)

  defp deliver(assignment, checks, now, delivery), do: push(assignment, checks, now, delivery, [])

  defp push(assignment, checks, now, %{authority: authority, sender: sender} = delivery, opts) do
    case LeaseDelivery.deliver(assignment, authority, now, sender, checks, opts) do
      {:ok, :pushed} ->
        %{empty() | pushed: 1}

      {:ok, {:not_delivered, reason}} when is_map_key(delivery, :refresh) ->
        Logger.warning(
          "Sweep lease refresh: sending the lease of #{assignment.id}: #{inspect(reason)}"
        )

        %{empty() | errors: 1}

      {:ok, _not_pushed} ->
        empty()

      {:error, reason} ->
        Logger.warning(
          "Sweep lease pass: delivering the lease of #{assignment.id}: #{inspect(reason)}"
        )

        %{empty() | errors: 1}
    end
  end

  defp withdraw(_group, _keep, _now, nil), do: empty()

  defp withdraw(group, keep, now, %{sender: sender}) do
    case LeaseDelivery.withdraw_except(group.id, keep, now, sender) do
      {:ok, count} ->
        %{empty() | withdrawn: count}

      {:error, reason} ->
        Logger.warning("Sweep lease pass: withdrawing leases of #{group.id}: #{inspect(reason)}")
        %{empty() | errors: 1}
    end
  end

  defp sync_slots(assignment, inputs, desired, unrun) do
    lease_id = lease_id(assignment)
    wanted = Map.new(desired, &{key(&1.start), &1})
    cidrs = planned_cidrs(inputs.targets)

    {keep, stale} =
      Enum.split_with(unrun, fn slot ->
        slot.authority_epoch == assignment.authority_epoch and
          slot.lease_id == lease_id and
          slot.network_scope_id == assignment.network_scope_id and
          slot.check_set_sha256 == inputs.check_set_sha256 and
          same_window?(wanted[key(slot.slot_start)], slot) and
          slot_cidrs(slot) == cidrs
      end)

    case ExecutionSlots.drop(Enum.map(stale, & &1.id)) do
      {:ok, dropped} -> fill(assignment, inputs, desired, keep, lease_id, dropped)
      {:error, _reason} -> %{empty() | errors: 1}
    end
  end

  defp same_window?(%{expires: expires}, slot),
    do: DateTime.compare(expires, slot.collection_expires) == :eq

  defp same_window?(nil, _slot), do: false

  defp planned_cidrs(targets) when is_list(targets) do
    case SweepPlan.canonical_targets(targets) do
      {:ok, cidrs} -> cidrs
      {:error, _} -> :unplannable
    end
  end

  defp planned_cidrs(_targets), do: :unplannable

  defp slot_cidrs(%{plan_pages: pages}) when is_list(pages) do
    pages
    |> Enum.reduce_while({:ok, []}, fn encoded, {:ok, acc} ->
      case page_cidrs(encoded) do
        {:ok, cidrs} -> {:cont, {:ok, [cidrs | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, chunks} -> chunks |> Enum.reverse() |> Enum.concat()
      :error -> :undecodable
    end
  end

  defp slot_cidrs(_slot), do: :undecodable

  defp page_cidrs(encoded) when is_binary(encoded) do
    page = ScheduledPlanPageV1.decode(encoded)
    {:ok, Enum.map(page.ranges, & &1.cidr)}
  rescue
    _ -> :error
  end

  defp page_cidrs(_encoded), do: :error

  defp fill(assignment, inputs, desired, keep, lease_id, dropped) do
    present = MapSet.new(keep, &key(&1.slot_start))

    opts = [
      targets: inputs.targets,
      check_set_sha256: inputs.check_set_sha256,
      lease_id: lease_id
    ]

    {scheduled, errors} =
      desired
      |> Enum.reject(&MapSet.member?(present, key(&1.start)))
      |> Enum.take(@max_new_slots_per_assignment)
      |> Enum.reduce({0, 0}, fn slot, {ok, failed} ->
        case ExecutionSlots.schedule(assignment, slot.start, slot.expires, opts) do
          {:ok, _slot} -> {ok + 1, failed}
          {:error, _reason} -> {ok, failed + 1}
        end
      end)

    %{empty() | leases: 1, scheduled: scheduled, dropped: dropped, errors: errors}
  end

  # The slots that start after `now` and before the end of the horizon.
  defp desired_slots(schedule, now, horizon) do
    schedule
    |> LeaseSchedule.slots(now, DateTime.shift(now, second: horizon))
    |> Enum.filter(&DateTime.after?(&1.start, now))
  end

  defp too_dense?(slots) do
    min = LeaseSchedule.min_interval_seconds()
    Enum.any?(slots, &(DateTime.diff(&1.expires, &1.start, :second) < min))
  end

  defp key(%DateTime{} = time), do: DateTime.to_unix(time, :microsecond)

  defp count_revoked({:ok, count}, _group), do: %{empty() | groups: 1, revoked: count}

  defp count_revoked({:error, reason}, group) do
    Logger.warning("Sweep lease pass: revoking leases of group #{group.id}: #{inspect(reason)}")
    %{empty() | groups: 1, errors: 1}
  end

  defp load_profile(nil), do: {:ok, nil}

  defp load_profile(id) do
    case Ash.get(SweepProfile, id, actor: actor()) do
      {:ok, profile} -> {:ok, profile}
      {:error, reason} -> profile_result(reason)
    end
  rescue
    error -> profile_result(error)
  end

  defp profile_result(reason) do
    if profile_missing?(reason), do: {:ok, nil}, else: {:error, reason}
  end

  defp profile_missing?(%NotFound{}), do: true

  defp profile_missing?(%Ash.Error.Invalid{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &profile_missing?/1)
  end

  defp profile_missing?(_reason), do: false

  defp empty,
    do: %{
      groups: 0,
      leases: 0,
      revoked: 0,
      scheduled: 0,
      dropped: 0,
      pushed: 0,
      withdrawn: 0,
      missed_offline: 0,
      missed_exhausted: 0,
      errors: 0,
      failed_groups: MapSet.new()
    }

  defp failed_groups(summary), do: Map.pop(summary, :failed_groups, MapSet.new())

  defp log_failed_groups(skipped) do
    if MapSet.size(skipped) > 0 do
      ids = skipped |> Enum.sort() |> Enum.join(", ")

      Logger.warning(
        "Sweep lease pass: planning failed for groups #{ids}; their closed slots stay unmarked this pass"
      )
    end
  end

  defp add(a, b) do
    Map.merge(a, b, fn
      :failed_groups, left, right -> MapSet.union(left, right)
      _key, left, right -> left + right
    end)
  end

  defp actor, do: SystemActor.system(:sweep_lease_pass)
end
