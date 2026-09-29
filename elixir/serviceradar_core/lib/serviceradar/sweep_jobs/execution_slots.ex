defmodule ServiceRadar.SweepJobs.ExecutionSlots do
  @moduledoc """
  Mints and withdraws the pre-minted executions of a schedule lease.

  `schedule/4` mints an execution id whose UUIDv7 time is the slot start, builds the plan
  that execution binds (`ServiceRadar.Edge.SweepPlan`) and stores both, so the source
  authorization core signs later names an execution and a plan that already exist.
  `drop_unrun/2` withdraws the slots that have not started when their agent is revoked.
  Only the system actor writes.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.SweepPlan
  alias Serviceradar.Edge.V1.ScheduledPlanHeaderV1
  alias Serviceradar.Edge.V1.ScheduledPlanPageV1
  alias ServiceRadar.SweepJobs.SweepExecutionSlot
  alias ServiceRadar.SweepJobs.SweepProducerAssignment

  require Ash.Query

  @doc """
  A UUIDv7 whose timestamp is `time`: 48 bits of Unix milliseconds, then random bits.
  """
  @spec mint_id(DateTime.t()) :: Ecto.UUID.t()
  def mint_id(%DateTime{} = time), do: time |> mint_binary() |> Ecto.UUID.cast!()

  defp mint_binary(%DateTime{} = time) do
    <<rand_a::12, rand_b::62, _::6>> = :crypto.strong_rand_bytes(10)
    ms = DateTime.to_unix(time, :millisecond)
    <<ms::48, 7::4, rand_a::12, 2::2, rand_b::62>>
  end

  @doc """
  Records one execution of the assignment's lease starting at `slot_start`.

  Options: `:targets` (the group's static targets), `:check_set_sha256` (32 bytes) and
  `:lease_id` (the lease's UUID). The plan is built from the targets; a target the plan
  cannot carry is an error and no slot.
  """
  @spec schedule(SweepProducerAssignment.t(), DateTime.t(), DateTime.t(), keyword()) ::
          {:ok, SweepExecutionSlot.t()} | {:error, term()}
  def schedule(%SweepProducerAssignment{} = assignment, slot_start, collection_expires, opts) do
    if DateTime.after?(collection_expires, slot_start) do
      build_and_create(assignment, slot_start, collection_expires, opts)
    else
      {:error, :invalid_window}
    end
  end

  defp build_and_create(assignment, slot_start, collection_expires, opts) do
    targets = Keyword.fetch!(opts, :targets)
    check_set = Keyword.fetch!(opts, :check_set_sha256)
    plan_id = mint_binary(slot_start)

    with {:ok, %{header: header, pages: pages}} <-
           SweepPlan.build(targets,
             plan_id: plan_id,
             network_scope_id: Ecto.UUID.dump!(assignment.network_scope_id),
             check_set_sha256: check_set
           ) do
      attrs = %{
        id: mint_id(slot_start),
        sweep_group_id: assignment.sweep_group_id,
        agent_id: assignment.agent_id,
        producer_assignment_id: assignment.id,
        network_scope_id: assignment.network_scope_id,
        authority_epoch: assignment.authority_epoch,
        lease_id: Keyword.fetch!(opts, :lease_id),
        slot_start: slot_start,
        collection_expires: collection_expires,
        plan_id: Ecto.UUID.cast!(plan_id),
        plan_sha256: header.execution_plan_sha256,
        check_set_sha256: check_set,
        plan_header: ScheduledPlanHeaderV1.encode(header),
        plan_pages: Enum.map(pages, &ScheduledPlanPageV1.encode/1)
      }

      SweepExecutionSlot
      |> Ash.Changeset.for_create(:schedule, attrs, actor: actor())
      |> Ash.create()
    end
  end

  @doc """
  Withdraws the slots of a group that have not started: `{:only, agent_ids}` for those
  agents, or `{:except, agent_ids}` for every agent but them. Returns how many.
  """
  @spec drop_unrun(Ecto.UUID.t(), {:only | :except, [String.t()]}, DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def drop_unrun(sweep_group_id, agents, now \\ DateTime.utc_now())

  def drop_unrun(_sweep_group_id, {:only, []}, _now), do: {:ok, 0}

  def drop_unrun(sweep_group_id, {which, agent_ids}, now) when which in [:only, :except] do
    unrun =
      Ash.Query.filter(
        SweepExecutionSlot,
        sweep_group_id == ^sweep_group_id and state == :scheduled and slot_start > ^now
      )

    unrun
    |> restrict(which, agent_ids)
    |> bulk_drop()
  end

  defp restrict(query, :only, agent_ids), do: Ash.Query.filter(query, agent_id in ^agent_ids)

  defp restrict(query, :except, agent_ids),
    do: Ash.Query.filter(query, agent_id not in ^agent_ids)

  defp bulk_drop(query) do
    case Ash.bulk_update(query, :drop, %{},
           actor: actor(),
           strategy: [:atomic, :stream],
           return_records?: true,
           return_errors?: true
         ) do
      %Ash.BulkResult{status: :success, records: records} -> {:ok, length(records || [])}
      %Ash.BulkResult{errors: [error | _]} -> {:error, error}
      %Ash.BulkResult{} -> {:error, :bulk_update_failed}
    end
  end

  @doc "The slots of a group, soonest first."
  @spec list_for_group(Ecto.UUID.t()) :: {:ok, [SweepExecutionSlot.t()]} | {:error, term()}
  def list_for_group(sweep_group_id) do
    SweepExecutionSlot
    |> Ash.Query.filter(sweep_group_id == ^sweep_group_id)
    |> Ash.Query.sort(slot_start: :asc)
    |> Ash.read(actor: actor())
  end

  defp actor, do: SystemActor.system(:sweep_execution_slots)
end
