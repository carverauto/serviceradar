defmodule ServiceRadar.Integrations.IntegrationSourceNotifier do
  @moduledoc """
  Ash notifier for IntegrationSource lifecycle events.

  Writes OCSF audit events when integration sources are created, updated,
  enabled, disabled, or deleted. Uses the shared AuditWriter for consistency.
  """

  use Ash.Notifier

  alias ServiceRadar.Events.AuditWriter

  @impl Ash.Notifier
  def notify(%Ash.Notifier.Notification{
        resource: ServiceRadar.Integrations.IntegrationSource,
        action: %{name: action_name, type: action_type},
        data: record,
        changeset: changeset
      }) do
    actor = get_actor(changeset)
    action = normalize_action(action_name, action_type)

    AuditWriter.write_async(
      tenant_id: record.tenant_id,
      action: action,
      resource_type: "integration_source",
      resource_id: record.id,
      resource_name: record.name,
      actor: actor,
      details: %{
        source_type: record.source_type,
        endpoint: record.endpoint,
        enabled: record.enabled,
        agent_id: record.agent_id,
        partition: record.partition
      }
    )

    :ok
  end

  def notify(_notification), do: :ok

  defp normalize_action(:create, _), do: :create
  defp normalize_action(:update, _), do: :update
  defp normalize_action(:enable, _), do: :enable
  defp normalize_action(:disable, _), do: :disable
  defp normalize_action(:delete, _), do: :delete
  defp normalize_action(_, :destroy), do: :delete
  defp normalize_action(action, _), do: action

  defp get_actor(%Ash.Changeset{context: %{private: %{actor: actor}}}), do: actor
  defp get_actor(%Ash.Changeset{context: %{actor: actor}}), do: actor
  defp get_actor(_), do: nil
end
