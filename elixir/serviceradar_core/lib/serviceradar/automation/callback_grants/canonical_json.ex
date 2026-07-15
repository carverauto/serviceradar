defmodule ServiceRadar.Automation.CallbackGrants.CanonicalJSON do
  @moduledoc """
  Encodes the deliberately small JSON subset used by automation callbacks.

  Object keys are UTF-8 strings sorted by byte value. Integers, booleans,
  strings, null, arrays, and objects are supported; floats are rejected so a
  response fingerprint cannot vary by runtime-specific number formatting.
  """

  @type json_value ::
          nil
          | boolean()
          | integer()
          | binary()
          | [json_value()]
          | %{optional(binary() | atom()) => json_value()}

  @spec encode(json_value()) :: {:ok, binary()} | {:error, term()}
  def encode(value) do
    with {:ok, iodata} <- encode_value(value) do
      {:ok, IO.iodata_to_binary(iodata)}
    end
  end

  @spec encode!(json_value()) :: binary()
  def encode!(value) do
    case encode(value) do
      {:ok, encoded} ->
        encoded

      {:error, _reason} ->
        raise ArgumentError, "cannot canonically encode JSON"
    end
  end

  @spec digest(json_value()) :: {:ok, binary()} | {:error, term()}
  def digest(value) do
    with {:ok, encoded} <- encode(value) do
      {:ok, sha256(encoded)}
    end
  end

  @spec sha256(iodata()) :: binary()
  def sha256(value) do
    value
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp encode_value(nil), do: {:ok, "null"}
  defp encode_value(true), do: {:ok, "true"}
  defp encode_value(false), do: {:ok, "false"}
  defp encode_value(value) when is_integer(value), do: {:ok, Integer.to_string(value)}

  defp encode_value(value) when is_binary(value) do
    if String.valid?(value), do: {:ok, Jason.encode!(value)}, else: {:error, :invalid_utf8}
  end

  defp encode_value(value) when is_list(value) do
    with {:ok, encoded} <- encode_list(value, []) do
      {:ok, ["[", Enum.intersperse(Enum.reverse(encoded), ","), "]"]}
    end
  end

  defp encode_value(value) when is_map(value) do
    with {:ok, entries} <- normalized_entries(value),
         {:ok, encoded} <- encode_entries(entries, []) do
      {:ok, ["{", Enum.intersperse(Enum.reverse(encoded), ","), "}"]}
    end
  end

  defp encode_value(value) when is_float(value), do: {:error, :floats_not_supported}
  defp encode_value(_value), do: {:error, :unsupported_json_value}

  defp encode_list([], encoded), do: {:ok, encoded}

  defp encode_list([value | rest], encoded) do
    with {:ok, item} <- encode_value(value) do
      encode_list(rest, [item | encoded])
    end
  end

  defp normalized_entries(map) do
    map
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, key} <- normalize_key(key),
           false <- Map.has_key?(acc, key) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        true -> {:halt, {:error, {:duplicate_object_key, normalize_key_value(key)}}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.sort_by(normalized, &elem(&1, 0))}
      error -> error
    end
  end

  defp encode_entries([], encoded), do: {:ok, encoded}

  defp encode_entries([{key, value} | rest], encoded) do
    with {:ok, item} <- encode_value(value) do
      encode_entries(rest, [[Jason.encode!(key), ":", item] | encoded])
    end
  end

  defp normalize_key(key) when is_binary(key) do
    if String.valid?(key), do: {:ok, key}, else: {:error, :invalid_utf8_key}
  end

  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(_key), do: {:error, :object_keys_must_be_strings}

  defp normalize_key_value(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key_value(key), do: key
end
