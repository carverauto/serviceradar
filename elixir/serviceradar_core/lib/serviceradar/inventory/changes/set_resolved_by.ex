defmodule ServiceRadar.Inventory.Changes.SetResolvedBy do
  @moduledoc false
  # Stamps who resolved a de-duplication task: a system actor's id ("system:<component>"), or a
  # user's email, or its id.
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.force_change_attribute(changeset, :resolved_by, actor_name(context.actor))
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
