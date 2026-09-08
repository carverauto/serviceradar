defmodule ServiceRadar.Edge.Compression do
  @moduledoc """
  Elixir peer of `go/pkg/edge/edgerecord/compression.go` (task 1.5-f, slice 2).

  Enforces the frozen compression-admission rules -- see the requirement "Compression
  admission is frozen by value, stage, and frame shape".

  ## The frame walk is the enforcement, not the decoder

  `:zstd.decompress/1` ACCEPTS CONCATENATED FRAMES: two frames of 5_000 bytes decompress to
  10_000 bytes with no error. So it cannot be the admission boundary, and a project-owned
  walk over the frame and block headers is required to prove the payload is exactly ONE
  frame ending at exactly `byte_size(payload)`.

  ## The window and dictionary checks are DEFENCE IN DEPTH, and that is measured

  The preflight refuses `windowSize > 32 MiB` and `dictID != 0`, and SO DOES THE DECODER --
  it raises "Frame requires too much memory" and "Dictionary mismatch" respectively, which
  `safe/1` maps to the same `:invalid`. Deleting either preflight check leaves every vector
  passing, and that is recorded rather than papered over: the two layers agree, and neither
  case is currently reachable without the other also firing.

  They are kept because they make the FROZEN RULE independent of decoder configuration. The
  ceiling is a spec value; relying on `windowLogMax` alone would make it a property of how
  the context happens to be built. `windowLogMax: 25` is set as well, and is genuinely not
  sufficient alone: a context built with `windowLogMax: 10` still decoded a frame whose
  `windowSize` is 5_000, because a single-segment frame needs no window buffer.

  ## Reason parity is deliberate, and coarser than this module could be

  Go reports an oversized window and a nonzero dictionary id as `ErrZstdInvalid` -- both come
  from its decoder rather than its frame walk. This module detects both in the preflight and
  could name them precisely, but reports `:invalid` for the same inputs, because a shared
  vector asserting an exact reason must get the same answer from both runtimes. Making them
  distinct is a change to GO's taxonomy and is out of scope for a reconcile slice.

  ## What each rule costs

  Sizes and ratio are checked on the DECLARED values before any decoding, so a bomb is
  refused unexpanded. The streaming pass then DISCARDS output as it counts, so validation
  never accumulates the body; the transient peak is bounded by the declared ceiling that has
  already been admitted.

  `@max_window` bounds the frame's HISTORY/WINDOW REQUIREMENT, not total decoder memory --
  a decoder holds tables and buffers beyond the window, and nothing here bounds the whole
  of it.
  """
  import Bitwise

  alias ServiceRadar.Edge.SemanticValidate
  alias Serviceradar.Edge.V1.EdgeRecordV1

  # The frozen values. Their normative source is the spec requirement, not this module.
  @max_uncompressed 33_554_432
  @max_ratio 100
  @max_window 33_554_432

  # The PHYSICAL ceiling on the encoded payload, mirroring Go's MaxPayloadBytes. Distinct in
  # kind from the three work ceilings above: this one bounds received bytes.
  @max_payload 524_288

  # 1 << 25 = 33_554_432. Defence in depth only -- see the moduledoc.
  @window_log_max 25

  # DERIVED, not restated. `SemanticValidate` already owns the admitted set as the enum
  # policy for this exact field, and Go reads its own from one place for the same reason. A
  # second literal list here would agree on the day it was written and drift silently after.
  @admitted_codecs Map.fetch!(SemanticValidate.enum_field_policy(), {EdgeRecordV1, :compression})

  @record_keys EdgeRecordV1.__struct__() |> Map.keys() |> Enum.sort()

  @zstd_magic 0xFD2FB528

  @typedoc """
  Rejection reasons, matching Go's sentinels one-for-one:
  `:invalid` = `ErrZstdInvalid`, `:output_size` = `ErrZstdOutputSize`,
  `:trailing` = `ErrZstdTrailing`.
  """
  @type reason :: :invalid | :output_size | :trailing

  @typedoc """
  Record-stage rejection reasons, matching Go's sentinels: `:payload_too_large` =
  `ErrPayloadTooLarge`, `:encoded_size` = `ErrEncodedSize`, `:payload_digest` =
  `ErrPayloadDigest`, `:compression` = `ErrCompression`, `:uncompressed_size` =
  `ErrUncompressedSize`. A frame reason may also surface, unchanged.
  """
  @type record_reason ::
          :payload_too_large
          | :encoded_size
          | :payload_digest
          | :compression
          | :uncompressed_size
          | :record
          | reason()

  @doc """
  The DECLARED-SIZE admission: nonzero, within the output ceiling, and within the ratio of
  the encoded size. Evaluated BEFORE decompression, which is the point -- a decompression
  bomb is refused without ever being expanded.

  `encoded_size` MUST already have been bound to the actual payload length by the caller. It
  is the ratio's denominator, so an unbound value buys arbitrary ratio headroom.
  """
  @spec admit_declared(term(), term()) :: :ok | {:error, :output_size}
  def admit_declared(uncompressed_size, encoded_size)
      when is_integer(uncompressed_size) and is_integer(encoded_size) and uncompressed_size > 0 and
             encoded_size >= 0 do
    if uncompressed_size <= @max_uncompressed and
         uncompressed_size <= encoded_size * @max_ratio,
       do: :ok,
       else: {:error, :output_size}
  end

  def admit_declared(_, _), do: {:error, :output_size}

  @doc """
  Bounded streaming validation of a ZSTD payload against its declared decoded size.

  Mirrors Go's `ValidateZstdPayload`: frame structure FIRST (so trailing data is refused
  before any decode), then a streaming decode whose output must equal the declaration exactly.
  """
  @spec validate_payload(term(), term()) :: :ok | {:error, reason()}
  def validate_payload(payload, declared) when is_binary(payload) and is_integer(declared) do
    with :ok <- encoded_in_range(payload),
         :ok <- declared_in_range(declared),
         {:ok, frame_len} <- frame_length(payload),
         :ok <- exact_extent(frame_len, byte_size(payload)),
         :ok <- header_admissible(payload) do
      streamed_size(payload, declared)
    end
  end

  def validate_payload(_, _), do: {:error, :invalid}

  @doc """
  Validates and then materializes the body.

  TWO PASSES, deliberately. The first proves the output size without retaining the body; the
  second produces it. The freeze is about one compression LAYER, not one pass, and Go has the
  same topology.
  """
  @spec decompress(term(), term()) :: {:ok, binary()} | {:error, reason()}
  def decompress(payload, declared) do
    with :ok <- validate_payload(payload, declared) do
      materialize(payload, declared)
    end
  end

  @doc """
  RECORD-LEVEL compression admission -- the peer of Go's `validatePayloadBinding`.

  `admit_declared/2` is the ratio gate, but it takes `encoded_size` on trust; its own doc
  says the caller MUST have bound that value to the payload length first. Until this
  function existed nothing in this runtime did, so the precondition was documented and
  never enforced -- and an unbound `encoded_size` buys arbitrary ratio headroom, because it
  is the DENOMINATOR.

  The ORDER is the frozen part, and it is Go's order exactly:

    1. the payload fits the PHYSICAL ceiling;
    2. `encoded_size` is BOUND to the actual payload length;
    3. `payload_sha256` covers those same bytes;
    4. the codec is one of the admitted set;
    5. per codec -- NONE requires `uncompressed_size == encoded_size`; ZSTD applies the
       declared-size and ratio gate BEFORE decoding, then validates the frame.

  Step 2 before step 5 is what makes the ratio meaningful; a runtime that checked the ratio
  first would compare against a number the sender chose.

  ## Reasons

  One-for-one with Go's sentinels: `:payload_too_large`, `:encoded_size`, `:payload_digest`,
  `:compression`, `:uncompressed_size`, plus the frame reasons from `validate_payload/2`.

  `admit_declared/2` reports `:output_size` because at the FRAME stage that is Go's
  `ErrZstdOutputSize`. At the RECORD stage the same condition is Go's `ErrUncompressedSize`,
  so it is translated here rather than leaking a frame reason into a record verdict.

  `:record` has no Go counterpart -- Go's signature makes a non-record unrepresentable. It
  keeps this boundary total, and no shared vector can produce it.
  """
  @spec admit_record(term()) :: :ok | {:error, record_reason()}
  def admit_record(
        %EdgeRecordV1{
          payload: payload,
          payload_sha256: digest,
          encoded_size: encoded,
          uncompressed_size: uncompressed,
          compression: codec
        } = rec
      )
      when is_binary(payload) and is_binary(digest) and is_integer(encoded) and
             is_integer(uncompressed) do
    with :ok <- exact_record_shape(rec),
         :ok <- payload_in_range(payload),
         :ok <- encoded_size_bound(encoded, payload),
         :ok <- payload_digest(digest, payload),
         :ok <- admitted_codec(codec) do
      admit_codec(codec, uncompressed, encoded, payload)
    end
  end

  # EVERYTHING ELSE IS REFUSED, not normalized. Three ways this was unsound before:
  #
  #   * `%EdgeRecordV1{} = r` matches a bare `%{__struct__: EdgeRecordV1}` -- a map with no
  #     other keys -- and `r.payload` then RAISES rather than returning a reason;
  #   * `payload || <<>>` turned a nil or false payload into empty bytes, so a record with
  #     no payload was admitted as one carrying zero bytes;
  #   * `==` is value equality across numeric types, so `uncompressed_size: 5.0` compared
  #     equal to `encoded_size: 5` on the NONE path and a float size was admitted.
  #
  # The head above requires a binary payload and digest and INTEGER sizes, so all three land
  # here. It is NOT sufficient on its own: matching five named keys plus `__struct__` admits
  # a hand-built map carrying only those six, so `exact_record_shape/1` compares the FULL key
  # inventory against the generated struct.
  def admit_record(_), do: {:error, :record}

  @doc "The frozen ceilings, so callers and vectors read them from one place."
  @spec limits() :: %{uncompressed: pos_integer(), ratio: pos_integer(), window: pos_integer()}
  def limits, do: %{uncompressed: @max_uncompressed, ratio: @max_ratio, window: @max_window}

  # --- declared size ---------------------------------------------------------------------

  # The ENCODED INPUT is bounded before the frame is walked. A caller could otherwise hand
  # this an arbitrarily large buffer; the peer is described as bounded, so it must be.
  # Reported as `:invalid` rather than a new reason, because the frame stage's vocabulary is
  # shared with Go through the corpus manifest and a fourth reason would change a frozen
  # taxonomy for a case record admission already refuses earlier.
  defp encoded_in_range(payload) when byte_size(payload) <= @max_payload, do: :ok
  defp encoded_in_range(_), do: {:error, :invalid}

  defp declared_in_range(declared) when declared > 0 and declared <= @max_uncompressed, do: :ok
  defp declared_in_range(_), do: {:error, :output_size}

  defp exact_extent(frame_len, payload_len) when frame_len == payload_len, do: :ok
  defp exact_extent(_, _), do: {:error, :trailing}

  # --- header ----------------------------------------------------------------------------

  # `get_frame_header/1` describes only the FIRST frame, so it is not a substitute for the
  # walk. It is used for the two values the walk deliberately skips.
  defp header_admissible(payload) do
    case :zstd.get_frame_header(payload) do
      {:ok, %{dictID: dict_id, windowSize: window}} ->
        cond do
          dict_id != 0 -> {:error, :invalid}
          is_integer(window) and window > @max_window -> {:error, :invalid}
          true -> :ok
        end

      _ ->
        {:error, :invalid}
    end
  rescue
    _ -> {:error, :invalid}
  catch
    _, _ -> {:error, :invalid}
  end

  # --- streaming -------------------------------------------------------------------------

  # `:zstd.stream/2` returns EITHER `{:continue, output}` when it consumed all the input, OR
  # `{:continue, remainder, output}` when its 128 KiB output buffer filled first. Matching
  # only the two-tuple raises `CaseClauseError` on any body above that buffer -- a VALID
  # 131_073-byte body produces exactly that. So the remainder is fed back until it is gone.
  defp streamed_size(payload, declared) do
    with_context(fn ctx ->
      case drain(ctx, payload, 0, declared) do
        {:ok, ^declared} -> :ok
        {:ok, _other} -> {:error, :output_size}
        {:error, _} = e -> e
      end
    end)
  end

  # Counts output and DISCARDS it, stopping as soon as the count exceeds the declaration so a
  # frame that would overrun is refused without producing the rest.
  defp drain(ctx, input, acc, declared) do
    case safe(fn -> :zstd.stream(ctx, input) end) do
      {:ok, {:continue, remainder, out}} ->
        case bump(acc, out, declared) do
          {:ok, n} -> drain(ctx, remainder, n, declared)
          {:error, _} = e -> e
        end

      {:ok, {_tag, out}} ->
        with {:ok, n} <- bump(acc, out, declared),
             {:ok, tail} <- safe_finish(ctx) do
          bump(n, tail, declared)
        end

      {:error, _} = e ->
        e
    end
  end

  defp bump(acc, out, declared) do
    n = acc + IO.iodata_length(out)
    if n > declared, do: {:error, :output_size}, else: {:ok, n}
  end

  defp safe_finish(ctx) do
    case safe(fn -> :zstd.finish(ctx, "") end) do
      {:ok, {_tag, out}} -> {:ok, out}
      {:error, _} = e -> e
    end
  end

  # The second pass, which materializes. Same remainder handling; the body is accumulated
  # here because producing it is the point.
  defp materialize(payload, declared) do
    with_context(fn ctx ->
      case collect(ctx, payload, []) do
        {:ok, chunks} ->
          out = IO.iodata_to_binary(chunks)
          if byte_size(out) == declared, do: {:ok, out}, else: {:error, :output_size}

        {:error, _} = e ->
          e
      end
    end)
  end

  defp collect(ctx, input, acc) do
    case safe(fn -> :zstd.stream(ctx, input) end) do
      {:ok, {:continue, remainder, out}} ->
        collect(ctx, remainder, [acc, out])

      {:ok, {_tag, out}} ->
        case safe_finish(ctx) do
          {:ok, tail} -> {:ok, [acc, out, tail]}
          {:error, _} = e -> e
        end

      {:error, _} = e ->
        e
    end
  end

  # A decompression context holds native state. `finish/2` RESETS it; it does not release it,
  # so every acquired context is closed on every path.
  defp with_context(fun) do
    case safe(fn -> :zstd.context(:decompress, %{windowLogMax: @window_log_max}) end) do
      {:ok, {:ok, ctx}} ->
        try do
          fun.(ctx)
        after
          safe(fn -> :zstd.close(ctx) end)
        end

      _ ->
        {:error, :invalid}
    end
  end

  # The OTP zstd primitives are NIF-backed and raise on malformed input. A validator
  # promising `{:error, reason}` must not let that through its public boundary.
  defp safe(fun) do
    {:ok, fun.()}
  rescue
    _ -> {:error, :invalid}
  catch
    _, _ -> {:error, :invalid}
  end

  # --- record-stage admission ------------------------------------------------------------

  # A struct pattern checks `__struct__` and the keys it NAMES; nothing stops a tagged map
  # from carrying six keys where the generated record has twenty. Comparing the whole
  # inventory rejects both a forged map that is missing fields and one that carries extra
  # ones, and it is derived from the generated struct so it tracks the proto.
  defp exact_record_shape(rec) do
    if Enum.sort(Map.keys(rec)) == @record_keys, do: :ok, else: {:error, :record}
  end

  defp payload_in_range(p) when byte_size(p) <= @max_payload, do: :ok
  defp payload_in_range(_), do: {:error, :payload_too_large}

  defp encoded_size_bound(declared, payload) when declared == byte_size(payload), do: :ok
  defp encoded_size_bound(_, _), do: {:error, :encoded_size}

  defp payload_digest(<<digest::binary-size(32)>>, payload) do
    if :crypto.hash(:sha256, payload) == digest, do: :ok, else: {:error, :payload_digest}
  end

  defp payload_digest(_, _), do: {:error, :payload_digest}

  # The admitted SET lives here alone, ahead of the per-codec logic, so the switch below
  # only decides HOW to validate an accepted codec -- Go's structure, for the same reason.
  defp admitted_codec(c) when c in @admitted_codecs, do: :ok

  defp admitted_codec(_), do: {:error, :compression}

  defp admit_codec(:EDGE_RECORD_COMPRESSION_NONE, uncompressed, encoded, _payload) do
    if uncompressed == encoded, do: :ok, else: {:error, :uncompressed_size}
  end

  defp admit_codec(:EDGE_RECORD_COMPRESSION_ZSTD, uncompressed, encoded, payload) do
    case admit_declared(uncompressed, encoded) do
      :ok -> validate_payload(payload, uncompressed)
      {:error, :output_size} -> {:error, :uncompressed_size}
    end
  end

  # FAIL-CLOSED, mirroring Go's `default:` arm. `admitted_codec/1` already guarantees the
  # codec, so this is unreachable -- which is the point: without it, removing that gate turns
  # an unlisted codec into a FunctionClauseError instead of a rejection, and this boundary is
  # documented as total. Go fails closed twice here; so does the peer.
  defp admit_codec(_codec, _uncompressed, _encoded, _payload), do: {:error, :compression}

  # --- the frame walk --------------------------------------------------------------------

  # A port of Go's `zstdFrameLen`: parses ONE standard frame (RFC 8878) and returns its exact
  # encoded length. It does not decompress; it walks the frame header and block headers to
  # find the frame's end offset. A skippable-frame magic, a reserved bit, a reserved block
  # type and truncation are all refused.
  # PRIVATE deliberately: an exported frame walk would be a SECOND entry point taking raw
  # bytes, and it would not carry the encoded-input ceiling that `validate_payload/2`
  # applies before calling it. One bounded public boundary, not two.
  @spec frame_length(binary()) :: {:ok, non_neg_integer()} | {:error, :invalid}
  defp frame_length(<<magic::little-32, fhd, rest::binary>>) when magic == @zstd_magic do
    fcs_flag = fhd >>> 6
    single_seg = (fhd &&& 0x20) != 0
    reserved = (fhd &&& 0x08) != 0
    checksum = (fhd &&& 0x04) != 0
    did_flag = fhd &&& 0x03

    if reserved do
      {:error, :invalid}
    else
      # window descriptor byte, dictionary id, then frame content size
      skip =
        if(single_seg, do: 0, else: 1) +
          elem({0, 1, 2, 4}, did_flag) +
          fcs_len(fcs_flag, single_seg)

      # 5 = magic (4) + frame header descriptor (1)
      walk_blocks(rest, skip, 5 + skip, checksum)
    end
  end

  defp frame_length(_), do: {:error, :invalid}

  defp fcs_len(0, true), do: 1
  defp fcs_len(0, false), do: 0
  defp fcs_len(1, _), do: 2
  defp fcs_len(2, _), do: 4
  defp fcs_len(3, _), do: 8

  defp walk_blocks(rest, skip, off, checksum) do
    case rest do
      <<_::binary-size(skip), blocks::binary>> -> blocks(blocks, off, checksum)
      _ -> {:error, :invalid}
    end
  end

  defp blocks(<<b0, b1, b2, rest::binary>>, off, checksum) do
    hdr = b0 ||| b1 <<< 8 ||| b2 <<< 16
    last = (hdr &&& 1) != 0
    type = hdr >>> 1 &&& 0x3
    size = hdr >>> 3

    # raw (0) and compressed (2) occupy `size` bytes; RLE (1) occupies exactly one; 3 is
    # reserved.
    on_wire =
      case type do
        0 -> size
        2 -> size
        1 -> 1
        _ -> :reserved
      end

    cond do
      on_wire == :reserved ->
        {:error, :invalid}

      byte_size(rest) < on_wire ->
        {:error, :invalid}

      last ->
        # The 4-byte content checksum, when present, is part of the frame's EXTENT and must
        # actually be present -- a truncated checksum is a truncated frame, not a short one.
        trailer = if checksum, do: 4, else: 0

        if byte_size(rest) - on_wire >= trailer,
          do: {:ok, off + 3 + on_wire + trailer},
          else: {:error, :invalid}

      true ->
        <<_::binary-size(on_wire), tail::binary>> = rest
        blocks(tail, off + 3 + on_wire, checksum)
    end
  end

  defp blocks(_, _, _), do: {:error, :invalid}
end
