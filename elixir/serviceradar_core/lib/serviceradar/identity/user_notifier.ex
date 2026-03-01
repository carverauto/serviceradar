defmodule ServiceRadar.Identity.UserNotifier do
  @moduledoc """
  Audit logging for user lifecycle and role changes.
  """

  use Ash.Notifier

  alias ServiceRadar.Events.AuditWriter

  @impl Ash.Notifier
  def notify(%Ash.Notifier.Notification{
        resource: ServiceRadar.Identity.User,
        action: %{name: action_name},
        data: record,
        changeset: changeset
      }) do
    case action_name do
      :update_role ->
        AuditWriter.write_async(
          action: :update,
          resource_type: "user",
          resource_id: record.id,
          resource_name: record.email,
          actor: get_actor(changeset),
          details: %{
            change: "role_update",
            old_role: changeset.data.role,
            new_role: record.role
          }
        )

      :deactivate ->
        ServiceRadar.Identity.Changes.RevokeUserAccess.revoke_user_access(
          record,
          get_actor(changeset)
        )

        AuditWriter.write_async(
          action: :disable,
          resource_type: "user",
          resource_id: record.id,
          resource_name: record.email,
          actor: get_actor(changeset),
          details: %{change: "deactivate", status: "inactive"}
        )

      :reactivate ->
        AuditWriter.write_async(
          action: :enable,
          resource_type: "user",
          resource_id: record.id,
          resource_name: record.email,
          actor: get_actor(changeset),
          details: %{change: "reactivate", status: "active"}
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
