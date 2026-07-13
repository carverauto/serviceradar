defmodule ServiceRadar.Automation.LaunchEnvelopes.Cipher do
  @moduledoc """
  AES-256-GCM protection for single-resolution automation launch envelopes.

  A purpose-derived key keeps these short-lived callback bearers separate from
  other Cloak ciphertexts even when the deployment uses the same root key. The
  exact launch context is supplied as AEAD additional authenticated data.

  The current implementation intentionally supports one active key ID. Rotating
  that key invalidates outstanding envelopes, whose lifetime is capped at 600
  seconds. Operators must keep the key stable for at least that drain window or
  revoke and relaunch the affected children.
  """

  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON
  alias ServiceRadar.Automation.LaunchEnvelopes.Context

  @cipher_version "aes-256-gcm-hkdf-sha256-v1"
  @default_key_id "current"
  @hkdf_salt :crypto.hash(:sha256, "serviceradar-automation-launch-envelope-hkdf-salt-v1")
  @payload_schema "serviceradar.automation_launch_envelope_payload/v1"
  @reference_prefix "srle1_"
  @idempotency_prefix "srci_v1_"
  @reference_entropy_bytes 32
  @idempotency_entropy_bytes 32
  @iv_bytes 12
  @tag_bytes 16

  @type encrypted :: %{
          ciphertext: binary(),
          cipher_version: binary(),
          cipher_key_id: binary()
        }

  @spec cipher_version() :: binary()
  def cipher_version, do: @cipher_version

  @spec active_key_id(keyword()) :: {:ok, binary()} | {:error, atom()}
  def active_key_id(opts \\ []) do
    key_id =
      Keyword.get(opts, :key_id) ||
        Application.get_env(:serviceradar_core, :automation_launch_envelope_key_id) ||
        @default_key_id

    if is_binary(key_id) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/, key_id),
      do: {:ok, key_id},
      else: {:error, :launch_envelope_key_unavailable}
  end

  @spec issue_reference(keyword()) :: {:ok, binary(), binary()} | {:error, atom()}
  def issue_reference(opts \\ []) do
    random_bytes = Keyword.get(opts, :random_bytes, &:crypto.strong_rand_bytes/1)

    with {:ok, key} <- purpose_key("reference-verifier", opts),
         {:ok, entropy} <- safe_random(random_bytes, @reference_entropy_bytes) do
      reference = @reference_prefix <> Base.url_encode64(entropy, padding: false)
      verifier = :crypto.mac(:hmac, :sha256, key, reference)
      {:ok, reference, verifier}
    end
  end

  @spec reference_verifier(binary(), keyword()) :: {:ok, binary()} | {:error, atom()}
  def reference_verifier(reference, opts \\ [])

  def reference_verifier(reference, opts) when is_binary(reference) do
    with :ok <- validate_reference(reference),
         {:ok, key} <- purpose_key("reference-verifier", opts) do
      {:ok, :crypto.mac(:hmac, :sha256, key, reference)}
    end
  end

  def reference_verifier(_reference, _opts), do: {:error, :invalid_launch_envelope_reference}

  @spec encrypt(binary(), binary(), Context.t(), keyword()) ::
          {:ok, encrypted()} | {:error, atom()}
  def encrypt(bearer, idempotency_key, context, opts \\ [])

  def encrypt(bearer, idempotency_key, %Context{} = context, opts)
      when is_binary(bearer) and is_binary(idempotency_key) do
    random_bytes = Keyword.get(opts, :random_bytes, &:crypto.strong_rand_bytes/1)

    with :ok <- validate_bearer(bearer),
         :ok <- validate_idempotency_key(idempotency_key),
         {:ok, key_id} <- active_key_id(opts),
         {:ok, key} <- purpose_key("payload-encryption", opts),
         {:ok, iv} <- safe_random(random_bytes, @iv_bytes),
         {:ok, plaintext} <-
           payload_bytes(bearer, idempotency_key, context.callback_grant_id) do
      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          key,
          iv,
          plaintext,
          Context.aad(context),
          true
        )

      {:ok,
       %{
         ciphertext: iv <> ciphertext <> tag,
         cipher_version: @cipher_version,
         cipher_key_id: key_id
       }}
    end
  rescue
    _ -> {:error, :launch_envelope_encrypt_failed}
  end

  def encrypt(_bearer, _idempotency_key, _context, _opts), do: {:error, :invalid_callback_bearer}

  @spec decrypt(binary(), binary(), Context.t(), keyword()) ::
          {:ok, %{bearer: binary(), idempotency_key: binary(), callback_grant_id: binary()}}
          | {:error, atom()}
  def decrypt(ciphertext, @cipher_version, %Context{} = context, opts)
      when is_binary(ciphertext) and byte_size(ciphertext) >= @iv_bytes + @tag_bytes do
    with {:ok, key} <- purpose_key("payload-encryption", opts),
         {:ok, plaintext} <- decrypt_bytes(ciphertext, key, Context.aad(context)),
         {:ok, payload} <- Jason.decode(plaintext),
         :ok <- validate_payload(payload, context) do
      {:ok,
       %{
         bearer: Map.fetch!(payload, "bearer"),
         idempotency_key: Map.fetch!(payload, "idempotency_key"),
         callback_grant_id: Map.fetch!(payload, "callback_grant_id")
       }}
    else
      _ -> {:error, :launch_envelope_decrypt_failed}
    end
  rescue
    _ -> {:error, :launch_envelope_decrypt_failed}
  end

  def decrypt(_ciphertext, _version, _context, _opts),
    do: {:error, :launch_envelope_decrypt_failed}

  defp decrypt_bytes(ciphertext, key, aad) do
    <<iv::binary-size(@iv_bytes), rest::binary>> = ciphertext
    encrypted_bytes = byte_size(rest) - @tag_bytes
    <<encrypted::binary-size(encrypted_bytes), tag::binary-size(@tag_bytes)>> = rest

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, encrypted, aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> {:error, :launch_envelope_decrypt_failed}
    end
  end

  defp payload_bytes(bearer, idempotency_key, callback_grant_id) do
    CanonicalJSON.encode(%{
      "schema" => @payload_schema,
      "bearer" => bearer,
      "idempotency_key" => idempotency_key,
      "callback_grant_id" => callback_grant_id
    })
  end

  defp validate_payload(
         %{
           "schema" => @payload_schema,
           "bearer" => bearer,
           "idempotency_key" => idempotency_key,
           "callback_grant_id" => callback_grant_id
         },
         %Context{} = context
       ) do
    with :ok <- validate_bearer(bearer),
         :ok <- validate_idempotency_key(idempotency_key),
         true <- secure_equal?(callback_grant_id, context.callback_grant_id) do
      :ok
    else
      _ -> {:error, :launch_envelope_decrypt_failed}
    end
  end

  defp validate_payload(_payload, _context), do: {:error, :launch_envelope_decrypt_failed}

  defp validate_bearer(bearer) when is_binary(bearer) and byte_size(bearer) == 43 do
    case Base.url_decode64(bearer, padding: false) do
      {:ok, decoded} when byte_size(decoded) == 32 -> :ok
      _ -> {:error, :invalid_callback_bearer}
    end
  end

  defp validate_bearer(_bearer), do: {:error, :invalid_callback_bearer}

  defp validate_idempotency_key(@idempotency_prefix <> encoded = key)
       when byte_size(key) == byte_size(@idempotency_prefix) + 43 do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, decoded} when byte_size(decoded) == @idempotency_entropy_bytes -> :ok
      _ -> {:error, :invalid_callback_idempotency_key}
    end
  end

  defp validate_idempotency_key(_key), do: {:error, :invalid_callback_idempotency_key}

  defp validate_reference(reference) do
    with true <- String.starts_with?(reference, @reference_prefix),
         encoded = String.replace_prefix(reference, @reference_prefix, ""),
         {:ok, decoded} <- Base.url_decode64(encoded, padding: false),
         true <- byte_size(decoded) == @reference_entropy_bytes do
      :ok
    else
      _ -> {:error, :invalid_launch_envelope_reference}
    end
  end

  defp safe_random(random_bytes, size) when is_function(random_bytes, 1) do
    case random_bytes.(size) do
      bytes when is_binary(bytes) and byte_size(bytes) == size -> {:ok, bytes}
      _ -> {:error, :insufficient_launch_envelope_entropy}
    end
  rescue
    _ -> {:error, :launch_envelope_random_failed}
  end

  defp purpose_key(purpose, opts) do
    with {:ok, root_key} <- root_key(opts) do
      # RFC 5869 HKDF-Extract + the first HKDF-Expand block. SHA-256 output is
      # exactly the 32 bytes required by AES-256, so no second block is needed.
      pseudorandom_key = :crypto.mac(:hmac, :sha256, @hkdf_salt, root_key)

      {:ok,
       :crypto.mac(
         :hmac,
         :sha256,
         pseudorandom_key,
         "serviceradar-automation-launch-envelope-v1\0" <> purpose <> <<1>>
       )}
    end
  end

  defp root_key(opts) do
    opts
    |> Keyword.get(:encryption_key)
    |> Kernel.||(configured_key())
    |> decode_key()
  end

  defp configured_key do
    Application.get_env(:serviceradar_core, :automation_launch_envelope_key)
  end

  defp decode_key(key) when is_binary(key) and byte_size(key) == 32, do: {:ok, key}

  defp decode_key(key) when is_binary(key) do
    case Base.decode64(String.trim(key)) do
      {:ok, decoded} when byte_size(decoded) == 32 -> {:ok, decoded}
      _ -> {:error, :launch_envelope_key_unavailable}
    end
  end

  defp decode_key(_key), do: {:error, :launch_envelope_key_unavailable}

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_equal?(_left, _right), do: false
end
