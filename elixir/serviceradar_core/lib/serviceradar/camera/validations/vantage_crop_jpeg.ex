defmodule ServiceRadar.Camera.Validations.VantageCropJpeg do
  @moduledoc """
  Validates optional `crop_jpeg` binaries on `VantageObservation`:
  - `nil` is allowed
  - size <= 32 KiB (`32_768` bytes)
  - Baseline JFIF JPEG: starts with SOI (`FF D8`), ends with EOI (`FF D9`),
    carries an `APP0` `JFIF\\0` header, `SOF0` (`FF C0`), and `SOS` (`FF DA`)
    before `EOI`, and does not use Progressive `SOF2` (`FF C2`).
  """

  use Ash.Resource.Validation

  @max_bytes 32_768
  @max_base64_bytes div(@max_bytes + 2, 3) * 4
  @jpeg_soi <<0xFF, 0xD8>>
  @jpeg_eoi <<0xFF, 0xD9>>

  @doc "Maximum permitted crop JPEG size in bytes (32 KiB)."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "Maximum permitted Base64 string length for a 32 KiB crop JPEG."
  @spec max_base64_bytes() :: pos_integer()
  def max_base64_bytes, do: @max_base64_bytes

  @doc "Returns `true` when `bytes` is a valid Baseline JFIF JPEG within 32 KiB."
  @spec valid_crop_jpeg?(term()) :: boolean()
  def valid_crop_jpeg?(bytes), do: validate_jpeg(bytes) == {:ok, bytes} and is_binary(bytes)

  @doc "Validates an optional crop JPEG binary (`nil` is permitted)."
  @spec validate_jpeg(term()) ::
          {:ok, binary() | nil} | {:error, :crop_too_large | :invalid_crop_jpeg}
  def validate_jpeg(nil), do: {:ok, nil}

  def validate_jpeg(bytes) when is_binary(bytes) and byte_size(bytes) > @max_bytes do
    {:error, :crop_too_large}
  end

  def validate_jpeg(bytes) when is_binary(bytes) and byte_size(bytes) >= 16 do
    size = byte_size(bytes)

    with true <- binary_part(bytes, 0, 2) == @jpeg_soi,
         true <- binary_part(bytes, size - 2, 2) == @jpeg_eoi,
         {:ok, rest} <- {:ok, binary_part(bytes, 2, size - 2)},
         :ok <- scan_jfif_markers(rest, %{jfif?: false, sof0?: false}) do
      {:ok, bytes}
    else
      _ -> {:error, :invalid_crop_jpeg}
    end
  end

  def validate_jpeg(_), do: {:error, :invalid_crop_jpeg}

  @doc "Decodes and validates an optional Base64-encoded crop JPEG string."
  @spec decode_base64_jpeg(term()) ::
          {:ok, binary() | nil} | {:error, :crop_too_large | :invalid_crop_jpeg}
  def decode_base64_jpeg(nil), do: {:ok, nil}

  def decode_base64_jpeg(encoded)
      when is_binary(encoded) and byte_size(encoded) > @max_base64_bytes do
    {:error, :crop_too_large}
  end

  def decode_base64_jpeg(encoded) when is_binary(encoded) and byte_size(encoded) > 0 do
    case Base.decode64(encoded) do
      {:ok, bytes} -> validate_jpeg(bytes)
      :error -> {:error, :invalid_crop_jpeg}
    end
  end

  def decode_base64_jpeg(_), do: {:error, :invalid_crop_jpeg}

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.fetch_change(changeset, :crop_jpeg) do
      :error -> :ok
      {:ok, value} -> validate_changeset_value(value)
    end
  end

  @impl true
  def atomic(changeset, _opts, _context) do
    case fetch_pending_value(changeset) do
      :unchanged ->
        :ok

      {:ok, value} when is_nil(value) or is_binary(value) ->
        validate_changeset_value(value)

      {:ok, _other} ->
        {:not_atomic, "crop_jpeg must be a concrete binary"}
    end
  end

  defp fetch_pending_value(changeset) do
    with :error <- Keyword.fetch(changeset.atomics, :crop_jpeg),
         :error <- Ash.Changeset.fetch_change(changeset, :crop_jpeg) do
      :unchanged
    end
  end

  defp validate_changeset_value(value) do
    case validate_jpeg(value) do
      {:ok, _} ->
        :ok

      {:error, :crop_too_large} ->
        {:error, field: :crop_jpeg, message: "must be at most #{@max_bytes} bytes"}

      {:error, :invalid_crop_jpeg} ->
        {:error, field: :crop_jpeg, message: "must be a valid Baseline JFIF JPEG image"}
    end
  end

  # Walk JPEG marker segments before SOS (0xDA) to confirm APP0 "JFIF\0" and SOF0 (0xC0),
  # reject header-only SOI+APP0+EOI, and reject Progressive SOF2 (0xC2) before and after SOS
  # while honoring byte-stuffed 0xFF 0x00 in scan entropy data.
  defp scan_jfif_markers(<<0xFF, 0xFF, rest::binary>>, state),
    do: scan_jfif_markers(<<0xFF, rest::binary>>, state)

  defp scan_jfif_markers(<<0xFF, 0xC2, _rest::binary>>, _state), do: {:error, :progressive}

  defp scan_jfif_markers(<<0xFF, 0xDA, len::16, rest::binary>>, %{jfif?: true, sof0?: true})
       when len >= 2 do
    payload_len = len - 2

    case rest do
      <<_payload::binary-size(payload_len), scan_data::binary>> ->
        scan_post_sos(scan_data)

      _ ->
        {:error, :truncated_segment}
    end
  end

  defp scan_jfif_markers(<<0xFF, 0xDA, _rest::binary>>, %{jfif?: false}),
    do: {:error, :missing_jfif}

  defp scan_jfif_markers(<<0xFF, 0xDA, _rest::binary>>, %{sof0?: false}),
    do: {:error, :missing_sof0}

  defp scan_jfif_markers(<<0xFF, 0xD9, _rest::binary>>, _state), do: {:error, :missing_sos}

  defp scan_jfif_markers(<<0xFF, marker, rest::binary>>, state)
       when marker in [0x00, 0x01] or marker in 0xD0..0xD7 do
    scan_jfif_markers(rest, state)
  end

  defp scan_jfif_markers(<<0xFF, marker, len::16, rest::binary>>, state) when len >= 2 do
    payload_len = len - 2

    case rest do
      <<payload::binary-size(payload_len), tail::binary>> ->
        next_state = %{
          jfif?: state.jfif? or jfif_app0?(marker, payload),
          sof0?: state.sof0? or marker == 0xC0
        }

        scan_jfif_markers(tail, next_state)

      _ ->
        {:error, :truncated_segment}
    end
  end

  defp scan_jfif_markers(_, _), do: {:error, :invalid_marker}

  defp scan_post_sos(bin) do
    case :binary.match(bin, <<0xFF>>) do
      {pos, 1} ->
        after_ff = binary_part(bin, pos + 1, byte_size(bin) - pos - 1)
        handle_post_sos_marker(after_ff)

      :nomatch ->
        {:error, :missing_eoi}
    end
  end

  defp handle_post_sos_marker(<<0xD9>>), do: :ok
  defp handle_post_sos_marker(<<0x00, rest::binary>>), do: scan_post_sos(rest)
  defp handle_post_sos_marker(<<0xFF, rest::binary>>), do: handle_post_sos_marker(rest)
  defp handle_post_sos_marker(<<m, rest::binary>>) when m in 0xD0..0xD7, do: scan_post_sos(rest)
  defp handle_post_sos_marker(<<0xC2, _::binary>>), do: {:error, :progressive}
  defp handle_post_sos_marker(<<_other, rest::binary>>), do: scan_post_sos(rest)
  defp handle_post_sos_marker(<<>>), do: {:error, :truncated_marker}

  defp jfif_app0?(0xE0, <<"JFIF", 0, _::binary>>), do: true
  defp jfif_app0?(_, _), do: false
end
