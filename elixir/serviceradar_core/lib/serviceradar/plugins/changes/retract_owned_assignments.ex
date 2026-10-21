defmodule ServiceRadar.Plugins.Changes.RetractOwnedAssignments do
  @moduledoc """
  Retracts an owner's plugin assignments inside the owner's own action.

  Attached to the update and destroy actions of the two assignment owners,
  `NetworkCredentialRule` (`owner: :credential_rule`) and `PluginTargetPolicy`
  (`owner: :plugin_target_policy`):

    * a destroy retracts every enabled assignment of the owner
      (`owner_deleted`);
    * an update that disables the owner retracts every enabled assignment
      (`owner_disabled`);
    * an update of an enabled owner that changes what it covers (a rule's
      `scope_type`/`scope_value`, a policy's `input_definitions`) retracts the
      assignments of the agents it no longer covers (`owner_scope_narrowed`).

  The retraction runs as an `after_action` hook, so it shares the owner action's
  transaction: if it fails, the owner change rolls back too. Only the updated
  owner record is needed, never its prior state, so the hook works when the
  update runs atomically. See `ServiceRadar.Plugins.OwnedAssignmentRetraction`.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Plugins.OwnedAssignmentRetraction

  @coverage_fields %{
    credential_rule: [:scope_type, :scope_value],
    plugin_target_policy: [:input_definitions]
  }

  @impl true
  def change(changeset, opts, context) do
    case trigger(changeset, Keyword.fetch!(opts, :owner)) do
      nil -> changeset
      trigger -> add_hook(changeset, trigger, opts, context)
    end
  end

  @impl true
  def atomic(changeset, opts, context) do
    case trigger(changeset, Keyword.fetch!(opts, :owner)) do
      nil -> :ok
      trigger -> {:ok, add_hook(changeset, trigger, opts, context)}
    end
  end

  defp add_hook(changeset, trigger, opts, context) do
    owner_kind = Keyword.fetch!(opts, :owner)
    actor = Map.get(context, :actor)

    Ash.Changeset.after_action(changeset, fn _changeset, owner ->
      case retract(owner_kind, trigger, owner, actor) do
        {:ok, notifications} -> {:ok, owner, notifications}
        {:error, error} -> {:error, error}
      end
    end)
  end

  defp trigger(%{action_type: :destroy}, _owner_kind), do: :deleted

  defp trigger(changeset, owner_kind) do
    enabled_changed? = Ash.Changeset.changing_attribute?(changeset, :enabled)

    coverage_changed? =
      Enum.any?(@coverage_fields[owner_kind], &Ash.Changeset.changing_attribute?(changeset, &1))

    cond do
      coverage_changed? -> :coverage_changed
      enabled_changed? -> :enabled_changed
      true -> nil
    end
  end

  defp retract(owner_kind, :deleted, owner, actor),
    do:
      OwnedAssignmentRetraction.retract_owner_assignments(
        owner_kind,
        owner,
        :owner_deleted,
        actor
      )

  defp retract(owner_kind, _trigger, %{enabled: false} = owner, actor),
    do:
      OwnedAssignmentRetraction.retract_owner_assignments(
        owner_kind,
        owner,
        :owner_disabled,
        actor
      )

  defp retract(owner_kind, :coverage_changed, owner, actor),
    do: OwnedAssignmentRetraction.retract_uncovered(owner_kind, owner, actor)

  # Enabled, or left enabled, with no change to what it covers.
  defp retract(_owner_kind, :enabled_changed, _owner, _actor), do: {:ok, []}
end
