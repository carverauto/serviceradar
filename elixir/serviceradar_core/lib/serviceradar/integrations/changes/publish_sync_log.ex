defmodule ServiceRadar.Integrations.Changes.PublishSyncLog do
  @moduledoc """
  Ash change that writes sync ingestion lifecycle updates to logs.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Changes.AfterAction
  alias ServiceRadar.Observability.SyncLogWriter

  @impl true
  def init(opts) do
    stage = Keyword.fetch!(opts, :stage)

    if stage not in [:started, :finished] do
      raise ArgumentError, "stage must be :started or :finished"
    end

    {:ok, stage: stage}
  end

  @impl true
  def change(changeset, opts, _context) do
    device_count = Ash.Changeset.get_argument(changeset, :device_count) || 0
    result = Ash.Changeset.get_argument(changeset, :result)
    error_message = Ash.Changeset.get_argument(changeset, :error_message)

    AfterAction.after_action(changeset, fn source ->
      case Keyword.fetch!(opts, :stage) do
        :started ->
          SyncLogWriter.write_start(source, device_count: device_count)

        :finished ->
          SyncLogWriter.write_finish(source,
            result: result,
            device_count: device_count,
            error_message: error_message
          )
      end
    end)
  end

  @impl true
  # An atomic update never calls change/3, so the hook is registered here too.
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
