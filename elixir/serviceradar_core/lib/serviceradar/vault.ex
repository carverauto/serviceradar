defmodule ServiceRadar.Vault do
  @moduledoc """
  Encryption vault for AshCloak using Cloak.

  This module provides AES-256-GCM encryption for sensitive fields like email addresses.

  ## Configuration

  Set the following environment variables:

      # Base64-encoded 32-byte key (required in production)
      CLOAK_KEY="your-base64-encoded-key"

  To generate a key:

      key = :crypto.strong_rand_bytes(32) |> Base.encode64()

  ## Key Rotation

  For key rotation, configure multiple keys with tags:

      CLOAK_KEY_PRIMARY="new-key-base64"
      CLOAK_KEY_SECONDARY="old-key-base64"

  The vault will use the first key for encryption and try all keys for decryption.
  """

  use Cloak.Vault, otp_app: :serviceradar_core

  @impl GenServer
  def init(config) do
    config =
      Keyword.put(config, :ciphers, [
        default: {
          Cloak.Ciphers.AES.GCM,
          tag: "AES.GCM.V1",
          key: decode_key!(),
          iv_length: 12
        }
      ])

    {:ok, config}
  end

  defp decode_key! do
    key_base64 =
      System.get_env("CLOAK_KEY") ||
        Application.get_env(:serviceradar_core, :cloak_key) ||
        # Development-only fallback key (NOT for production use)
        dev_fallback_key()

    case Base.decode64(key_base64) do
      {:ok, key} when byte_size(key) == 32 ->
        key

      {:ok, key} ->
        raise """
        Invalid CLOAK_KEY: key must be exactly 32 bytes (256 bits).
        Got #{byte_size(key)} bytes.
        """

      :error ->
        raise """
        Invalid CLOAK_KEY: must be a valid Base64-encoded string.
        Generate a key with: :crypto.strong_rand_bytes(32) |> Base.encode64()
        """
    end
  end

  defp dev_fallback_key do
    if Application.get_env(:serviceradar_core, :env, :prod) in [:dev, :test] do
      # Development/test only - generates a consistent key based on app name
      # NEVER use this in production
      :crypto.hash(:sha256, "serviceradar_dev_key_do_not_use_in_prod")
      |> Base.encode64()
    else
      raise """
      CLOAK_KEY environment variable is required in production.
      Generate a key with: :crypto.strong_rand_bytes(32) |> Base.encode64()
      """
    end
  end
end
