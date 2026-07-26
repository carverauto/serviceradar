defmodule ServiceRadar.Edge.CompressionValidate do
  @moduledoc """
  Compression-envelope parity with Go's `edgerecord.validateCompression` /
  `ValidateZstdPayload` (task 1.5: "streaming compression expansion" and
  "trailing-frame rejection").

  Go refuses a decompression bomb BEFORE decoding, using only declared sizes, and
  then proves the payload is exactly ONE standard Zstd frame that ends at the last
  byte. Both of those are reproducible here byte-for-byte, because neither needs a
  decompressor:

    * the bomb guard is pure arithmetic on `uncompressed_size` / `encoded_size`;
    * the single-frame/trailing guard is a structural walk of the RFC 8878 frame
      header and block headers, which never inflates anything.

  ## The one rule this module CANNOT reproduce, and why that is stated rather than hidden

  Go's final check decodes the payload through a fixed scratch buffer and requires
  the actual output length to equal `uncompressed_size` exactly. That needs a Zstd
  decoder, and `serviceradar_core` has no Zstd dependency. Rather than silently
  enforcing a weaker rule and calling it parity, the gap is DECLARED:
  `verified_scope/0` lists `:zstd_decoded_size_equality` under `:unverified`, and a
  test asserts that declaration so it cannot quietly disappear.

  This is a deliberate, bounded divergence: everything that can be decided from the
  bytes themselves IS decided here identically to Go, so a payload Elixir accepts
  and Go rejects can only differ in that single decoded-length equality -- and never
  in frame structure, trailing data, or expansion ratio, which are the inputs an
  attacker controls.
  """

  alias Serviceradar.Edge.V1.EdgeRecordV1

  # Mirrors Go: MaxUncompressedBytes / MaxCompressionRatio in validate.go.
  @max_uncompressed_bytes 32 * 1024 * 1024
  @max_compression_ratio 100

  @zstd_magic 0xFD2FB528

  # Encoded length in bytes of the Dictionary_ID field, indexed by DID_Flag.
  @did_field_size {0, 1, 2, 4}

  @type failure ::
          :compression
          | :uncompressed_size
          | :zstd_invalid
          | :zstd_trailing

  @doc "Absolute ceiling on a declared decoded size (Go: MaxUncompressedBytes)."
  @spec max_uncompressed_bytes() :: pos_integer()
  def max_uncompressed_bytes, do: @max_uncompressed_bytes

  @doc "Ceiling on declared decoded size relative to encoded size (Go: MaxCompressionRatio)."
  @spec max_compression_ratio() :: pos_integer()
  def max_compression_ratio, do: @max_compression_ratio

  @doc """
  Which Go rules this module decides locally. Callers that need full parity on
  `:zstd_output_size` must obtain the decoded bytes from a component that has a
  decoder (today: the Go gateway).
  """
  @spec verified_scope() :: %{verified: [atom()], unverified: [atom()]}
  def verified_scope do
    %{
      verified: [
        :compression_enum,
        :none_size_equality,
        :zstd_declared_size_bounds,
        :zstd_expansion_ratio,
        :zstd_frame_structure,
        :zstd_trailing_data
      ],
      unverified: [:zstd_decoded_size_equality]
    }
  end

  @doc """
  Validate the compression envelope of a decoded `EdgeRecordV1`.

  Mirrors Go's `validateCompression`: an unset/unknown compression is
  `{:error, :compression}`; NONE requires `uncompressed_size == encoded_size`;
  ZSTD applies the bomb guard and then the frame-structure/trailing guard.
  """
  @spec validate(struct()) :: :ok | {:error, failure()}
  def validate(%EdgeRecordV1{} = record) do
    case record.compression do
      :EDGE_RECORD_COMPRESSION_NONE ->
        if size_of(record.uncompressed_size) == size_of(record.encoded_size) do
          :ok
        else
          {:error, :uncompressed_size}
        end

      :EDGE_RECORD_COMPRESSION_ZSTD ->
        validate_zstd(
          payload_of(record),
          size_of(record.uncompressed_size),
          size_of(record.encoded_size)
        )

      _unknown_or_unset ->
        {:error, :compression}
    end
  end

  def validate(_not_a_record), do: {:error, :compression}

  @doc """
  Bomb guard plus single-frame/trailing guard for a Zstd payload.

  The declared-size test runs FIRST and in Go's exact order, so an oversized or
  zero declaration is rejected without touching the payload bytes at all.
  """
  @spec validate_zstd(binary(), non_neg_integer(), non_neg_integer()) :: :ok | {:error, failure()}
  def validate_zstd(payload, declared_uncompressed, encoded_size) when is_binary(payload) do
    cond do
      declared_uncompressed == 0 ->
        {:error, :uncompressed_size}

      declared_uncompressed > @max_uncompressed_bytes ->
        {:error, :uncompressed_size}

      # Zstd may EXPAND a tiny incompressible payload, so Go deliberately applies
      # no lower bound against encoded_size -- only this upper expansion ratio.
      declared_uncompressed > encoded_size * @max_compression_ratio ->
        {:error, :uncompressed_size}

      true ->
        single_frame_exactly(payload)
    end
  end

  def validate_zstd(_payload, _declared, _encoded), do: {:error, :zstd_invalid}

  @doc """
  Require the payload to be exactly one standard Zstd frame ending at its last byte.

  A valid frame that ends EARLY means trailing bytes, a second concatenated frame,
  an empty concatenated frame, or a skippable frame follows -- all of which Go
  rejects as `ErrZstdTrailing`. This distinction matters because a decoder
  transparently consumes no-output trailing frames, so a decode-side "one extra
  output byte" probe cannot see them; only a structural walk can.
  """
  @spec single_frame_exactly(binary()) :: :ok | {:error, failure()}
  def single_frame_exactly(payload) when is_binary(payload) do
    case frame_length(payload) do
      {:ok, len} when len == byte_size(payload) -> :ok
      {:ok, _shorter} -> {:error, :zstd_trailing}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Encoded length of the single standard Zstd frame at the start of `bin`.

  Walks the RFC 8878 frame header and block headers WITHOUT decompressing. Rejects
  a non-Zstd magic (including the skippable-frame magic range), a set reserved
  frame-header bit, the reserved block type 3, and any truncation.
  """
  @spec frame_length(binary()) :: {:ok, non_neg_integer()} | {:error, failure()}
  def frame_length(<<@zstd_magic::little-32, rest::binary>>) do
    with {:ok, header_len} <- frame_header_length(rest),
         <<_header::binary-size(header_len), blocks::binary>> <- rest,
         {:ok, blocks_len, checksum?} <- walk_blocks(blocks, 0, header_checksum?(rest)) do
      total = 4 + header_len + blocks_len + if checksum?, do: 4, else: 0

      if total <= 4 + byte_size(rest), do: {:ok, total}, else: {:error, :zstd_invalid}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :zstd_invalid}
    end
  end

  def frame_length(_not_zstd), do: {:error, :zstd_invalid}

  # Frame_Header_Descriptor + optional Window_Descriptor + Dictionary_ID +
  # Frame_Content_Size. Returns the header length measured from just after magic.
  defp frame_header_length(<<fhd, _::binary>> = rest) do
    fcs_flag = Bitwise.bsr(fhd, 6)
    single_segment? = Bitwise.band(fhd, 0x20) != 0

    if Bitwise.band(fhd, 0x08) == 0 do
      did_flag = Bitwise.band(fhd, 0x03)

      len =
        1 +
          if(single_segment?, do: 0, else: 1) +
          elem(@did_field_size, did_flag) +
          fcs_field_size(fcs_flag, single_segment?)

      if len <= byte_size(rest), do: {:ok, len}, else: {:error, :zstd_invalid}
    else
      # Reserved bit MUST be zero.
      {:error, :zstd_invalid}
    end
  end

  defp frame_header_length(_), do: {:error, :zstd_invalid}

  # FCS_Field_Size: flag 0 encodes 1 byte only when Single_Segment is set.
  defp fcs_field_size(0, true), do: 1
  defp fcs_field_size(0, false), do: 0
  defp fcs_field_size(1, _), do: 2
  defp fcs_field_size(2, _), do: 4
  defp fcs_field_size(3, _), do: 8

  defp header_checksum?(<<fhd, _::binary>>), do: Bitwise.band(fhd, 0x04) != 0
  defp header_checksum?(_), do: false

  # Block_Header is 3 bytes little-endian: bit0 Last_Block, bits1-2 Block_Type,
  # bits3+ Block_Size. A raw/compressed block occupies Block_Size bytes on the
  # wire; an RLE block occupies exactly one.
  defp walk_blocks(<<b0, b1, b2, rest::binary>>, acc, checksum?) do
    hdr = b0 + Bitwise.bsl(b1, 8) + Bitwise.bsl(b2, 16)
    last? = Bitwise.band(hdr, 1) != 0
    block_type = Bitwise.band(Bitwise.bsr(hdr, 1), 0x3)
    block_size = Bitwise.bsr(hdr, 3)

    case on_wire_size(block_type, block_size) do
      {:ok, on_wire} when on_wire <= byte_size(rest) ->
        acc = acc + 3 + on_wire

        if last? do
          {:ok, acc, checksum?}
        else
          <<_consumed::binary-size(on_wire), tail::binary>> = rest
          walk_blocks(tail, acc, checksum?)
        end

      {:ok, _overrun} ->
        {:error, :zstd_invalid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp walk_blocks(_truncated, _acc, _checksum?), do: {:error, :zstd_invalid}

  defp on_wire_size(0, size), do: {:ok, size}
  defp on_wire_size(2, size), do: {:ok, size}
  defp on_wire_size(1, _size), do: {:ok, 1}
  defp on_wire_size(_reserved_3, _size), do: {:error, :zstd_invalid}

  defp payload_of(%{payload: p}) when is_binary(p), do: p
  defp payload_of(_), do: ""

  defp size_of(n) when is_integer(n) and n >= 0, do: n
  defp size_of(_), do: 0
end
