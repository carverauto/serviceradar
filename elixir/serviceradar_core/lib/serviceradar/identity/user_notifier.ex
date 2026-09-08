defmodule ServiceRadar.Identity.UserNotifier do
  @moduledoc """
  Audit logging for user lifecycle and role changes.
  """

  use Ash.Notifier

  alias ServiceRadar.Events.AuditNotifier

  @impl Ash.Notifier
  def notify(
        %Ash.Notifier.Notification{
          resource: ServiceRadar.Identity.User,
          action: %{name: action_name},
          data: record
        } =
          notification
      ) do
    actor = AuditNotifier.actor(notification)

    case action_name do
      :update_role ->
        AuditNotifier.write_async(notification,
          action: :update,
          resource_type: "user",
          resource_id: record.id,
          resource_name: record.email,
          details: %{
            change: "role_update",
            old_role: notification.changeset.data.role,
            new_role: record.role
          }
        )

      :deactivate ->
        ServiceRadar.Identity.Changes.RevokeUserAccess.revoke_user_access(
          record,
          actor
        )

        AuditNotifier.write_async(notification,
          action: :disable,
          resource_type: "user",
          resource_id: record.id,
          resource_name: record.email,
          details: %{change: "deactivate", status: "inactive"}
        )

      :reactivate ->
        AuditNotifier.write_async(notification,
          action: :enable,
          resource_type: "user",
          resource_id: record.id,
          resource_name: record.email,
          details: %{change: "reactivate", status: "active"}
        )

      _ ->
        :ok
    end

    :ok
  end

  def notify(_notification), do: :ok
end
