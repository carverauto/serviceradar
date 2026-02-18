defmodule ServiceRadar.Software.StorageToken do
  @moduledoc """
  Generates HMAC-signed download URLs for software images.

  Follows the same pattern as `ServiceRadar.Plugins.StorageToken`.
  """

  require Logger

  @default_download_ttl_seconds 86_400

  @spec download_url(String.t(), String.t() | nil) :: String.t() | nil
  def download_url(image_id, object_key)
      when is_binary(image_id) and is_binary(object_key) do
    base_url = public_url()
    secret = signing_secret()

    cond do
      base_url == nil ->
        Logger.debug("software storage public URL not configured")
        nil

      secret == nil ->
        Logger.warning("software storage signing secret not configured")
        nil

      String.trim(object_key) == "" ->
        nil

      true ->
        exp =
          DateTime.utc_now()
          |> DateTime.add(download_ttl_seconds(), :second)
          |> DateTime.to_unix()

        payload = %{
          "id" => image_id,
          "key" => object_key,
          "exp" => exp,
          "act" => "download"
        }

        payload_json = Jason.encode!(payload)
        signature = :crypto.mac(:hmac, :sha256, secret, payload_json)

        token =
          Base.url_encode64(payload_json, padding: false) <>
            "." <>
            Base.url_encode64(signature, padding: false)

        String.trim_trailing(base_url, "/") <>
          "/api/software-images/#{image_id}/download?token=#{token}"
    end
  end

  def download_url(_image_id, _object_key), do: nil

  @spec verify_token(String.t()) :: {:ok, map()} | {:error, atom()}
  def verify_token(token) when is_binary(token) do
    with {:ok, secret} <- fetch_signing_secret(),
         {:ok, payload_json, expected_sig} <- decode_token_parts(token),
         :ok <- verify_signature(payload_json, expected_sig, secret),
         {:ok, payload} <- decode_payload(payload_json),
         :ok <- ensure_not_expired(payload) do
      {:ok, payload}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def verify_token(_), do: {:error, :invalid_token_format}

  defp fetch_signing_secret do
    case signing_secret() do
      nil -> {:error, :signing_secret_not_configured}
      secret -> {:ok, secret}
    end
  end

  defp decode_token_parts(token) do
    case String.split(token, ".", parts: 2) do
      [payload_b64, sig_b64] ->
        with {:ok, payload_json} <- Base.url_decode64(payload_b64, padding: false),
             {:ok, expected_sig} <- Base.url_decode64(sig_b64, padding: false) do
          {:ok, payload_json, expected_sig}
        else
          _ -> {:error, :invalid_token_format}
        end

      _ ->
        {:error, :invalid_token_format}
    end
  end

  defp verify_signature(payload_json, expected_sig, secret) do
    actual_sig = :crypto.mac(:hmac, :sha256, secret, payload_json)
    if :crypto.hash_equals(expected_sig, actual_sig), do: :ok, else: {:error, :invalid_signature}
  end

  defp decode_payload(payload_json) do
    case Jason.decode(payload_json) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> {:error, :invalid_token_format}
    end
  end

  defp ensure_not_expired(%{"exp" => exp}) when is_integer(exp) do
    if exp > DateTime.to_unix(DateTime.utc_now()), do: :ok, else: {:error, :token_expired}
  end

  defp ensure_not_expired(_), do: {:error, :invalid_token_format}

  defp download_ttl_seconds do
    config()
    |> Keyword.get(:download_ttl_seconds, @default_download_ttl_seconds)
  end

  defp public_url do
    config()
    |> Keyword.get(:public_url)
    |> normalize_string()
  end

  defp signing_secret do
    config()
    |> Keyword.get(:signing_secret)
    |> normalize_string()
  end

  defp config do
    Application.get_env(:serviceradar_core, :software_storage, [])
  end

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(_), do: nil
end
