defmodule ServiceRadar.Edge.DirectLeafAccessProvisioner do
  @moduledoc """
  System-only application entry points for issuing and revoking direct-leaf
  identities on add-on assignments.

  Keeping the action invocation here gives Oban workers, maintenance tasks,
  and future leaf-authorization reconciliation one audited path. Callers do
  not receive or handle NATS account seeds; the assignment action stores only
  encrypted mTLS PEM material.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonAssignment

  require Ash.Query

  @spec issue(binary(), keyword()) :: {:ok, AddonAssignment.t()} | {:error, term()}
  def issue(assignment_id, opts \\ []) when is_binary(assignment_id) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:direct_leaf_access_provisioner))
    validity_days = Keyword.get(opts, :validity_days, 30)

    with {:ok, assignment} <- fetch_assignment(assignment_id, actor) do
      changeset =
        Ash.Changeset.for_update(
          assignment,
          :issue_direct_access,
          %{validity_days: validity_days},
          actor: actor
        )

      Ash.update(changeset)
    end
  end

  @spec revoke(binary(), keyword()) :: {:ok, AddonAssignment.t()} | {:error, term()}
  def revoke(assignment_id, opts \\ []) when is_binary(assignment_id) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:direct_leaf_access_provisioner))
    reason = Keyword.get(opts, :reason, "direct leaf access revoked")

    with {:ok, assignment} <- fetch_assignment(assignment_id, actor) do
      changeset =
        Ash.Changeset.for_update(assignment, :revoke_direct_access, %{reason: reason},
          actor: actor
        )

      Ash.update(changeset)
    end
  end

  @spec mark_ready(binary(), non_neg_integer(), keyword()) ::
          {:ok, AddonAssignment.t()} | {:error, term()}
  def mark_ready(assignment_id, generation, opts \\ []) when is_binary(assignment_id) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:direct_leaf_access_provisioner))

    with {:ok, assignment} <- fetch_assignment(assignment_id, actor) do
      changeset =
        Ash.Changeset.for_update(
          assignment,
          :mark_direct_access_ready,
          %{generation: generation},
          actor: actor
        )

      Ash.update(changeset)
    end
  end

  defp fetch_assignment(assignment_id, actor) do
    AddonAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^assignment_id)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} -> {:error, :addon_assignment_not_found}
      {:ok, assignment} -> {:ok, assignment}
      {:error, reason} -> {:error, reason}
    end
  end
end
