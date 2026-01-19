defmodule ServiceRadar.NetworkDiscovery.MapperConfigNotifier do
  @moduledoc """
  Notifier that invalidates mapper config cache when discovery resources change.
  """

  use Ash.Notifier

  require Logger

  alias ServiceRadar.AgentConfig.ConfigPublisher

  @impl Ash.Notifier
  def notify(%Ash.Notifier.Notification{
        resource: resource,
        action: %{name: action_name, type: action_type},
        data: record
      }) do
    action = normalize_action(action_name, action_type)
    resource_name = resource |> Module.split() |> List.last()

    Logger.debug(
      "MapperConfigNotifier: #{action} on #{resource_name}, invalidating mapper config"
    )

    ConfigPublisher.publish_resource_change(:mapper, resource, record.id, action)
    :ok
  end

  defp normalize_action(:create, _), do: :created
  defp normalize_action(:update, _), do: :updated
  defp normalize_action(:delete, _), do: :deleted
  defp normalize_action(_, :destroy), do: :deleted
  defp normalize_action(action, _), do: action
end
