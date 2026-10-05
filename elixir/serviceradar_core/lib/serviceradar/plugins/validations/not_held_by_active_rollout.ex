defmodule ServiceRadar.Plugins.Validations.NotHeldByActiveRollout do
  @moduledoc """
  Refuses to destroy an add-on assignment or profile that an active rollout
  still holds.

  A finished rollout's history survives the delete: `addon_rollout_targets`
  clears its `assignment_id` (`ON DELETE SET NULL`). An active rollout cannot
  lose its source the same way. Its targets still carry candidate overrides and
  slot-holding states, and `AddonRolloutCoordinator` would pause it on the
  missing source, leaving the agents' target slots held. So the operator gets a
  real error that names the rollout instead, and cancels it first.

  Pass `source_type: :assignment` or `source_type: :profile`.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonRollout
  alias ServiceRadar.Plugins.AddonRolloutTarget

  require Ash.Query

  # Keep in sync with AddonRolloutCoordinator's @active_rollout_states and
  # @slot_holding_target_states.
  @active_rollout_states [:pending, :running, :paused, :rolling_back]
  @slot_holding_target_states [
    :pending,
    :waiting_health,
    :healthy_soak,
    :succeeded,
    :rollback_pending
  ]

  @impl true
  def init(opts) do
    if opts[:source_type] in [:assignment, :profile] do
      {:ok, opts}
    else
      {:error, "source_type must be :assignment or :profile"}
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "active rollout validation requires a cross-table read"}

  @impl true
  def validate(changeset, opts, _context) do
    case check(opts[:source_type], Map.get(changeset.data, :id)) do
      :ok -> :ok
      {:error, message} -> {:error, field: :id, message: message}
    end
  end

  @doc """
  Returns `:ok` when nothing active holds the source, or `{:error, message}`.

  Callers that delete several rows for one source (a profile and its
  assignments) call this before deleting anything, so a refusal does not leave
  the source half-deleted.
  """
  @spec check(:assignment | :profile, Ecto.UUID.t() | nil) :: :ok | {:error, String.t()}
  def check(_source_type, nil), do: :ok

  def check(source_type, id) do
    actor = SystemActor.system(:addon_rollout_delete_guard)

    with {:ok, nil} <- active_rollout_for_source(source_type, id, actor),
         {:ok, nil} <- holding_target(source_type, id, actor) do
      :ok
    else
      {:ok, %AddonRollout{} = rollout} ->
        {:error, active_message(source_type, rollout.id, rollout.state)}

      {:ok, %AddonRolloutTarget{} = target} ->
        {:error, active_message(source_type, target.rollout_id, target.state)}

      {:error, _reason} ->
        {:error, "could not check #{label(source_type)} for active rollouts"}
    end
  end

  defp active_rollout_for_source(source_type, id, actor) do
    AddonRollout
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      source_type == ^source_type and source_id == ^id and state in ^@active_rollout_states
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(actor: actor)
  end

  # A profile rollout targets the profile's assignments, so the profile-level
  # rollout check already covers them; only an assignment can be held directly.
  defp holding_target(:profile, _id, _actor), do: {:ok, nil}

  defp holding_target(:assignment, id, actor) do
    AddonRolloutTarget
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(assignment_id == ^id and state in ^@slot_holding_target_states)
    |> Ash.Query.limit(1)
    |> Ash.read_one(actor: actor)
  end

  defp active_message(source_type, rollout_id, state) do
    "#{label(source_type)} is held by active rollout #{rollout_id} (#{state}); " <>
      "cancel the rollout before removing it"
  end

  defp label(:assignment), do: "add-on assignment"
  defp label(:profile), do: "add-on profile"
end
