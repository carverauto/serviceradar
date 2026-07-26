defmodule ServiceRadar.Edge.CompressionReadiness do
  @moduledoc """
  Fail-closed compression admission for the edge decode path (task 1.5, PARTIAL).

  ## This does NOT establish compression parity with Go

  An earlier attempt validated Zstd structurally — walking RFC 8878 frame and block
  headers — and admitted anything well-formed. That is not equivalent to Go's
  `edgerecord.ValidateZstdPayload`, and the difference is not the decoded-length
  check it claimed. A structural walk inspects LENGTHS, not CONTENT, so it cannot
  see a corrupt checksum, a bad compressed block, a dictionary id, an oversized
  window, an out-of-range block size, or an FCS mismatch. Confirmed against both
  runtimes with `28b52ffd24010900004100000000`: Elixir said `:ok`, Go said
  "payload is not a valid zstd frame".

  So this module does not decide ZSTD at all. `serviceradar_core` has no Zstd
  decoder, and without one the honest answer is NOT READY:

    * `NONE` is validated COMPLETELY and may be admitted;
    * ZSTD may be REJECTED when the bytes are provably bad (sound: every rejection
      here is one Go also makes);
    * every ZSTD input that survives rejection returns `{:not_ready, reason}` and
      stays UNRESOLVED — never `:ok`.

  `:not_ready` is a readiness failure, so it pauses rather than destroying: the
  record is neither admitted nor permanently rejected, and becomes decidable once a
  bounded decoder exists.

  ## Scope

  Task 1.5 and compression parity are NOT complete. A later slice, landing before
  task 1.16 enables ZSTD, must add a real bounded decoder validating dictionaries,
  windows, blocks, checksums, trailing frames, output limits, and exact decoded
  size through actual gateway/EventWriter admission. Until then ZSTD stays
  unadvertised — see `advertised_codecs/0`.
  """

  alias Serviceradar.Edge.V1.EdgeRecordV1

  # Mirrors Go: MaxUncompressedBytes / MaxCompressionRatio in validate.go.
  @max_uncompressed_bytes 32 * 1024 * 1024
  @max_compression_ratio 100

  @zstd_magic 0xFD2FB528
  @did_field_size {0, 1, 2, 4}

  @type failure ::
          :compression | :encoded_size | :uncompressed_size | :zstd_invalid | :zstd_trailing
  @type not_ready :: :zstd_decoder_unavailable
  @type verdict :: :ok | {:error, failure()} | {:not_ready, not_ready()}

  @doc "Absolute ceiling on a declared decoded size (Go: MaxUncompressedBytes)."
  @spec max_uncompressed_bytes() :: pos_integer()
  def max_uncompressed_bytes, do: @max_uncompressed_bytes

  @doc "Ceiling on declared decoded size relative to encoded size (Go: MaxCompressionRatio)."
  @spec max_compression_ratio() :: pos_integer()
  def max_compression_ratio, do: @max_compression_ratio

  @doc """
  Codecs this deployment advertises as admissible.

  ZSTD is deliberately absent: producers must not be told it is accepted while the
  decode path cannot decide it.
  """
  @spec advertised_codecs() :: [atom()]
  def advertised_codecs, do: [:EDGE_RECORD_COMPRESSION_NONE]

  @doc """
  Assess a decoded `EdgeRecordV1`'s compression envelope.

  `encoded_size` is bound to the ACTUAL payload length first, for every codec. A
  declared size that does not match the bytes present makes every later size test
  meaningless — the ratio guard in particular would be computed against a number
  the producer chose rather than the payload it sent.
  """
  @spec assess(struct()) :: verdict()
  def assess(%EdgeRecordV1{} = record) do
    payload = payload_of(record)
    encoded = size_of(record.encoded_size)
    uncompressed = size_of(record.uncompressed_size)

    if encoded == byte_size(payload) do
      assess_codec(record.compression, payload, uncompressed, encoded)
    else
      {:error, :encoded_size}
    end
  end

  def assess(_not_a_record), do: {:error, :compression}

  # NONE is fully decidable here: the payload IS the record body, so an exact
  # three-way agreement between declared sizes and the bytes present is the whole
  # contract.
  defp assess_codec(:EDGE_RECORD_COMPRESSION_NONE, payload, uncompressed, encoded) do
    if uncompressed == encoded and uncompressed == byte_size(payload) do
      :ok
    else
      {:error, :uncompressed_size}
    end
  end

  defp assess_codec(:EDGE_RECORD_COMPRESSION_ZSTD, payload, uncompressed, encoded) do
    case reject_zstd_early(payload, uncompressed, encoded) do
      :no_early_rejection -> {:not_ready, :zstd_decoder_unavailable}
      {:error, _} = rejection -> rejection
    end
  end

  defp assess_codec(_unknown_or_unset, _payload, _uncompressed, _encoded),
    do: {:error, :compression}

  @doc """
  Early-reject preflight for a Zstd payload.

  Returns `{:error, reason}` only for inputs Go ALSO rejects, and
  `:no_early_rejection` otherwise. It NEVER returns `:ok`: passing the preflight
  means "not provably bad", which is not the same as valid, and treating it as
  admission is precisely the error this module exists to correct.
  """
  @spec reject_zstd_early(binary(), non_neg_integer(), non_neg_integer()) ::
          :no_early_rejection | {:error, failure()}
  def reject_zstd_early(payload, declared_uncompressed, encoded_size) when is_binary(payload) do
    cond do
      declared_uncompressed == 0 ->
        {:error, :uncompressed_size}

      declared_uncompressed > @max_uncompressed_bytes ->
        {:error, :uncompressed_size}

      # Zstd may EXPAND a tiny incompressible payload, so Go applies no lower
      # bound against encoded_size -- only this upper expansion ratio.
      declared_uncompressed > encoded_size * @max_compression_ratio ->
        {:error, :uncompressed_size}

      true ->
        single_frame_exactly(payload)
    end
  end

  def reject_zstd_early(_payload, _declared, _encoded), do: {:error, :zstd_invalid}

  @doc """
  Reject a payload that is not exactly one standard Zstd frame ending at its last
  byte; otherwise report that no early rejection applies.

  A valid frame ending EARLY means trailing bytes, a second concatenated frame, an
  empty concatenated frame, or a skippable frame follows — all of which Go rejects.
  A decoder transparently consumes no-output trailing frames, so only a structural
  walk can see them; that is what this check is for, and all it is for.
  """
  @spec single_frame_exactly(binary()) :: :no_early_rejection | {:error, failure()}
  def single_frame_exactly(payload) when is_binary(payload) do
    case frame_length(payload) do
      {:ok, len} when len == byte_size(payload) -> :no_early_rejection
      {:ok, _shorter} -> {:error, :zstd_trailing}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Encoded length of the single standard Zstd frame at the start of `bin`.

  Walks the RFC 8878 frame header and block headers WITHOUT decompressing, so it
  can prove a payload is malformed but never that it is well-formed.
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

  defp frame_header_length(<<fhd, _::binary>> = rest) do
    fcs_flag = Bitwise.bsr(fhd, 6)
    single_segment? = Bitwise.band(fhd, 0x20) != 0

    if Bitwise.band(fhd, 0x08) == 0 do
      did_flag = Bitwise.band(fhd, 0x03)

      len =
        1 + if(single_segment?, do: 0, else: 1) + elem(@did_field_size, did_flag) +
          fcs_field_size(fcs_flag, single_segment?)

      if len <= byte_size(rest), do: {:ok, len}, else: {:error, :zstd_invalid}
    else
      # Reserved bit MUST be zero.
      {:error, :zstd_invalid}
    end
  end

  defp frame_header_length(_), do: {:error, :zstd_invalid}

  defp fcs_field_size(0, true), do: 1
  defp fcs_field_size(0, false), do: 0
  defp fcs_field_size(1, _), do: 2
  defp fcs_field_size(2, _), do: 4
  defp fcs_field_size(3, _), do: 8

  defp header_checksum?(<<fhd, _::binary>>), do: Bitwise.band(fhd, 0x04) != 0
  defp header_checksum?(_), do: false

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
