defmodule ServiceRadar.Camera.Thumbnail do
  @moduledoc """
  Validation, URL construction, and scoped retrieval for bounded JPEG clip
  thumbnails stored on `VisualFrame` and `RecordingCatalogEntry` rows.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.VantageObservation
  alias ServiceRadar.Camera.VisualFrame

  require Ash.Query

  @max_bytes 65_536
  @max_base64_bytes div(@max_bytes + 2, 3) * 4
  @jpeg_soi <<0xFF, 0xD8>>
  @jpeg_eoi <<0xFF, 0xD9>>

  @system_actor SystemActor.system(:camera_thumbnail)

  @type kind :: :frame | :block | :vantage

  @doc "Maximum permitted thumbnail size in bytes (64 KiB)."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "Returns `true` when `bytes` is a non-empty JPEG within the 64 KiB cap."
  @spec valid_jpeg?(term()) :: boolean()
  def valid_jpeg?(bytes)
      when is_binary(bytes) and byte_size(bytes) >= 4 and byte_size(bytes) <= @max_bytes do
    size = byte_size(bytes)

    binary_part(bytes, 0, 2) == @jpeg_soi and
      binary_part(bytes, size - 2, 2) == @jpeg_eoi
  end

  def valid_jpeg?(_), do: false

  @doc """
  Validates an optional JPEG binary (`nil` is permitted).
  """
  @spec validate_jpeg(term()) ::
          {:ok, binary() | nil} | {:error, :thumbnail_too_large | :invalid_thumbnail_jpeg}
  def validate_jpeg(nil), do: {:ok, nil}

  def validate_jpeg(bytes) when is_binary(bytes) and byte_size(bytes) > @max_bytes do
    {:error, :thumbnail_too_large}
  end

  def validate_jpeg(bytes) when is_binary(bytes) do
    if valid_jpeg?(bytes) do
      {:ok, bytes}
    else
      {:error, :invalid_thumbnail_jpeg}
    end
  end

  def validate_jpeg(_), do: {:error, :invalid_thumbnail_jpeg}

  @doc """
  Decodes and validates an optional base64-encoded JPEG thumbnail string.
  """
  @spec decode_base64_jpeg(term()) ::
          {:ok, binary() | nil} | {:error, :thumbnail_too_large | :invalid_thumbnail_jpeg}
  def decode_base64_jpeg(nil), do: {:ok, nil}

  def decode_base64_jpeg(encoded)
      when is_binary(encoded) and byte_size(encoded) > @max_base64_bytes do
    {:error, :thumbnail_too_large}
  end

  def decode_base64_jpeg(encoded) when is_binary(encoded) and byte_size(encoded) > 0 do
    case Base.decode64(encoded) do
      {:ok, bytes} -> validate_jpeg(bytes)
      :error -> {:error, :invalid_thumbnail_jpeg}
    end
  end

  def decode_base64_jpeg(_), do: {:error, :invalid_thumbnail_jpeg}

  @doc "Builds the authenticated thumbnail URL for a `VisualFrame`."
  @spec frame_url(String.t(), String.t()) :: String.t()
  def frame_url(camera_source_id, visual_frame_id) do
    "/api/cameras/#{camera_source_id}/timeline/thumbnails/frame/#{visual_frame_id}.jpg"
  end

  @doc "Builds the authenticated thumbnail URL for a `RecordingCatalogEntry`."
  @spec block_url(String.t(), String.t()) :: String.t()
  def block_url(camera_source_id, catalog_entry_id) do
    "/api/cameras/#{camera_source_id}/timeline/thumbnails/block/#{catalog_entry_id}.jpg"
  end

  @doc "Builds the authenticated crop preview URL for a `VantageObservation`."
  @spec vantage_crop_url(String.t(), String.t()) :: String.t()
  def vantage_crop_url(camera_source_id, observation_id) do
    "/api/cameras/#{camera_source_id}/timeline/thumbnails/vantage/#{observation_id}.jpg"
  end

  @doc """
  Fetches a validated JPEG thumbnail scoped strictly to `(camera_source_id, kind, id)`,
  excluding quarantined, unfrozen, or non-playable catalog entries.

  Only the `thumbnail_jpeg` column is selected from PostgreSQL.
  """
  @spec fetch_for_camera(String.t(), kind() | String.t(), String.t()) ::
          {:ok, binary()} | {:error, term()}
  def fetch_for_camera(camera_source_id, kind, id) do
    with {:ok, camera_uuid} <- cast_uuid(camera_source_id, :invalid_camera_source_id),
         {:ok, normalized_kind} <- normalize_kind(kind),
         {:ok, record_uuid} <- cast_uuid(id, :invalid_id),
         {:ok, bytes} <- load_from_repo(camera_uuid, normalized_kind, record_uuid) do
      if valid_jpeg?(bytes) do
        {:ok, bytes}
      else
        {:error, :thumbnail_not_found}
      end
    end
  end

  defp load_from_repo(camera_uuid, :frame, record_uuid) do
    VisualFrame
    |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
    |> Ash.Query.filter(
      id == ^record_uuid and
        camera_source_id == ^camera_uuid and
        catalog_entry.local_state != :quarantined and
        is_nil(catalog_entry.quarantine_reason) and
        not is_nil(catalog_entry.recording_block_id) and
        (catalog_entry.local_state == :present or catalog_entry.archive_state == :verified)
    )
    |> Ash.Query.select([:id, :thumbnail_jpeg])
    |> Ash.read_one(actor: @system_actor)
    |> unwrap_thumbnail_row()
  end

  defp load_from_repo(camera_uuid, :block, record_uuid) do
    RecordingCatalogEntry
    |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
    |> Ash.Query.filter(
      id == ^record_uuid and
        camera_source_id == ^camera_uuid and
        local_state != :quarantined and
        is_nil(quarantine_reason) and
        not is_nil(recording_block_id) and
        (local_state == :present or archive_state == :verified)
    )
    |> Ash.Query.select([:id, :thumbnail_jpeg])
    |> Ash.read_one(actor: @system_actor)
    |> unwrap_thumbnail_row()
  end

  defp load_from_repo(camera_uuid, :vantage, record_uuid) do
    VantageObservation
    |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
    |> Ash.Query.filter(
      id == ^record_uuid and
        camera_source_id == ^camera_uuid and
        ((source_mode == :live_keyframe_tap and is_nil(catalog_entry_id)) or
           (not is_nil(catalog_entry_id) and
              catalog_entry.local_state != :quarantined and
              is_nil(catalog_entry.quarantine_reason) and
              not is_nil(catalog_entry.recording_block_id) and
              (catalog_entry.local_state == :present or catalog_entry.archive_state == :verified)))
    )
    |> Ash.Query.select([:id, :crop_jpeg, :catalog_entry_id, :source_mode])
    |> Ash.read_one(actor: @system_actor)
    |> unwrap_crop_row()
  end

  defp unwrap_thumbnail_row({:ok, %{thumbnail_jpeg: bytes}}) when is_binary(bytes),
    do: {:ok, bytes}

  defp unwrap_thumbnail_row({:ok, _}), do: {:error, :thumbnail_not_found}
  defp unwrap_thumbnail_row({:error, _} = error), do: error

  defp unwrap_crop_row({:ok, %{crop_jpeg: bytes}}) when is_binary(bytes), do: {:ok, bytes}

  defp unwrap_crop_row({:ok, _}), do: {:error, :thumbnail_not_found}
  defp unwrap_crop_row({:error, _} = error), do: error

  defp normalize_kind(:frame), do: {:ok, :frame}
  defp normalize_kind("frame"), do: {:ok, :frame}
  defp normalize_kind(:block), do: {:ok, :block}
  defp normalize_kind("block"), do: {:ok, :block}
  defp normalize_kind(:vantage), do: {:ok, :vantage}
  defp normalize_kind("vantage"), do: {:ok, :vantage}
  defp normalize_kind(_), do: {:error, :invalid_id}

  defp cast_uuid(value, error_reason) when is_binary(value) do
    case Ecto.UUID.cast(String.trim(value)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, error_reason}
    end
  end

  defp cast_uuid(_, error_reason), do: {:error, error_reason}
end
