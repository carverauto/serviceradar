defmodule ServiceRadar.SweepJobs.LeasePass do
  @moduledoc """
  Keeps every sweep schedule lease matching its group, its agents and the operator settings.

  For each group the pass decides who holds a lease and what its unrun slots are:

    * a group that is not eligible (`ServiceRadar.SweepJobs.LeaseEligibility`) holds no lease:
      every active assignment is revoked, which drops its unrun slots and returns the agents to
      their local ticker;
    * an agent the group no longer runs on (`ServiceRadar.SweepJobs.LeaseAgents`), or for which
      leasing is off (`ServiceRadar.SweepJobs.LeaseSettings`), is revoked the same way;
    * every other agent holds an active assignment (`ProducerAssignments.ensure/3`) whose unrun
      slots are exactly the schedule's slots between now and the agent's horizon, planned under
      the assignment's current epoch, check set and targets.

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
  part-way through, converges on the same slots. With no leasing enabled and no active
  assignment it reads nothing else.
  """

  alias Ash.Error.Query.NotFound
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.SweepPlan
  alias ServiceRadar.SweepJobs.ExecutionSlots
  alias ServiceRadar.SweepJobs.LeaseAgents
  alias ServiceRadar.SweepJobs.LeaseEligibility
  alias ServiceRadar.SweepJobs.LeaseSchedule
  alias ServiceRadar.SweepJobs.LeaseSettings
  alias ServiceRadar.SweepJobs.ProducerAssignments
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepLeaseSetting
  alias ServiceRadar.SweepJobs.SweepProducerAssignment
  alias ServiceRadar.SweepJobs.SweepProfile
  alias Serviceradar.Edge.V1.ScheduledPlanPageV1

  require Ash.Query
  require Logger

  @max_new_slots_per_assignment 1_000

  @type summary :: %{
          groups: non_neg_integer(),
          leases: non_neg_integer(),
          revoked: non_neg_integer(),
          scheduled: non_neg_integer(),
          dropped: non_neg_integer(),
          errors: non_neg_integer()
        }

  @doc "The most slots one pass mints for one assignment."
  @spec max_new_slots_per_assignment() :: pos_integer()
  def max_new_slots_per_assignment, do: @max_new_slots_per_assignment

  @doc "Runs the pass over every sweep group."
  @spec run(DateTime.t()) :: {:ok, summary() | :idle} | {:error, term()}
  def run(now \\ DateTime.utc_now()) do
    with {:ok, true} <- active?(),
         {:ok, groups} <- Ash.read(SweepGroup, actor: actor()) do
      {:ok, Enum.reduce(groups, empty(), &add(&2, reconcile_group(&1, now)))}
    else
      {:ok, false} -> {:ok, :idle}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Runs the pass over one sweep group."
  @spec reconcile_group(SweepGroup.t(), DateTime.t()) :: summary()
  def reconcile_group(%SweepGroup{} = group, now \\ DateTime.utc_now()) do
    case load_profile(group.profile_id) do
      {:ok, profile} ->
        lease_or_revoke(group, profile, now)

      {:error, reason} ->
        Logger.warning("Sweep lease pass: profile of group #{group.id}: #{inspect(reason)}")
        %{empty() | groups: 1, errors: 1}
    end
  rescue
    error ->
      Logger.error("Sweep lease pass failed for group #{group.id}: #{Exception.message(error)}")
      %{empty() | groups: 1, errors: 1}
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

  # Leasing is enabled somewhere, or an assignment is still active and may need revoking.
  defp active? do
    with {:ok, enabled} <-
           SweepLeaseSetting
           |> Ash.Query.filter(leasing_enabled == true)
           |> Ash.exists(actor: actor()),
         {:ok, assigned} <-
           SweepProducerAssignment
           |> Ash.Query.filter(state == :active)
           |> Ash.exists(actor: actor()) do
      {:ok, enabled or assigned}
    end
  end

  defp lease_group(group, inputs, now) do
    case LeaseAgents.candidates(group) do
      {:ok, candidates} ->
        leased = Enum.flat_map(candidates, &leased_agent(&1, inputs.schedule, now))
        revoked = ProducerAssignments.revoke_all_except(group.id, Enum.map(leased, & &1.agent_id))

        Enum.reduce(leased, count_revoked(revoked, group), fn agent, acc ->
          add(acc, lease_agent(group, inputs, agent, now))
        end)

      {:error, reason} ->
        Logger.warning("Sweep lease pass: agents of group #{group.id}: #{inspect(reason)}")
        %{empty() | groups: 1, errors: 1}
    end
  end

  # The agent's lease window, or nothing when it holds no lease: leasing is off for it, its
  # partition is unknown, or the schedule is too dense over its horizon.
  defp leased_agent(%{agent_id: agent_id, partition: partition}, schedule, now) do
    with {:ok, scope_id} <- ProducerAssignments.network_scope_id_for_partition(partition),
         {:ok, %{enabled?: true, horizon_seconds: horizon}} <-
           LeaseSettings.resolve(agent_id, scope_id),
         slots = desired_slots(schedule, now, horizon),
         false <- too_dense?(slots) do
      [%{agent_id: agent_id, scope_id: scope_id, slots: slots}]
    else
      _ -> []
    end
  end

  defp lease_agent(group, inputs, agent, now) do
    with {:ok, assignment} <- ProducerAssignments.ensure(group.id, agent.agent_id, agent.scope_id),
         {:ok, unrun} <- ExecutionSlots.list_unrun(assignment.id, now) do
      sync_slots(assignment, inputs, agent.slots, unrun)
    else
      {:error, reason} ->
        Logger.warning(
          "Sweep lease pass: lease of group #{group.id} on #{agent.agent_id}: #{inspect(reason)}"
        )

        %{empty() | errors: 1}
    end
  end

  defp lease_or_revoke(group, profile, now) do
    case LeaseEligibility.evaluate(group, profile) do
      {:ok, inputs} ->
        lease_group(group, inputs, now)

      {:error, _reason} ->
        count_revoked(ProducerAssignments.revoke_all_except(group.id, []), group)
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
    targets
    |> Enum.reduce_while([], fn target, acc ->
      case SweepPlan.canonical_target(to_string(target)) do
        {:ok, canonical} -> {:cont, [canonical | acc]}
        {:error, _} -> {:halt, :error}
      end
    end)
    |> case do
      :error ->
        :unplannable

      canonical ->
        canonical
        |> Enum.uniq_by(& &1.cidr)
        |> Enum.sort_by(& &1.order)
        |> Enum.map(& &1.cidr)
    end
  end

  defp planned_cidrs(_targets), do: :unplannable

  defp slot_cidrs(%{plan_pages: pages}) when is_list(pages) do
    Enum.reduce_while(pages, {:ok, []}, fn encoded, {:ok, acc} ->
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
    |> LeaseSchedule.slots(now, DateTime.add(now, horizon, :second))
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

  defp empty, do: %{groups: 0, leases: 0, revoked: 0, scheduled: 0, dropped: 0, errors: 0}

  defp add(a, b), do: Map.merge(a, b, fn _key, x, y -> x + y end)

  defp actor, do: SystemActor.system(:sweep_lease_pass)
end
