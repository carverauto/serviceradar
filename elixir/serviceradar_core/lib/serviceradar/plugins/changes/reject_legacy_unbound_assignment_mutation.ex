defmodule ServiceRadar.Plugins.Changes.RejectLegacyUnboundAssignmentMutation do
  @moduledoc false

  # The partition-binding migration deliberately preserved these rows as
  # disabled historical evidence. A regular update could otherwise set
  # `enabled: true` while leaving a `NULL` partition, and a regular destroy
  # could erase the evidence before its explicit recovery has been audited.
  # Recovery creates a separate bound row and never needs this bypassed.
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if legacy_unbound?(changeset.data) do
      Ash.Changeset.add_error(changeset,
        field: :partition_id,
        message: "legacy unbound assignments require explicit recovery and cannot be mutated"
      )
    else
      changeset
    end
  end

  defp legacy_unbound?(%{enabled: false, partition_id: partition_id}) do
    not present?(partition_id)
  end

  defp legacy_unbound?(_assignment), do: false

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
