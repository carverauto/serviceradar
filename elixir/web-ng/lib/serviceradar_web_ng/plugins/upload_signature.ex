defmodule ServiceRadarWebNG.Plugins.UploadSignature do
  @moduledoc false

  @supported_algorithm "ed25519"

  @spec verify(map() | nil, map(), String.t(), map()) :: :ok | {:error, atom()}
  def verify(signature, manifest, content_hash, trusted_keys)
      when is_map(manifest) and is_binary(content_hash) and is_map(trusted_keys) do
    with {:ok, normalized} <- normalize_signature(signature),
         {:ok, public_key} <- fetch_public_key(normalized.key_id, trusted_keys),
         payload = verification_payload(manifest, content_hash),
         true <-
           :crypto.verify(
             :eddsa,
             :none,
             payload,
             normalized.signature,
             [public_key, :ed25519]
           ) do
      :ok
    else
      false -> {:error, :invalid_signature}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify(_signature, _manifest, _content_hash, _trusted_keys), do: {:error, :invalid_signature}

  @spec verification_payload(map(), String.t()) :: binary()
  def verification_payload(manifest, content_hash) when is_map(manifest) and is_binary(content_hash) do
    write_canonical_json(%{"content_hash" => normalize_content_hash(content_hash), "manifest" => canonicalize(manifest)})
  end

  @spec normalize_trusted_keys(map() | list()) :: map()
  def normalize_trusted_keys(keys) when is_map(keys) do
    Enum.reduce(keys, %{}, fn {key_id, value}, acc ->
      case normalize_key_entry(key_id, value) do
        {normalized_key_id, normalized_value} -> Map.put(acc, normalized_key_id, normalized_value)
        nil -> acc
      end
    end)
  end

  def normalize_trusted_keys(keys) when is_list(keys) do
    Enum.reduce(keys, %{}, fn
      {key_id, value}, acc ->
        case normalize_key_entry(key_id, value) do
          {normalized_key_id, normalized_value} -> Map.put(acc, normalized_key_id, normalized_value)
          nil -> acc
        end

      _value, acc ->
        acc
    end)
  end

  def normalize_trusted_keys(_keys), do: %{}

  defp normalize_signature(%{} = signature) do
    algorithm =
      Map.get(signature, "algorithm") ||
        Map.get(signature, :algorithm)

    key_id =
      Map.get(signature, "key_id") ||
        Map.get(signature, :key_id)

    signature_value =
      Map.get(signature, "signature") ||
        Map.get(signature, :signature)

    with {:ok, normalized_algorithm} <- normalize_algorithm(algorithm),
         {:ok, normalized_key_id} <- normalize_key_id(key_id),
         {:ok, decoded_signature} <- decode_value(signature_value) do
      {:ok,
       %{
         algorithm: normalized_algorithm,
         key_id: normalized_key_id,
         signature: decoded_signature
       }}
    end
  end

  defp normalize_signature(_signature), do: {:error, :signature_required}

  defp normalize_algorithm(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      @supported_algorithm -> {:ok, @supported_algorithm}
      "" -> {:error, :signature_required}
      _ -> {:error, :unsupported_signature_algorithm}
    end
  end

  defp normalize_algorithm(_value), do: {:error, :signature_required}

  defp normalize_key_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :signature_required}
      key_id -> {:ok, key_id}
    end
  end

  defp normalize_key_id(_value), do: {:error, :signature_required}

  defp fetch_public_key(key_id, trusted_keys) do
    case Map.fetch(trusted_keys, key_id) do
      {:ok, encoded_key} ->
        case decode_value(encoded_key) do
          {:ok, public_key} when byte_size(public_key) == 32 -> {:ok, public_key}
          {:ok, _public_key} -> {:error, :invalid_verification_key}
          {:error, _reason} -> {:error, :invalid_verification_key}
        end

      :error ->
        {:error, :untrusted_signer}
    end
  end

  defp decode_value(value) when is_binary(value) do
    clean = String.trim(value)

    if clean == "" do
      {:error, :signature_required}
    else
      decode_variants(clean)
    end
  end

  defp decode_value(_value), do: {:error, :signature_required}

  defp decode_variants(value) do
    decoders = [
      &Base.decode16(&1, case: :mixed),
      &Base.decode64/1,
      &Base.decode64(&1, padding: false),
      &Base.url_decode64/1,
      &Base.url_decode64(&1, padding: false)
    ]

    Enum.find_value(decoders, {:error, :invalid_signature_encoding}, fn decoder ->
      case decoder.(value) do
        {:ok, decoded} -> {:ok, decoded}
        :error -> nil
      end
    end)
  end

  defp normalize_key_entry(key_id, value) when is_binary(key_id) and is_binary(value) do
    normalized_key_id = String.trim(key_id)
    normalized_value = String.trim(value)

    if normalized_key_id == "" or normalized_value == "" do
      nil
    else
      {normalized_key_id, normalized_value}
    end
  end

  defp normalize_key_entry(_key_id, _value), do: nil

  defp normalize_content_hash(content_hash) do
    content_hash
    |> String.trim()
    |> String.downcase()
  end

  defp canonicalize(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {normalize_key(key), canonicalize(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(other), do: other

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: to_string(key)

  defp write_canonical_json(%{} = map), do: map |> canonicalize() |> write_canonical_json()

  defp write_canonical_json(list) when is_list(list) do
    if Enum.all?(list, &match?({_, _}, &1)) do
      "{" <>
        Enum.map_join(list, ",", fn {key, value} ->
          Jason.encode!(key) <> ":" <> write_canonical_json(value)
        end) <> "}"
    else
      "[" <> Enum.map_join(list, ",", &write_canonical_json/1) <> "]"
    end
  end

  defp write_canonical_json(other), do: Jason.encode!(other)
end
