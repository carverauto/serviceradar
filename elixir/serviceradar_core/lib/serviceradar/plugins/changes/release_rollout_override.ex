defmodule ServiceRadar.Plugins.Changes.ReleaseRolloutOverride do
  @moduledoc """
  Releases Wasm plugin rollouts' hold on an assignment that is being disabled.

  A rollout proves its candidate on an assignment through the override columns
  (`rollout_plugin_package_id`, `rollout_id`, `rollout_started_at`), and its
  target row for the assignment holds the assignment's rollout slot. Owners and
  reconcilers never write the override columns, so a disable that left them set
  would leave a disabled row pointing at a candidate, and a target waiting on an
  assignment that will never report again, or a pending target that would later
  put an override on a disabled row.

  When an update disables an assignment, this change clears its override in
  that same update and, in the same transaction, cancels every Wasm rollout
  target still holding the assignment, with the reason code
  `assignment_retracted`. The target's `error` records the assignment's
  `disabled_reason` when the update sets one (an owner retraction does). The
  coordinator then treats the target as finished, like one whose assignment was
  deleted.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonRolloutTarget

  require Ash.Query

  @override_fields [:rollout_plugin_package_id, :rollout_id, :rollout_started_at]

  # Keep in sync with AddonRolloutCoordinator's @slot_holding_target_states.
  @slot_holding_target_states [
    :pending,
    :waiting_health,
    :healthy_soak,
    :succeeded,
    :rollback_pending
  ]

  @impl true
  def change(changeset, _opts, _context) do
    if disabling?(changeset) do
      changeset
      |> clear_override()
      |> Ash.Changeset.after_action(fn _changeset, assignment ->
        case cancel_holding_targets(assignment) do
          :ok -> {:ok, assignment}
          {:error, reason} -> {:error, reason}
        end
      end)
    else
      changeset
    end
  end

  # Whether the row is being disabled depends on its stored state, which an
  # atomic update does not have.
  @impl true
  def atomic(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :enabled) do
      {:not_atomic, "releasing rollout holds needs the stored enabled state"}
    else
      :ok
    end
  end

  defp disabling?(%{data: %{enabled: true}} = changeset),
    do: Ash.Changeset.get_attribute(changeset, :enabled) == false

  defp disabling?(_changeset), do: false

  defp clear_override(%{data: %{rollout_id: nil}} = changeset), do: changeset

  defp clear_override(changeset) do
    Enum.reduce(@override_fields, changeset, &Ash.Changeset.force_change_attribute(&2, &1, nil))
  end

  defp cancel_holding_targets(assignment) do
    actor = SystemActor.system(:plugin_rollout_override_release)

    AddonRolloutTarget
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      artifact_kind == :wasm_plugin and plugin_assignment_id == ^assignment.id and
        state in ^@slot_holding_target_states
    )
    |> Ash.read(actor: actor)
    |> case do
      {:ok, targets} ->
        Enum.reduce_while(targets, :ok, fn target, :ok ->
          case cancel_target(target, assignment, actor) do
            {:ok, _target} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cancel_target(target, assignment, actor) do
    target
    |> Ash.Changeset.for_update(:update, %{
      state: :canceled,
      reason_code: "assignment_retracted",
      error: disabled_reason(assignment),
      completed_at: DateTime.utc_now()
    })
    |> Ash.update(actor: actor, authorize?: true)
  end

  defp disabled_reason(%{disabled_reason: nil}), do: nil
  defp disabled_reason(%{disabled_reason: reason}), do: to_string(reason)
end
