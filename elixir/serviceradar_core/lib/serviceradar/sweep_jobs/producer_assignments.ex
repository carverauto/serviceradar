defmodule ServiceRadar.SweepJobs.ProducerAssignments do
  @moduledoc """
  Reads and moves the edge-record authority of sweep groups: one
  `ServiceRadar.SweepJobs.SweepProducerAssignment` per (sweep group, agent).

  The authority epoch is the fence the gateway compares each record against, so
  every change of who may produce a group's records goes through here:

    * `ensure/3` returns an active assignment, creating it or reissuing it
      under a new epoch when it was revoked or its network scope changed;
    * `bump_group/2` fences the assignments of a group after its targets change;
    * `revoke_agents/2` and `revoke_all_except/2` fence agents that no longer
      run the group and withdraw their slots that have not started.

  Only the system actor writes; the epoch moves by an atomic database update, so
  concurrent changes never repeat or lower it.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.SweepJobs.ExecutionSlots
  alias ServiceRadar.SweepJobs.SweepProducerAssignment

  require Ash.Query

  @type assignment :: SweepProducerAssignment.t()

  @doc """
  The network scope of a partition: its id. One spool carries exactly one scope,
  so an agent's records are written under its own partition.
  """
  @spec network_scope_id_for_partition(String.t()) ::
          {:ok, Ecto.UUID.t()} | {:error, :partition_not_found | term()}
  def network_scope_id_for_partition(slug) when is_binary(slug) do
    case Partition.get_by_slug(slug, actor: actor()) do
      {:ok, %{id: id}} -> {:ok, id}
      {:error, %Ash.Error.Invalid{}} -> {:error, :partition_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The assignment of a sweep group on an agent, or `nil`.
  """
  @spec get(Ecto.UUID.t(), String.t()) :: {:ok, assignment() | nil} | {:error, term()}
  def get(sweep_group_id, agent_id) do
    SweepProducerAssignment
    |> Ash.Query.filter(sweep_group_id == ^sweep_group_id and agent_id == ^agent_id)
    |> Ash.read_one(actor: actor())
  end

  @doc "Every assignment of a sweep group, revoked ones included."
  @spec list_for_group(Ecto.UUID.t()) :: {:ok, [assignment()]} | {:error, term()}
  def list_for_group(sweep_group_id) do
    SweepProducerAssignment
    |> Ash.Query.for_read(:for_group, %{sweep_group_id: sweep_group_id}, actor: actor())
    |> Ash.read(actor: actor())
  end

  @doc """
  An active assignment of the group on the agent under `network_scope_id`.

  An existing active assignment with the same scope is returned unchanged, so
  calling this again never moves the epoch. A revoked one, or one whose scope
  differs (the agent moved to another partition), is reissued under a new epoch.
  """
  @spec ensure(Ecto.UUID.t(), String.t(), Ecto.UUID.t()) ::
          {:ok, assignment()} | {:error, term()}
  def ensure(sweep_group_id, agent_id, network_scope_id) do
    with {:ok, existing} <- get(sweep_group_id, agent_id) do
      ensure_existing(existing, sweep_group_id, agent_id, network_scope_id)
    end
  end

  defp ensure_existing(nil, sweep_group_id, agent_id, network_scope_id) do
    attrs = %{
      sweep_group_id: sweep_group_id,
      agent_id: agent_id,
      network_scope_id: network_scope_id
    }

    case SweepProducerAssignment
         |> Ash.Changeset.for_create(:create, attrs, actor: actor())
         |> Ash.create() do
      {:ok, assignment} ->
        {:ok, assignment}

      {:error, error} ->
        # A concurrent ensure won the unique (group, agent) row: use it.
        case get(sweep_group_id, agent_id) do
          {:ok, %SweepProducerAssignment{} = existing} ->
            ensure_existing(existing, sweep_group_id, agent_id, network_scope_id)

          _ ->
            {:error, error}
        end
    end
  end

  defp ensure_existing(
         %SweepProducerAssignment{state: :active, network_scope_id: scope} = assignment,
         _sweep_group_id,
         _agent_id,
         scope
       ),
       do: {:ok, assignment}

  defp ensure_existing(%SweepProducerAssignment{} = assignment, _group, _agent, network_scope_id) do
    assignment
    |> Ash.Changeset.for_update(:reactivate, %{network_scope_id: network_scope_id},
      actor: actor()
    )
    |> Ash.update()
  end

  @doc """
  Fences the active assignments of a group under a new epoch, after a change
  that alters what its agents are authorized to sweep. Returns how many moved.
  """
  @spec bump_group(Ecto.UUID.t(), :target_changed | :manual) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def bump_group(sweep_group_id, reason \\ :target_changed) do
    SweepProducerAssignment
    |> Ash.Query.filter(sweep_group_id == ^sweep_group_id and state == :active)
    |> bulk(:bump_epoch, %{reason: reason})
  end

  @doc """
  Revokes the assignments of the given agents in a group and withdraws their unrun slots.
  Returns how many assignments were revoked.
  """
  @spec revoke_agents(Ecto.UUID.t(), [String.t()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def revoke_agents(_sweep_group_id, []), do: {:ok, 0}

  def revoke_agents(sweep_group_id, agent_ids) when is_list(agent_ids) do
    revoked =
      SweepProducerAssignment
      |> Ash.Query.filter(
        sweep_group_id == ^sweep_group_id and state == :active and agent_id in ^agent_ids
      )
      |> bulk(:revoke, %{})

    with {:ok, count} <- revoked,
         {:ok, _slots} <- ExecutionSlots.drop_unrun(sweep_group_id, {:only, agent_ids}) do
      {:ok, count}
    end
  end

  @doc """
  Revokes every active assignment of the group whose agent is not in `keep`,
  and withdraws the unrun slots of every other agent.
  """
  @spec revoke_all_except(Ecto.UUID.t(), [String.t()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def revoke_all_except(sweep_group_id, keep) when is_list(keep) do
    revoked =
      SweepProducerAssignment
      |> Ash.Query.filter(
        sweep_group_id == ^sweep_group_id and state == :active and agent_id not in ^keep
      )
      |> bulk(:revoke, %{})

    with {:ok, count} <- revoked,
         {:ok, _slots} <- ExecutionSlots.drop_unrun(sweep_group_id, {:except, keep}) do
      {:ok, count}
    end
  end

  defp bulk(query, action, input) do
    case Ash.bulk_update(query, action, input,
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

  defp actor, do: SystemActor.system(:sweep_producer_assignments)
end
