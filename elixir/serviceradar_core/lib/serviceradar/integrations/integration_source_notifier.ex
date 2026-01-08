defmodule ServiceRadar.Integrations.IntegrationSourceNotifier do
  @moduledoc """
  Ash notifier for IntegrationSource lifecycle events.

  Publishes events to NATS when integration sources are created, updated,
  enabled, disabled, or deleted. Runs after transaction commits to ensure
  events only fire for successful operations.
  """

  use Ash.Notifier

  require Logger

  alias ServiceRadar.Integrations.EventPublisher

  @impl Ash.Notifier
  def notify(%Ash.Notifier.Notification{
        resource: ServiceRadar.Integrations.IntegrationSource,
        action: %{name: action_name, type: action_type},
        data: record,
        changeset: changeset
      }) do
    actor = get_actor(changeset)
    action = normalize_action(action_name, action_type)

    Task.start(fn ->
      _ = EventPublisher.publish_integration_source_event(
        record,
        action,
        actor: actor
      )
    end)

    :ok
  end

  def notify(_notification), do: :ok

  defp get_actor(%Ash.Changeset{context: %{private: %{actor: actor}}}), do: actor
  defp get_actor(%Ash.Changeset{context: %{actor: actor}}), do: actor
  defp get_actor(_), do: nil

  defp normalize_action(:create, _), do: :create
  defp normalize_action(:update, _), do: :update
  defp normalize_action(:enable, _), do: :enable
  defp normalize_action(:disable, _), do: :disable
  defp normalize_action(:delete, _), do: :delete
  defp normalize_action(_, :destroy), do: :delete
  defp normalize_action(action, _), do: action
end
