defmodule ServiceRadar.Plugins.Changes.RollBackRevokedCandidate do
  @moduledoc """
  Rolls back every active Wasm plugin rollout whose candidate is the package
  being revoked.

  A revoked package is no longer distributable, but a rollout's overrides would
  keep naming it as the package its targets run. The rollback runs in the
  revoke's own transaction: it clears every override the rollout holds and moves
  the rollout to `:rolling_back` with the reason `candidate_revoked`, so the
  package is never revoked while an assignment still points at it. If the
  rollback fails, the revoke fails with it. The rollback's config notifications
  are handed back to the revoke, which sends them once it commits.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonRollout
  alias ServiceRadar.Plugins.AddonRolloutCoordinator

  require Ash.Query

  # Keep in sync with AddonRolloutCoordinator's @active_rollout_states.
  @active_rollout_states [:pending, :running, :paused, :rolling_back]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, package ->
      case roll_back_rollouts_of(package) do
        {:ok, notifications} -> {:ok, package, notifications}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp roll_back_rollouts_of(package) do
    actor = SystemActor.system(:plugin_candidate_revoke_rollback)

    AddonRollout
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      artifact_kind == :wasm_plugin and candidate_plugin_package_id == ^package.id and
        state in ^@active_rollout_states
    )
    |> Ash.read(actor: actor)
    |> case do
      {:ok, rollouts} ->
        Enum.reduce_while(rollouts, {:ok, []}, fn rollout, {:ok, notifications} = acc ->
          case AddonRolloutCoordinator.rollback(rollout.id,
                 actor: actor,
                 reason: :candidate_revoked,
                 return_notifications?: true
               ) do
            {:ok, rolled_back} ->
              {:cont, {:ok, notifications ++ rolled_back}}

            {:error, :rollout_not_active} ->
              {:cont, acc}

            {:error, reason} ->
              {:halt, {:error, {:candidate_rollback_failed, rollout.id, reason}}}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
