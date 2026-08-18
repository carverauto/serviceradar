defmodule ServiceRadar.Notifications.Validations.NonEmptyAlertSnapshot do
  @moduledoc """
  Keeps delivery snapshots readable after the source alert is pruned.

  Delivery updates are atomic by default in Ash. Implementing `atomic/3` is
  therefore part of this validation's contract even though the value being
  checked is supplied by the changeset rather than calculated in SQL.
  """

  use Ash.Resource.Validation

  @message "must denormalise the alert: AlertsRetentionWorker hard deletes alerts after 3 days " <>
             "and a delivery outlives its alert"

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :alert_snapshot) do
      snapshot when is_map(snapshot) and map_size(snapshot) > 0 ->
        :ok

      _other ->
        {:error, field: :alert_snapshot, message: @message}
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: validate(changeset, opts, context)
end
