defmodule ServiceRadar.Integrations.IntegrationSourceNotifier do
  @moduledoc """
  Ash notifier for IntegrationSource lifecycle events.

  Writes OCSF audit events when integration sources are created, updated,
  enabled, disabled, or deleted. Uses the shared AuditWriter for consistency.
  """

  use Ash.Notifier

  alias Ash.Notifier.Notification
  alias ServiceRadar.AgentConfig.DependencyDispatcher
  alias ServiceRadar.Events.AuditNotifier

  @impl Ash.Notifier
  def notify(
        %Notification{
          resource: ServiceRadar.Integrations.IntegrationSource,
          action: %{type: action_type},
          data: record
        } =
          notification
      ) do
    AuditNotifier.write_async(notification,
      resource_type: "integration_source",
      resource_id: record.id,
      resource_name: record.name,
      details: %{
        source_type: record.source_type,
        endpoint: record.endpoint,
        enabled: record.enabled,
        agent_id: record.agent_id,
        partition: record.partition
      }
    )

    if action_type in [:create, :update, :destroy] do
      DependencyDispatcher.dispatch_async(notification)
    end

    :ok
  end

  def notify(_notification), do: :ok
end
