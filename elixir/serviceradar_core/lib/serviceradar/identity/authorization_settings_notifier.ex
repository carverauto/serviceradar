defmodule ServiceRadar.Identity.AuthorizationSettingsNotifier do
  @moduledoc """
  Audit logging for authorization settings changes.
  """

  use Ash.Notifier

  alias ServiceRadar.Events.AuditNotifier

  @impl Ash.Notifier
  def notify(%Ash.Notifier.Notification{
        resource: ServiceRadar.Identity.AuthorizationSettings,
        action: %{name: action_name},
        data: record
      } = notification) do
    case action_name in [:create, :update] do
      true ->
        AuditNotifier.write_async(notification,
          resource_type: "authorization_settings",
          resource_id: record.key,
          resource_name: "default",
          details: %{default_role: record.default_role, role_mappings: record.role_mappings}
        )

      false ->
        :ok
    end

    :ok
  end

  def notify(_notification), do: :ok
end
