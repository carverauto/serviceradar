defmodule ServiceRadar.Camera.Validations.ThumbnailJpeg do
  @moduledoc """
  Ash validation enforcing bounded size (<= 64 KiB) and JPEG SOI/EOI magic bytes
  on optional `thumbnail_jpeg` attributes.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Camera.Thumbnail

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.fetch_change(changeset, :thumbnail_jpeg) do
      :error -> :ok
      {:ok, value} -> validate_value(value)
    end
  end

  @impl true
  def atomic(changeset, _opts, _context) do
    case fetch_pending_value(changeset) do
      :unchanged ->
        :ok

      {:ok, value} when is_nil(value) or is_binary(value) ->
        validate_value(value)

      {:ok, _other} ->
        {:not_atomic, "thumbnail_jpeg must be a concrete binary"}
    end
  end

  defp fetch_pending_value(changeset) do
    with :error <- Keyword.fetch(changeset.atomics, :thumbnail_jpeg),
         :error <- Ash.Changeset.fetch_change(changeset, :thumbnail_jpeg) do
      :unchanged
    end
  end

  defp validate_value(value) do
    case Thumbnail.validate_jpeg(value) do
      {:ok, _} ->
        :ok

      {:error, :thumbnail_too_large} ->
        {:error,
         field: :thumbnail_jpeg, message: "must be at most #{Thumbnail.max_bytes()} bytes"}

      {:error, :invalid_thumbnail_jpeg} ->
        {:error, field: :thumbnail_jpeg, message: "must be a valid JPEG image"}
    end
  end
end
