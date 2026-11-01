defmodule ServiceRadar.Edge.Changes.StampCertificateActor do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, context) do
    Ash.Changeset.force_change_attribute(
      changeset,
      Keyword.fetch!(opts, :attribute),
      Map.get(context.actor || %{}, :id)
    )
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
