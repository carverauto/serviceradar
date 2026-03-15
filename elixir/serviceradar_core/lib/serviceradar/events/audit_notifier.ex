defmodule ServiceRadar.Events.AuditNotifier do
  @moduledoc false

  alias Ash.Notifier.Notification
  alias ServiceRadar.AshContext
  alias ServiceRadar.Events.AuditWriter

  @spec actor(Notification.t()) :: term() | nil
  def actor(%Notification{changeset: changeset}), do: AshContext.actor(changeset)

  @spec action(Notification.t()) :: atom()
  def action(%Notification{action: %{name: action_name, type: action_type}}) do
    normalize_action(action_name, action_type)
  end

  @spec build_opts(Notification.t(), keyword()) :: keyword()
  def build_opts(notification, opts) do
    opts
    |> Keyword.put_new(:action, action(notification))
    |> Keyword.put_new(:actor, actor(notification))
  end

  @spec write_async(Notification.t(), keyword()) :: :ok
  def write_async(notification, opts) do
    notification
    |> build_opts(opts)
    |> AuditWriter.write_async()
  end

  defp normalize_action(:delete, _), do: :delete
  defp normalize_action(_, :destroy), do: :delete
  defp normalize_action(action, _), do: action
end
