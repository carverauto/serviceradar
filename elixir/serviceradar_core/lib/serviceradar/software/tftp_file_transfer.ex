defmodule ServiceRadar.Software.TftpFileTransfer do
  @moduledoc """
  Helpers for TFTP file transfer operations.

  Called by the agent gateway via `core_call` RPC to store received files
  and retrieve images for download streaming.
  """

  require Logger

  alias ServiceRadar.Software.{SoftwareImage, Storage, TftpSession}

  @doc """
  Store a file received from a TFTP receive session.

  1. Verifies the SHA-256 hash matches
  2. Stores the file via `Storage.put/2`
  3. Transitions the TftpSession through storing → stored

  Returns `{:ok, object_key}` on success.
  """
  @spec store_received_file(String.t(), String.t(), String.t(), String.t(), integer()) ::
          {:ok, String.t()} | {:error, term()}
  def store_received_file(session_id, filename, temp_path, content_hash, file_size) do
    object_key = "backups/#{session_id}/#{filename}"

    Logger.info(
      "Storing received file: session=#{session_id} filename=#{filename} " <>
        "size=#{file_size} hash=#{content_hash}"
    )

    with :ok <- verify_file(temp_path, content_hash, file_size),
         {:ok, ^object_key} <- Storage.put(object_key, temp_path),
         :ok <- transition_session_to_stored(session_id, object_key) do
      Logger.info("File stored successfully: session=#{session_id} key=#{object_key}")
      {:ok, object_key}
    else
      {:error, reason} = error ->
        Logger.error(
          "Failed to store received file: session=#{session_id} reason=#{inspect(reason)}"
        )

        fail_session(session_id, "storage failed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Retrieve a software image for download streaming.

  1. Looks up the SoftwareImage by ID
  2. Downloads the image from storage to a temp file
  3. Returns the temp path and metadata

  The caller is responsible for cleaning up the temp file.
  """
  @spec get_image_for_download(String.t()) ::
          {:ok, %{temp_path: String.t(), content_hash: String.t(), file_size: integer(), filename: String.t()}}
          | {:error, term()}
  def get_image_for_download(image_id) do
    Logger.info("Fetching image for download: image_id=#{image_id}")

    with {:ok, image} <- load_image(image_id),
         {:ok, temp_path} <- download_to_temp(image) do
      {:ok,
       %{
         temp_path: temp_path,
         content_hash: image.content_hash || "",
         file_size: image.file_size || 0,
         filename: image.filename
       }}
    end
  end

  # -- Private --

  defp verify_file(temp_path, content_hash, expected_size) do
    case File.stat(temp_path) do
      {:ok, %{size: actual_size}} when expected_size > 0 and actual_size != expected_size ->
        {:error, {:size_mismatch, expected: expected_size, actual: actual_size}}

      {:ok, _stat} ->
        if content_hash != "" do
          Storage.verify_hash(temp_path, content_hash)
        else
          :ok
        end

      {:error, reason} ->
        {:error, {:file_stat_failed, reason}}
    end
  end

  defp transition_session_to_stored(session_id, object_key) do
    with {:ok, session} <- load_session(session_id),
         {:ok, session} <- maybe_transition(session, :start_storing),
         {:ok, _session} <- finish_store(session, object_key) do
      :ok
    end
  end

  defp maybe_transition(session, action) do
    case session.status do
      :completed ->
        Ash.update(session, action: action)

      :storing ->
        # Already in storing state, skip this transition
        {:ok, session}

      other ->
        {:error, {:unexpected_session_status, other, expected: [:completed, :storing]}}
    end
  end

  defp finish_store(session, object_key) do
    Ash.update(session, action: :finish_store, params: %{object_key: object_key})
  end

  defp fail_session(session_id, error_message) do
    case load_session(session_id) do
      {:ok, session} ->
        case Ash.update(session, action: :fail, params: %{error_message: error_message}) do
          {:ok, _} -> :ok
          {:error, reason} ->
            Logger.warning("Failed to mark session as failed: #{inspect(reason)}")
        end

      {:error, _} ->
        :ok
    end
  end

  defp load_session(session_id) do
    TftpSession
    |> Ash.Query.for_read(:by_id, %{id: session_id})
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, :session_not_found}
      {:ok, session} -> {:ok, session}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_image(image_id) do
    SoftwareImage
    |> Ash.Query.for_read(:by_id, %{id: image_id})
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, :image_not_found}
      {:ok, %{object_key: nil}} -> {:error, :image_has_no_object_key}
      {:ok, image} -> {:ok, image}
      {:error, reason} -> {:error, reason}
    end
  end

  defp download_to_temp(image) do
    temp_dir = System.tmp_dir!()
    temp_path = Path.join(temp_dir, "sr_download_#{image.id}")

    case Storage.get(image.object_key, temp_path) do
      :ok -> {:ok, temp_path}
      {:error, reason} -> {:error, {:storage_get_failed, reason}}
    end
  end
end
