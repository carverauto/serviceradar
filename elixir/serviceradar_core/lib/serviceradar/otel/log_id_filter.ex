defmodule ServiceRadar.Otel.LogIdFilter do
  @moduledoc """
  Handler-scoped `:logger` filter that rewrites OTel trace/span id logger
  metadata from lowercase hex text into raw bytes before OTLP log export.

  ## Why this exists (upstream encoding bug workaround)

  `otel_span:hex_span_ctx/1` (deps/opentelemetry_api/src/otel_span.erl)
  intentionally puts lowercase *hex text* into the `otel_trace_id` /
  `otel_span_id` Logger metadata keys "because the main use of this function
  is logger metadata" (human-readable console/JSON logs). The OTLP logs
  encoder `otel_otlp_logs.erl:91-94` (opentelemetry_experimental) then copies
  those metadata values *verbatim* into the protobuf
  `LogRecord.trace_id`/`span_id` BYTES fields. The wire therefore carries
  32 ASCII-hex bytes instead of the 16 raw trace-id bytes (32 -> 16, and
  16 -> 8 for span ids). Downstream consumers hex-encode the bytes field
  exactly once and persist 64-char ids that can never join `otel_traces`.

  This filter is attached ONLY to the OTel log handler (see
  `ServiceRadar.Telemetry.OtelSetup`), so the console/JSON handlers keep the
  human-readable hex metadata. It converts:

    * `otel_trace_id`: 32-char hex (binary or charlist) -> 16 raw bytes
    * `otel_span_id`: 16-char hex (binary or charlist) -> 8 raw bytes

  Values that are already raw bytes, absent, or malformed are left untouched.

  Remove once the upstream encoding bug in `opentelemetry_experimental` is
  fixed (issue to be filed against open-telemetry/opentelemetry-erlang).
  """

  @trace_id_hex_size 32
  @span_id_hex_size 16

  @doc """
  `:logger` filter callback (arity-2 filter fun contract).

  Always returns the (possibly rewritten) log event; never returns `:stop`
  or `:ignore`, so it cannot suppress log export.
  """
  @spec filter(:logger.log_event(), term()) :: :logger.log_event()
  def filter(%{meta: meta} = log_event, _arg) when is_map(meta) do
    %{log_event | meta: transform_metadata(meta)}
  end

  def filter(log_event, _arg), do: log_event

  @doc """
  Rewrites `otel_trace_id`/`otel_span_id` hex-text metadata values to raw
  bytes. Pure function, exposed for unit testing.
  """
  @spec transform_metadata(map()) :: map()
  def transform_metadata(meta) when is_map(meta) do
    meta
    |> rewrite_id(:otel_trace_id, @trace_id_hex_size)
    |> rewrite_id(:otel_span_id, @span_id_hex_size)
  end

  defp rewrite_id(meta, key, hex_size) do
    case meta do
      %{^key => value} ->
        case decode_hex_id(value, hex_size) do
          {:ok, bytes} -> Map.put(meta, key, bytes)
          :error -> meta
        end

      _ ->
        meta
    end
  end

  # A raw-bytes id (16/8 bytes) can never match the hex length (32/16), so
  # already-correct values fall through to :error and stay untouched.
  defp decode_hex_id(value, hex_size) when is_binary(value) and byte_size(value) == hex_size do
    Base.decode16(value, case: :mixed)
  end

  defp decode_hex_id(value, hex_size) when is_list(value) do
    decode_hex_id(IO.iodata_to_binary(value), hex_size)
  rescue
    ArgumentError -> :error
  end

  defp decode_hex_id(_value, _hex_size), do: :error
end
