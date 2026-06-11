defmodule ServiceRadar.EventWriter.OtelId do
  @moduledoc """
  Canonical OTel identifier normalization.

  The canonical contract shared across the whole pipeline:

  - `trace_id` is a 32-character lowercase hex string
  - `span_id` / `parent_span_id` are 16-character lowercase hex strings
  - absent/invalid/zero identifiers are `nil` (stored as SQL NULL)

  Incoming values can arrive in several encodings, depending on producer:

  - raw OTLP bytes (16 bytes trace / 8 bytes span)
  - ASCII hex text in OTLP bytes fields (the Erlang OTLP logs exporter
    `otel_otlp_logs.erl` copies hex Logger metadata verbatim into the
    protobuf bytes fields)
  - already-hex JSON strings, possibly uppercase
  - legacy double-hex strings (hex encoding of the ASCII hex string),
    arriving via JSON re-publication of previously mis-encoded rows
  - standard base64 (common when protobuf bytes round-trip through JSON)

  Normalization is intentionally idempotent: feeding an already-canonical
  id back through any of these functions returns it unchanged, and hex
  text is never hex-encoded a second time.
  """

  @doc """
  Normalizes a trace id to 32-character lowercase hex, or `nil`.
  """
  @spec normalize_trace_id(term()) :: String.t() | nil
  def normalize_trace_id(value), do: normalize(value, 16)

  @doc """
  Normalizes a span id to 16-character lowercase hex, or `nil`.
  """
  @spec normalize_span_id(term()) :: String.t() | nil
  def normalize_span_id(value), do: normalize(value, 8)

  @doc """
  Normalizes a parent span id to 16-character lowercase hex, or `nil`.

  All-zero parents (the protobuf encoding of "no parent") and empty
  values normalize to `nil`, so root spans always store NULL.
  """
  @spec normalize_parent_span_id(term()) :: String.t() | nil
  def normalize_parent_span_id(value), do: normalize(value, 8)

  # byte_len is the raw OTLP byte length: 16 for trace ids, 8 for span ids.
  defp normalize(nil, _byte_len), do: nil
  defp normalize("", _byte_len), do: nil

  defp normalize(value, byte_len) when is_binary(value) do
    hex_len = byte_len * 2

    cond do
      # Already-hex text (CRITICAL: prevents double-hex encoding).
      byte_size(value) == hex_len and hex?(value) ->
        finalize(String.downcase(value))

      # Legacy double-hex: hex encoding of the ASCII hex string.
      byte_size(value) == hex_len * 2 and hex?(value) ->
        decode_double_hex(value, hex_len)

      # Raw OTLP bytes.
      byte_size(value) == byte_len ->
        finalize(Base.encode16(value, case: :lower))

      # Standard base64 of the raw bytes.
      true ->
        decode_base64(value, byte_len)
    end
  end

  defp normalize(_value, _byte_len), do: nil

  defp decode_double_hex(value, hex_len) do
    case Base.decode16(value, case: :mixed) do
      {:ok, decoded} when byte_size(decoded) == hex_len ->
        if hex?(decoded) do
          finalize(String.downcase(decoded))
        end

      _ ->
        nil
    end
  end

  defp decode_base64(value, byte_len) do
    case Base.decode64(value) do
      {:ok, decoded} when byte_size(decoded) == byte_len ->
        finalize(Base.encode16(decoded, case: :lower))

      _ ->
        nil
    end
  end

  defp finalize(hex) do
    if all_zero?(hex), do: nil, else: hex
  end

  defp hex?(value) do
    for(<<char <- value>>, reduce: true) do
      acc -> acc and hex_char?(char)
    end
  end

  defp hex_char?(char) when char in ?0..?9 when char in ?a..?f when char in ?A..?F, do: true

  defp hex_char?(_char), do: false

  defp all_zero?(hex) do
    for(<<char <- hex>>, reduce: true) do
      acc -> acc and char == ?0
    end
  end
end
