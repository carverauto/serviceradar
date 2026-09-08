defmodule ServiceRadar.AgentConfig.DependencyNotifier do
  @moduledoc """
  Generic Ash notifier for cataloged agent config dependencies.

  Attach this notifier only to low-churn configuration resources. High-volume
  ingestion resources should use explicit scoped changes until their catalog
  resolvers are precise enough to avoid noisy fleet invalidations.
  """

  use Ash.Notifier

  alias Ash.Notifier.Notification
  alias ServiceRadar.AgentConfig.DependencyCatalog
  alias ServiceRadar.AgentConfig.DependencyDispatcher

  @impl Ash.Notifier
  def notify(%Notification{} = notification) do
    case DependencyCatalog.for_notification(notification) do
      [] ->
        :ok

      _entries ->
        DependencyDispatcher.dispatch_async(notification)
    end
  end

  def notify(_notification), do: :ok
end
