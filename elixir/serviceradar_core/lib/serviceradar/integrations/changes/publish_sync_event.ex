defmodule ServiceRadar.Integrations.Changes.PublishSyncEvent do
  @moduledoc """
  Ash change that writes sync ingestion lifecycle events to OCSF.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Events.SyncWriter

  @impl true
  def init(opts) do
    stage = Keyword.fetch!(opts, :stage)

    unless stage in [:started, :finished] do
      raise ArgumentError, "stage must be :started or :finished"
    end

    {:ok, %{stage: stage}}
  end

  @impl true
  def change(changeset, opts, _context) do
    device_count = Ash.Changeset.get_argument(changeset, :device_count) || 0
    result = Ash.Changeset.get_argument(changeset, :result)
    error_message = Ash.Changeset.get_argument(changeset, :error_message)

    Ash.Changeset.after_action(changeset, fn _changeset, source ->
      case opts.stage do
        :started ->
          SyncWriter.write_start(source, device_count: device_count)

        :finished ->
          SyncWriter.write_finish(source,
            result: result,
            device_count: device_count,
            error_message: error_message
          )
      end

      {:ok, source}
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok
end
