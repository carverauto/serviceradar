defmodule ServiceRadar.Identity.AuthorizationSettingsNotifier do
  @moduledoc """
  Audit logging for authorization settings changes.
  """

  use Ash.Notifier

  alias ServiceRadar.Events.AuditWriter

  @impl Ash.Notifier
  def notify(%Ash.Notifier.Notification{
        resource: ServiceRadar.Identity.AuthorizationSettings,
        action: %{name: action_name},
        data: record,
        changeset: changeset
      }) do
    case action_name do
      :create ->
        AuditWriter.write_async(
          action: :create,
          resource_type: "authorization_settings",
          resource_id: record.key,
          resource_name: "default",
          actor: get_actor(changeset),
          details: %{default_role: record.default_role, role_mappings: record.role_mappings}
        )

      :update ->
        AuditWriter.write_async(
          action: :update,
          resource_type: "authorization_settings",
          resource_id: record.key,
          resource_name: "default",
          actor: get_actor(changeset),
          details: %{default_role: record.default_role, role_mappings: record.role_mappings}
        )

      _ ->
        :ok
    end

    :ok
  end

  def notify(_notification), do: :ok

  defp get_actor(%Ash.Changeset{context: %{private: %{actor: actor}}}), do: actor
  defp get_actor(%Ash.Changeset{context: %{actor: actor}}), do: actor
  defp get_actor(_), do: nil
end
