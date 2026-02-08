defmodule ServiceRadar.Plugins.StorageToken do
  @moduledoc """
  Generates signed download URLs for plugin package blobs.
  """

  require Logger

  @default_download_ttl_seconds 86_400

  @spec download_url(String.t(), String.t() | nil) :: String.t() | nil
  def download_url(package_id, object_key)
      when is_binary(package_id) and is_binary(object_key) do
    base_url = public_url()
    secret = signing_secret()

    cond do
      base_url == nil ->
        Logger.debug("plugin storage public URL not configured")
        nil

      secret == nil ->
        Logger.warning("plugin storage signing secret not configured")
        nil

      String.trim(object_key) == "" ->
        nil

      true ->
        exp =
          DateTime.utc_now()
          |> DateTime.add(download_ttl_seconds(), :second)
          |> DateTime.to_unix()

        payload = %{
          "id" => package_id,
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
          "/api/plugin-packages/#{package_id}/blob?token=#{token}"
    end
  end

  def download_url(_package_id, _object_key), do: nil

  defp download_ttl_seconds do
    config()
    |> Keyword.get(:download_ttl_seconds, @default_download_ttl_seconds)
    |> normalize_int(@default_download_ttl_seconds)
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
    Application.get_env(:serviceradar_core, :plugin_storage, [])
  end

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(_), do: nil

  defp normalize_int(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_int(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_int(_value, default), do: default
end
