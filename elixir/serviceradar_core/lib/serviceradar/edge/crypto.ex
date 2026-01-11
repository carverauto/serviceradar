defmodule ServiceRadar.Edge.Crypto do
  @moduledoc """
  Cryptographic utilities for edge onboarding tokens.

  Provides functions for:
  - Generating secure random tokens
  - Encrypting/decrypting sensitive data (join tokens, bundles)
  - Hashing and verifying download tokens

  ## Encryption

  Uses AES-256-GCM for symmetric encryption. The encryption key is derived from
  a secret configured via application config.

  ## Token Hashing

  Download tokens are hashed using SHA-256 for secure storage and verification.

  ## Configuration

  Configure the encryption secret in your config:

      config :serviceradar_core, :crypto_secret, "your-32-byte-minimum-secret"

  Or via an endpoint's secret_key_base:

      config :serviceradar_core, :crypto_secret_source, {:app_env, :my_app, MyAppWeb.Endpoint, :secret_key_base}
  """

  @token_length 32
  @aad "serviceradar-edge-onboarding"

  @doc """
  Generates a cryptographically secure random token.

  Returns a URL-safe base64-encoded string.
  """
  @spec generate_token() :: String.t()
  def generate_token do
    @token_length
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Encrypts plaintext data using AES-256-GCM.

  Returns a base64-encoded string containing the IV, ciphertext, and auth tag.
  """
  @spec encrypt(String.t()) :: String.t()
  def encrypt(plaintext) when is_binary(plaintext) do
    key = encryption_key()
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, true)

    # Combine IV + ciphertext + tag and base64 encode
    (iv <> ciphertext <> tag)
    |> Base.encode64()
  end

  @doc """
  Decrypts data encrypted with `encrypt/1`.

  Returns the original plaintext or raises on decryption failure.
  """
  @spec decrypt(String.t()) :: String.t()
  def decrypt(encoded) when is_binary(encoded) do
    key = encryption_key()

    with {:ok, data} <- Base.decode64(encoded),
         true <- byte_size(data) >= 28 do
      # Extract IV (12 bytes), tag (16 bytes), and ciphertext
      <<iv::binary-12, rest::binary>> = data
      ciphertext_size = byte_size(rest) - 16
      <<ciphertext::binary-size(ciphertext_size), tag::binary-16>> = rest

      case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
        plaintext when is_binary(plaintext) -> plaintext
        :error -> raise "Decryption failed: invalid ciphertext or key"
      end
    else
      _ -> raise "Decryption failed: invalid encoded data"
    end
  end

  @doc """
  Safely decrypts data, returning `{:ok, plaintext}` or `{:error, reason}`.
  """
  @spec decrypt_safe(String.t()) :: {:ok, String.t()} | {:error, :decrypt_failed}
  def decrypt_safe(encoded) do
    {:ok, decrypt(encoded)}
  rescue
    _ -> {:error, :decrypt_failed}
  end

  @doc """
  Hashes a download token for secure storage using SHA-256.

  Returns a hex-encoded hash string.
  """
  @spec hash_token(String.t()) :: String.t()
  def hash_token(token) when is_binary(token) do
    :crypto.hash(:sha256, token)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Verifies that a plaintext token matches a stored hash.
  """
  @spec verify_token(String.t(), String.t()) :: boolean()
  def verify_token(token, stored_hash) when is_binary(token) and is_binary(stored_hash) do
    computed_hash = hash_token(token)
    secure_compare(computed_hash, stored_hash)
  end

  def verify_token(_, _), do: false

  # Private functions

  defp encryption_key do
    secret = get_secret()

    if is_nil(secret) or byte_size(secret) < 32 do
      raise "crypto_secret must be configured and at least 32 bytes"
    end

    # Use HKDF to derive a key specific to edge onboarding
    :crypto.mac(:hmac, :sha256, "serviceradar-edge-key", secret)
  end

  defp get_secret do
    # First check for direct secret
    case Application.get_env(:serviceradar_core, :crypto_secret) do
      nil ->
        # Fall back to secret source (e.g., Phoenix endpoint)
        case Application.get_env(:serviceradar_core, :crypto_secret_source) do
          {:app_env, app, module, key} ->
            config = Application.get_env(app, module, [])
            Keyword.get(config, key)

          nil ->
            # Try common Phoenix endpoint patterns
            try_phoenix_secret()
        end

      secret ->
        secret
    end
  end

  defp try_phoenix_secret do
    # Try common Phoenix endpoint configurations
    with nil <- get_endpoint_secret(:serviceradar_web_ng, ServiceRadarWebNGWeb.Endpoint),
         nil <- get_endpoint_secret(:serviceradar_web, ServiceRadarWeb.Endpoint) do
      nil
    end
  end

  defp get_endpoint_secret(app, endpoint) do
    case Application.get_env(app, endpoint) do
      nil -> nil
      config -> Keyword.get(config, :secret_key_base)
    end
  rescue
    _ -> nil
  end

  # Constant-time comparison to prevent timing attacks
  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    a_bytes = :binary.bin_to_list(a)
    b_bytes = :binary.bin_to_list(b)

    result =
      Enum.zip(a_bytes, b_bytes)
      |> Enum.reduce(0, fn {x, y}, acc -> Bitwise.bor(acc, Bitwise.bxor(x, y)) end)

    result == 0
  end

  defp secure_compare(_, _), do: false
end
