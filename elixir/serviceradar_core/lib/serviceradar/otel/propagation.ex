defmodule ServiceRadar.Otel.Propagation do
  @moduledoc """
  W3C trace-context propagation helpers for internal async hops (NATS).

  NATS message headers are the carrier: publishers call `inject_headers/1`
  to stamp `traceparent`/`tracestate` onto outbound messages and consumers
  call `extract_context/1` to attach the remote parent before starting
  their own spans, so async hops stay part of one trace instead of every
  service emitting disconnected single-span roots.

  Both functions delegate to the propagators configured in the
  `:opentelemetry` application environment (`tracecontext` + `baggage` by
  default), so they are no-ops when no propagator or active span context is
  present.
  """

  @typedoc "NATS-style header list (Gnat `:headers` publish option)."
  @type headers :: [{binary(), binary()}]

  @doc """
  Merges `traceparent`/`tracestate` headers for the active span context into
  the given NATS header list.

  Returns the header list unchanged when there is no active (valid) span
  context, so callers can cheaply detect "nothing to add". Existing
  `traceparent`/`tracestate` entries are replaced (case-insensitively) by the
  propagator rather than duplicated.
  """
  @spec inject_headers(headers()) :: headers()
  def inject_headers(headers \\ []) when is_list(headers) do
    :otel_propagator_text_map.inject(headers)
  end

  @doc """
  Extracts W3C trace context from NATS message headers and attaches it to the
  current process context as the remote parent.

  Accepts a Gnat-style header list or a map (some transports surface headers
  as maps). Malformed or absent `traceparent` headers leave the current
  context untouched. Returns `:ok` always.
  """
  @spec extract_context(headers() | %{optional(binary()) => binary()}) :: :ok
  def extract_context(headers) do
    case normalize_headers(headers) do
      [] ->
        :ok

      carrier ->
        :otel_propagator_text_map.extract(carrier)
        :ok
    end
  end

  defp normalize_headers(headers) when is_map(headers) do
    headers
    |> Enum.map(fn {key, value} -> {key, value} end)
    |> normalize_headers()
  end

  defp normalize_headers(headers) when is_list(headers) do
    Enum.flat_map(headers, fn
      {key, value} ->
        case {normalize_part(key), normalize_part(value)} do
          {nil, _} -> []
          {_, nil} -> []
          {k, v} -> [{k, v}]
        end

      _other ->
        []
    end)
  end

  defp normalize_headers(_headers), do: []

  defp normalize_part(value) when is_binary(value), do: value
  defp normalize_part(value) when is_atom(value), do: Atom.to_string(value)

  defp normalize_part(value) when is_list(value) do
    IO.iodata_to_binary(value)
  rescue
    ArgumentError -> nil
  end

  defp normalize_part(_value), do: nil
end
