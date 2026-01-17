defmodule ServiceRadar.AgentConfig.ConfigInvalidationNotifier do
  @moduledoc """
  Ash notifier that triggers cache invalidation when config resources change.

  When ConfigInstance or ConfigTemplate resources are created, updated, or deleted,
  this notifier invalidates the relevant cache entries and publishes NATS events
  for cluster-wide invalidation.

  Schema isolation is handled by the database connection's search_path.
  """

  use Ash.Notifier

  require Logger

  alias ServiceRadar.AgentConfig.ConfigPublisher

  @impl Ash.Notifier
  def notify(%Ash.Notifier.Notification{
        resource: resource,
        action: %{name: action_name, type: action_type},
        data: record,
        changeset: _changeset
      })
      when resource in [
             ServiceRadar.AgentConfig.ConfigInstance,
             ServiceRadar.AgentConfig.ConfigTemplate
           ] do
    config_type = get_config_type(record)
    action = normalize_action(action_name, action_type)

    if config_type do
      resource_name = resource |> Module.split() |> List.last()

      Logger.debug(
        "ConfigInvalidationNotifier: #{action} on #{resource_name}, " <>
          "invalidating cache for type=#{config_type}"
      )

      # Publish invalidation event (this also invalidates local cache)
      ConfigPublisher.publish_resource_change(
        config_type,
        resource,
        record.id,
        action
      )
    end

    :ok
  end

  def notify(_notification), do: :ok

  defp get_config_type(%{config_type: config_type}) when not is_nil(config_type) do
    if is_atom(config_type), do: config_type, else: String.to_existing_atom(config_type)
  rescue
    _ -> nil
  end

  defp get_config_type(_), do: nil

  defp normalize_action(:create, _), do: :created
  defp normalize_action(:update, _), do: :updated
  defp normalize_action(:delete, _), do: :deleted
  defp normalize_action(_, :destroy), do: :deleted
  defp normalize_action(action, _), do: action
end
