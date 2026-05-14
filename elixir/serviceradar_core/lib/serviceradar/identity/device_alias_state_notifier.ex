defmodule ServiceRadar.Identity.DeviceAliasStateNotifier do
  @moduledoc """
  Invalidates IP identity-cache entries when alias state changes.
  """

  use Ash.Notifier

  alias Ash.Notifier.Notification
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Identity.IdentityCache

  @impl Ash.Notifier
  def notify(%Notification{
        resource: DeviceAliasState,
        action: %{type: action_type},
        data: record,
        changeset: changeset
      })
      when action_type in [:create, :update, :destroy] do
    invalidate_identity_cache(changeset_data(changeset))
    invalidate_identity_cache(record)
    :ok
  end

  def notify(_notification), do: :ok

  defp changeset_data(%{data: data}), do: data
  defp changeset_data(_), do: nil

  defp invalidate_identity_cache(%{alias_type: :ip, alias_value: value})
       when is_binary(value) and value != "" do
    IdentityCache.delete(value)
  end

  defp invalidate_identity_cache(_record), do: :ok
end
