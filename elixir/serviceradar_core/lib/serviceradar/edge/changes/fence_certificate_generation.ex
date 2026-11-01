defmodule ServiceRadar.Edge.Changes.FenceCertificateGeneration do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.filter(changeset,
      generation: Ash.Changeset.get_argument(changeset, :expected_generation)
    )
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
