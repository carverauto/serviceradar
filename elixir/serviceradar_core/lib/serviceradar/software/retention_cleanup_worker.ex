defmodule ServiceRadar.Software.RetentionCleanupWorker do
  @moduledoc """
  Periodic Oban worker that cleans up expired software artifacts:

  - Soft-deleted SoftwareImages past retention period: removes storage objects
  - Stored TftpSession files past retention period: removes storage objects
  """

  use Oban.Worker,
    queue: :software,
    max_attempts: 3,
    unique: [period: 300, states: [:available, :scheduled, :executing, :retryable]]

  alias ServiceRadar.Software.SoftwareImage
  alias ServiceRadar.Software.TftpSession
  alias ServiceRadar.Software.Storage

  require Ash.Query
  require Logger

  @default_retention_days 90

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    retention_days = retention_days()
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days * 86_400, :second)

    deleted_images = cleanup_deleted_images(cutoff)
    old_sessions = cleanup_old_session_files(cutoff)

    Logger.info("Retention cleanup: removed #{deleted_images} images, #{old_sessions} session files")
    :ok
  end

  defp cleanup_deleted_images(cutoff) do
    query =
      SoftwareImage
      |> Ash.Query.for_read(:list, %{})
      |> Ash.Query.filter(status == :deleted and updated_at < ^cutoff)

    case Ash.read(query) do
      {:ok, %{results: images}} -> do_cleanup_images(images)
      {:ok, images} when is_list(images) -> do_cleanup_images(images)
      _ -> 0
    end
  end

  defp do_cleanup_images(images) do
    Enum.count(images, fn image ->
      if image.object_key do
        case Storage.delete(image.object_key) do
          :ok ->
            Ash.destroy!(image)
            true

          {:error, reason} ->
            Logger.warning("Failed to delete storage object for image #{image.id}: #{inspect(reason)}")
            false
        end
      else
        Ash.destroy!(image)
        true
      end
    end)
  end

  defp cleanup_old_session_files(cutoff) do
    query =
      TftpSession
      |> Ash.Query.for_read(:list, %{})
      |> Ash.Query.filter(
        status in [:stored, :completed, :failed, :expired, :canceled] and
          updated_at < ^cutoff and
          not is_nil(object_key)
      )

    case Ash.read(query) do
      {:ok, %{results: sessions}} -> do_cleanup_sessions(sessions)
      {:ok, sessions} when is_list(sessions) -> do_cleanup_sessions(sessions)
      _ -> 0
    end
  end

  defp do_cleanup_sessions(sessions) do
    Enum.count(sessions, fn session ->
      case Storage.delete(session.object_key) do
        :ok ->
          session
          |> Ash.Changeset.for_update(:update_progress, %{})
          |> Ash.Changeset.force_change_attribute(:object_key, nil)
          |> Ash.update()

          true

        {:error, reason} ->
          Logger.warning("Failed to delete storage for session #{session.id}: #{inspect(reason)}")
          false
      end
    end)
  end

  defp retention_days do
    case Ash.read_one(ServiceRadar.Software.StorageConfig, action: :get_config) do
      {:ok, %{retention_days: days}} when is_integer(days) -> days
      _ -> @default_retention_days
    end
  rescue
    _ -> @default_retention_days
  end
end
