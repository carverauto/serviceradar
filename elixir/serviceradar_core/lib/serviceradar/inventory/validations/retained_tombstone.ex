defmodule ServiceRadar.Inventory.Validations.RetainedTombstone do
  @moduledoc """
  Refuses to restore a retained tombstone (`ServiceRadar.Inventory.Device.retained_reasons/0`)
  unless the action's `allow_retained` argument is true.

  Evidence-driven restores (a sweep, a discovery poll, an agent check-in) must never revive a
  record soft-deleted because its source retired its ids, or a released seed: that record is
  gone by decision, and the evidence that reaches it is an address or a MAC, not the device's
  identity. `Device :gateway_restore` has no `allow_retained` argument, so it always refuses.

  In a bulk update the refusal raises in SQL and aborts the statement, so a bulk caller must
  filter retained tombstones out of its query first; this validation is the backstop, not the
  filter.
  """

  use Ash.Resource.Validation

  import Ash.Expr

  alias Ash.Error.Changes.InvalidAttribute
  alias ServiceRadar.Inventory.Device

  @message "is a retained tombstone; only an operator restore (allow_retained) revives it"

  @impl true
  def validate(changeset, _opts, _context) do
    if allow_retained?(changeset) or not Device.retained_tombstone?(changeset.data) do
      :ok
    else
      {:error, field: :deleted_reason, value: changeset.data.deleted_reason, message: @message}
    end
  end

  # Plain references read the row as it stands before the update, which is the tombstone
  # being restored; the action's own changes clear both columns.
  @impl true
  def atomic(changeset, _opts, _context) do
    if allow_retained?(changeset) do
      :ok
    else
      retained = Device.retained_reasons()

      {:atomic, [:deleted_reason], expr(not is_nil(deleted_at) and deleted_reason in ^retained),
       expr(
         error(^InvalidAttribute, %{
           field: :deleted_reason,
           value: deleted_reason,
           message: ^@message
         })
       )}
    end
  end

  defp allow_retained?(changeset) do
    Ash.Changeset.get_argument(changeset, :allow_retained) == true
  end
end
