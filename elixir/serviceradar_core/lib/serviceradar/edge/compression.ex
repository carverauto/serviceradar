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
  """
  import Bitwise

  # The frozen values. Their normative source is the spec requirement, not this module.
  @max_uncompressed 33_554_432
  @max_ratio 100
  @max_window 33_554_432

  # 1 << 25 = 33_554_432. Defence in depth only -- see the moduledoc.
  @window_log_max 25

  @zstd_magic 0xFD2FB528

  @typedoc """
  Rejection reasons, matching Go's sentinels one-for-one:
  `:invalid` = `ErrZstdInvalid`, `:output_size` = `ErrZstdOutputSize`,
  `:trailing` = `ErrZstdTrailing`.
  """
  @type reason :: :invalid | :output_size | :trailing

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
    with :ok <- declared_in_range(declared),
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

  @doc "The frozen ceilings, so callers and vectors read them from one place."
  @spec limits() :: %{uncompressed: pos_integer(), ratio: pos_integer(), window: pos_integer()}
  def limits, do: %{uncompressed: @max_uncompressed, ratio: @max_ratio, window: @max_window}

  # --- declared size ---------------------------------------------------------------------

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

  # --- the frame walk --------------------------------------------------------------------

  # A port of Go's `zstdFrameLen`: parses ONE standard frame (RFC 8878) and returns its exact
  # encoded length. It does not decompress; it walks the frame header and block headers to
  # find the frame's end offset. A skippable-frame magic, a reserved bit, a reserved block
  # type and truncation are all refused.
  @spec frame_length(binary()) :: {:ok, non_neg_integer()} | {:error, :invalid}
  def frame_length(<<magic::little-32, fhd, rest::binary>>) when magic == @zstd_magic do
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

  def frame_length(_), do: {:error, :invalid}

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
