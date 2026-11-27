defmodule ServiceRadar.Inventory.Changes.NormalizeInterfaceEgressConfig do
  @moduledoc """
  Normalizes manual Internet egress settings on `InterfaceSettings` (trims blank
  `egress_vantage_id` values to `nil`).
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.fetch_change(changeset, :egress_vantage_id) do
      {:ok, value} when is_binary(value) ->
        trimmed = String.trim(value)

        Ash.Changeset.force_change_attribute(
          changeset,
          :egress_vantage_id,
          if(trimmed == "", do: nil, else: trimmed)
        )

      _ ->
        changeset
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
