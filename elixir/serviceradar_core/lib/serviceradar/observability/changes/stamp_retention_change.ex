defmodule ServiceRadar.Observability.Changes.StampRetentionChange do
  @moduledoc false
  # Records who changed a warehouse retention setting and when, and marks the new value as not
  # yet applied so the page shows it pending until core's applier records the outcome.
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:updated_by, actor_name(context.actor))
    |> Ash.Changeset.force_change_attribute(:updated_at, DateTime.utc_now())
    |> Ash.Changeset.force_change_attribute(:last_applied_status, "pending")
    |> Ash.Changeset.force_change_attribute(:last_applied_error, nil)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  @doc false
  def actor_name(%{role: :system, id: id}), do: to_string(id)

  def actor_name(actor) when is_map(actor) do
    to_string(Map.get(actor, :email) || Map.get(actor, :id) || "unknown")
  end

  def actor_name(_actor), do: "unknown"
end
