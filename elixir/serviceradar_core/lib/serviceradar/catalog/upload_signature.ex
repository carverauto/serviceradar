defmodule ServiceRadar.Catalog.UploadSignature do
  @moduledoc """
  Canonical JSON serialization and Ed25519 signature verification/signing for
  Solution Pack `.srpack.sig` documents (`wasm-plugin-system` & `solution-packs-catalog`).

  Byte-for-byte compatible with `ServiceRadarWebNG.Plugins.UploadSignature`,
  `build/wasm_plugins/upload_signature_tool.go`, and `serviceradar pack sign`:
  - Canonical verification payload:
    `{"content_hash":"<64-hex-sha256>","manifest":<canonical-manifest>}`
    serialized with lexicographically sorted object keys at every nesting level,
    minimal RFC 8259 string escaping (literal `<`, `>`, `&`, no HTML escaping),
    and no trailing newline.
  - Verified directly via `:crypto.verify(:eddsa, :none, payload, sig, [pub, :ed25519])`
    so `serviceradar_core` never depends upward on `serviceradar_web_ng`.
  """

  @supported_algorithm "ed25519"
  @ed25519_public_key_bytes 32
  @ed25519_seed_bytes 32
  @ed25519_signature_bytes 64

  @doc """
  Verifies a decoded signature map against `manifest`, `content_hash`, and
  `trusted_keys` (`%{key_id => base64_or_hex_public_key}`).
  """
  @spec verify(map() | nil, map(), String.t(), map()) :: :ok | {:error, atom()}
  def verify(signature, manifest, content_hash, trusted_keys)
      when is_map(manifest) and is_binary(content_hash) and is_map(trusted_keys) do
    normalized_keys = normalize_trusted_keys(trusted_keys)
    expected_hash = normalize_content_hash(content_hash)

    with {:ok, normalized} <- normalize_signature(signature),
         :ok <- verify_declared_hash(normalized.content_hash, expected_hash),
         {:ok, public_key} <- fetch_public_key(normalized.key_id, normalized_keys),
         payload = verification_payload(manifest, expected_hash),
         true <-
           byte_size(normalized.signature) == @ed25519_signature_bytes and
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

  def verify(_signature, _manifest, _content_hash, _trusted_keys),
    do: {:error, :invalid_signature}

  @doc """
  Signs `manifest` and `content_hash` with a 32-byte Ed25519 private seed (or
  64-byte expanded private key) and returns a canonical `.srpack.sig` map.
  """
  @spec sign(map(), String.t(), binary(), keyword()) :: {:ok, map()} | {:error, atom()}
  def sign(manifest, content_hash, private_key, opts \\ [])
      when is_map(manifest) and is_binary(content_hash) and is_list(opts) do
    key_id = opts |> Keyword.get(:key_id, "") |> to_string() |> String.trim()
    signer = opts |> Keyword.get(:signer, key_id) |> to_string() |> String.trim()

    with {:ok, seed} <- normalize_private_seed(private_key),
         true <- key_id != "" do
      normalized_hash = normalize_content_hash(content_hash)
      payload = verification_payload(manifest, normalized_hash)
      sig_bytes = :crypto.sign(:eddsa, :none, payload, [seed, :ed25519])

      {:ok,
       %{
         "algorithm" => @supported_algorithm,
         "content_hash" => normalized_hash,
         "key_id" => key_id,
         "signature" => Base.encode64(sig_bytes),
         "signer" => if(signer == "", do: key_id, else: signer)
       }}
    else
      false -> {:error, :key_id_required}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Builds the deterministic canonical UTF-8 JSON bytes signed by Ed25519.
  """
  @spec verification_payload(map(), String.t()) :: binary()
  def verification_payload(manifest, content_hash)
      when is_map(manifest) and is_binary(content_hash) do
    write_canonical_json(%{
      "content_hash" => normalize_content_hash(content_hash),
      "manifest" => canonicalize(manifest)
    })
  end

  @doc """
  Serializes any JSON-compatible term into compact canonical JSON with sorted
  object keys and minimal RFC 8259 string escaping.
  """
  @spec canonical_json(term()) :: binary()
  def canonical_json(value), do: value |> canonicalize() |> write_canonical_json()

  @doc """
  Normalizes a trusted signing key map or keyword/tuple list into trimmed string entries.
  """
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
          {normalized_key_id, normalized_value} ->
            Map.put(acc, normalized_key_id, normalized_value)

          nil ->
            acc
        end

      _other, acc ->
        acc
    end)
  end

  def normalize_trusted_keys(_keys), do: %{}

  defp verify_declared_hash(nil, _expected), do: :ok
  defp verify_declared_hash("", _expected), do: :ok

  defp verify_declared_hash(declared, expected) when is_binary(declared) do
    if normalize_content_hash(declared) == expected do
      :ok
    else
      {:error, :content_hash_mismatch}
    end
  end

  defp normalize_signature(%{} = signature) do
    algorithm = Map.get(signature, "algorithm") || Map.get(signature, :algorithm)
    key_id = Map.get(signature, "key_id") || Map.get(signature, :key_id)
    sig_val = Map.get(signature, "signature") || Map.get(signature, :signature)
    declared_hash = Map.get(signature, "content_hash") || Map.get(signature, :content_hash)

    with {:ok, normalized_algorithm} <- normalize_algorithm(algorithm),
         {:ok, normalized_key_id} <- normalize_key_id(key_id),
         {:ok, decoded_signature} <- decode_value(sig_val) do
      {:ok,
       %{
         algorithm: normalized_algorithm,
         key_id: normalized_key_id,
         content_hash: if(is_binary(declared_hash), do: declared_hash),
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
          {:ok, public_key} when byte_size(public_key) == @ed25519_public_key_bytes ->
            {:ok, public_key}

          _ ->
            {:error, :invalid_verification_key}
        end

      :error ->
        {:error, :untrusted_signer}
    end
  end

  defp normalize_private_seed(raw) when is_binary(raw) and byte_size(raw) == @ed25519_seed_bytes,
    do: {:ok, raw}

  defp normalize_private_seed(<<seed::binary-size(32), _pub::binary-size(32)>>), do: {:ok, seed}

  defp normalize_private_seed(encoded) when is_binary(encoded) do
    case decode_value(encoded) do
      {:ok, <<seed::binary-size(32)>>} -> {:ok, seed}
      {:ok, <<seed::binary-size(32), _pub::binary-size(32)>>} -> {:ok, seed}
      _ -> {:error, :invalid_signing_key}
    end
  end

  defp normalize_private_seed(_other), do: {:error, :invalid_signing_key}

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

  defp canonicalize({:object, entries}), do: {:object, entries}

  defp canonicalize(%{} = map) do
    entries =
      map
      |> Enum.map(fn {key, value} -> {normalize_key(key), canonicalize(value)} end)
      |> Enum.sort_by(&elem(&1, 0))

    {:object, entries}
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(other), do: other

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: to_string(key)

  defp write_canonical_json(%{} = map), do: map |> canonicalize() |> write_canonical_json()

  defp write_canonical_json({:object, entries}) do
    "{" <>
      Enum.map_join(entries, ",", fn {key, value} ->
        Jason.encode!(key) <> ":" <> write_canonical_json(value)
      end) <> "}"
  end

  defp write_canonical_json([]), do: "[]"

  defp write_canonical_json(list) when is_list(list) do
    "[" <> Enum.map_join(list, ",", &write_canonical_json/1) <> "]"
  end

  defp write_canonical_json(other), do: Jason.encode!(other)
end
