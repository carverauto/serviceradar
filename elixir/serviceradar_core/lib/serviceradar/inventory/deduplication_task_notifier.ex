defmodule ServiceRadar.Inventory.DeduplicationTaskNotifier do
  @moduledoc """
  Publishes `{:deduplication_task_updated, %{id: id, status: status}}` on
  `serviceradar:inventory:deduplication_tasks` whenever an operator resolves, dismisses or
  reopens a `ServiceRadar.Inventory.DeduplicationTask`, so a review queue open in another
  session drops or restores the task instead of offering an action that would now fail.

  The pulse is a refresh trigger only. Task opens and counts are bulk upserts from identity
  reconciliation, which do not notify, so ingest never broadcasts here.

  An update that runs inside a transaction must pass `return_notifications?: true` and hand the
  notifications to `Ash.Notifier.notify/1` after the commit, or Ash drops them.
  """

  use Ash.Notifier

  alias Ash.Notifier.Notification
  alias ServiceRadar.Inventory.DeduplicationTask

  @pubsub ServiceRadar.PubSub
  @topic "serviceradar:inventory:deduplication_tasks"

  @doc "The de-duplication task topic."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribe the calling process to de-duplication task updates."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @impl Ash.Notifier
  def notify(%Notification{
        resource: DeduplicationTask,
        action: %{type: :update},
        data: %{id: id, status: status}
      }) do
    case Process.whereis(@pubsub) do
      nil ->
        :ok

      _pid ->
        Phoenix.PubSub.broadcast(
          @pubsub,
          @topic,
          {:deduplication_task_updated, %{id: id, status: status}}
        )
    end

    :ok
  end

  def notify(_notification), do: :ok
end
