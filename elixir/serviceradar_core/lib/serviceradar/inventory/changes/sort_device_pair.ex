defmodule ServiceRadar.Inventory.Changes.SortDevicePair do
  @moduledoc false
  # Stores a distinct-device pair in one canonical order, so {a, b} and {b, a} are one row.
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    a = Ash.Changeset.get_attribute(changeset, :device_a)
    b = Ash.Changeset.get_attribute(changeset, :device_b)

    cond do
      is_binary(a) and is_binary(b) and a == b ->
        Ash.Changeset.add_error(changeset, field: :device_b, message: "must differ from device_a")

      is_binary(a) and is_binary(b) and a > b ->
        changeset
        |> Ash.Changeset.force_change_attribute(:device_a, b)
        |> Ash.Changeset.force_change_attribute(:device_b, a)

      true ->
        changeset
    end
  end
end
