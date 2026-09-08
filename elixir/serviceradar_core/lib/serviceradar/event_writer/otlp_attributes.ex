defmodule ServiceRadar.EventWriter.OtlpAttributes do
  @moduledoc """
  Shared helpers for converting OTLP protobuf attribute structures
  (`KeyValue` / `AnyValue`) into plain Elixir terms, plus the canonical
  byte encoding used for `attributes_hash` (recipe v2).

  ## attributes_hash recipe v2 (cross-language contract)

  This recipe is implemented IDENTICALLY by the Go gateway. Do not change
  one side without the other.

      hash_input = canonical_bytes(point_attributes)
                   <> "\\n" <> service_instance_id
                   <> "\\n" <> scope_name
      attributes_hash = lowercase_hex(md5(hash_input))

  `canonical_bytes/1` rules, applied recursively at every nesting level:

  - map    -> `{` + entries sorted by key bytes, each `enc(key) <> ":" <>
              enc(value)`, joined with `,` + `}`
  - string -> `"` <> escaped <> `"` where ONLY backslash and double-quote
              are escaped (`\\\\` and `\\"`)
  - bool   -> `true` / `false`
  - nil    -> `null`
  - int    -> base-10 ASCII
  - float  -> `f` <> 16-char lowercase hex of the IEEE-754 double
              big-endian bits (no decimal text, eliminating float-format
              divergence between languages)
  - bytes  -> `b` <> standard Base64. OTLP `bytes_value` terms are
              type-tagged as `{:bytes, binary}` by
              `key_values_to_canonical_map/1` and ALWAYS take this rule —
              even when the payload is valid UTF-8 — matching the Go
              writer's `[]byte` case. (Untagged non-UTF8 binaries also
              fall back to this rule defensively.)
  - array  -> `[` + encoded items joined with `,` + `]`

  Use `key_values_to_canonical_map/1` (which preserves OTLP `bytes_value`
  as tagged bytes) to build the hash input, and `stable_json/1` for the
  stored display JSON (sorted keys at every level; bytes shown as Base64
  strings).
  """

  alias Opentelemetry.Proto.Common.V1.AnyValue
  alias Opentelemetry.Proto.Common.V1.ArrayValue
  alias Opentelemetry.Proto.Common.V1.KeyValue
  alias Opentelemetry.Proto.Common.V1.KeyValueList

  @doc """
  Converts a list of OTLP `KeyValue` structs into a plain map.
  """
  @spec key_values_to_map(term()) :: map()
  def key_values_to_map(values) when is_list(values) do
    Enum.reduce(values, %{}, fn
      %KeyValue{key: key, value: value}, acc when is_binary(key) and key != "" ->
        Map.put(acc, key, any_value_to_term(value))

      _, acc ->
        acc
    end)
  end

  def key_values_to_map(_), do: %{}

  @doc """
  Converts an OTLP `AnyValue` into a plain Elixir term.
  """
  @spec any_value_to_term(term()) :: term()
  def any_value_to_term(%AnyValue{value: {:string_value, value}}), do: value
  def any_value_to_term(%AnyValue{value: {:bool_value, value}}), do: value
  def any_value_to_term(%AnyValue{value: {:int_value, value}}), do: value
  def any_value_to_term(%AnyValue{value: {:double_value, value}}), do: value

  def any_value_to_term(%AnyValue{value: {:bytes_value, value}}) when is_binary(value),
    do: Base.encode64(value)

  def any_value_to_term(%AnyValue{value: {:array_value, %ArrayValue{values: values}}}) do
    Enum.map(values, &any_value_to_term/1)
  end

  def any_value_to_term(%AnyValue{value: {:kvlist_value, %KeyValueList{values: values}}}) do
    key_values_to_map(values)
  end

  def any_value_to_term(_), do: nil

  @doc """
  Converts a list of OTLP `KeyValue` structs into a plain map, preserving
  `bytes_value` as type-tagged `{:bytes, binary}` terms (the
  display-oriented `key_values_to_map/1` Base64-encodes them). This is the
  input shape for `canonical_bytes/1` and `attributes_hash/3`; the tag
  keeps OTLP bytes values type-preserving so they ALWAYS take the
  `b` + Base64 canonical rule, exactly like the Go writer's `[]byte` case,
  even when the payload happens to be valid UTF-8.
  """
  @spec key_values_to_canonical_map(term()) :: map()
  def key_values_to_canonical_map(values) when is_list(values) do
    Enum.reduce(values, %{}, fn
      %KeyValue{key: key, value: value}, acc when is_binary(key) and key != "" ->
        Map.put(acc, key, any_value_to_canonical_term(value))

      _, acc ->
        acc
    end)
  end

  def key_values_to_canonical_map(_), do: %{}

  @doc """
  Converts an OTLP `AnyValue` into a plain Elixir term, preserving
  `bytes_value` as `{:bytes, binary}`.
  """
  @spec any_value_to_canonical_term(term()) :: term()
  def any_value_to_canonical_term(%AnyValue{value: {:bytes_value, value}}) when is_binary(value),
    do: {:bytes, value}

  def any_value_to_canonical_term(%AnyValue{value: {:array_value, %ArrayValue{values: values}}}) do
    Enum.map(values, &any_value_to_canonical_term/1)
  end

  def any_value_to_canonical_term(%AnyValue{
        value: {:kvlist_value, %KeyValueList{values: values}}
      }) do
    key_values_to_canonical_map(values)
  end

  def any_value_to_canonical_term(other), do: any_value_to_term(other)

  @doc """
  Computes the recipe-v2 `attributes_hash` (lowercase hex MD5) from a
  canonical attribute map plus the identity inputs. See the moduledoc for
  the cross-language contract.
  """
  @spec attributes_hash(map(), String.t() | nil, String.t() | nil) :: String.t()
  def attributes_hash(attributes, service_instance_id, scope_name) do
    input = [
      canonical_bytes(attributes),
      "\n",
      service_instance_id || "",
      "\n",
      scope_name || ""
    ]

    :md5 |> :crypto.hash(input) |> Base.encode16(case: :lower)
  end

  @doc """
  Deterministic canonical byte encoding of an attribute term. See the
  moduledoc for the exact rules; this MUST stay in lockstep with the Go
  implementation.
  """
  @spec canonical_bytes(term()) :: binary()
  def canonical_bytes(term), do: term |> canonical_iodata() |> IO.iodata_to_binary()

  defp canonical_iodata(map) when is_map(map) do
    entries =
      map
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(fn key ->
        [canonical_iodata(key), ":", canonical_iodata(Map.fetch!(map, key))]
      end)

    ["{", Enum.intersperse(entries, ","), "}"]
  end

  defp canonical_iodata(list) when is_list(list) do
    ["[", Enum.map_intersperse(list, ",", &canonical_iodata/1), "]"]
  end

  defp canonical_iodata(true), do: "true"
  defp canonical_iodata(false), do: "false"
  defp canonical_iodata(nil), do: "null"
  defp canonical_iodata(int) when is_integer(int), do: Integer.to_string(int)

  defp canonical_iodata(float) when is_float(float),
    do: ["f", Base.encode16(<<float::float-64>>, case: :lower)]

  # Type-tagged OTLP bytes values always take the bytes rule, matching the
  # Go writer's []byte case regardless of UTF-8 validity.
  defp canonical_iodata({:bytes, binary}) when is_binary(binary), do: ["b", Base.encode64(binary)]

  defp canonical_iodata(binary) when is_binary(binary) do
    if String.valid?(binary) do
      [?", escape_canonical_string(binary), ?"]
    else
      # Defensive: proto3 strings are UTF-8, but never emit invalid bytes.
      ["b", Base.encode64(binary)]
    end
  end

  defp escape_canonical_string(string) do
    string
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  @doc """
  Deterministic display JSON for stored attribute columns: standard JSON,
  but with map keys sorted bytewise at EVERY nesting level (built from
  sorted key lists rather than map order, so maps with more than 32 keys
  stay stable) and non-UTF8 binaries rendered as Base64 strings.
  """
  @spec stable_json(term()) :: String.t()
  def stable_json(term), do: term |> stable_json_iodata() |> IO.iodata_to_binary()

  defp stable_json_iodata(map) when is_map(map) do
    entries =
      map
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(fn key ->
        [stable_json_iodata(key), ":", stable_json_iodata(Map.fetch!(map, key))]
      end)

    ["{", Enum.intersperse(entries, ","), "}"]
  end

  defp stable_json_iodata(list) when is_list(list) do
    ["[", Enum.map_intersperse(list, ",", &stable_json_iodata/1), "]"]
  end

  defp stable_json_iodata({:bytes, binary}) when is_binary(binary),
    do: Jason.encode_to_iodata!(Base.encode64(binary))

  defp stable_json_iodata(binary) when is_binary(binary) do
    if String.valid?(binary) do
      Jason.encode_to_iodata!(binary)
    else
      Jason.encode_to_iodata!(Base.encode64(binary))
    end
  end

  defp stable_json_iodata(other), do: Jason.encode_to_iodata!(other)
end
