defmodule ServiceRadar.Plugins.StorageToken do
  @moduledoc """
  Generates signed download tokens and endpoint URLs for plugin package blobs.
  """

  require Logger

  @default_download_ttl_seconds 86_400

  @spec download_request(String.t(), String.t() | nil) ::
          %{url: String.t(), token: String.t()} | nil
  def download_request(package_id, object_key) do
    download_request(package_id, object_key, "/artifacts/plugins/#{package_id}/blob/download")
  end

  @doc """
  Mints a signed download request for a native add-on package artifact. Mirrors
  `download_request/2` exactly (same HMAC-signed token mechanism, same secret,
  same TTL) but points the URL at the agent-gateway artifact endpoint so agents
  fetch add-on artifacts over HTTPS like WASM plugins.
  """
  @spec download_addon_request(String.t(), String.t() | nil) ::
          %{url: String.t(), token: String.t()} | nil
  def download_addon_request(package_id, object_key) do
    download_request(package_id, object_key, "/artifacts/addons/#{package_id}/blob/download")
  end

  @doc """
  Mints a signed download request for an agent-facing artifact family.

  The token id identifies the logical artifact source. Core authorizes the exact
  source/object pair before the agent-gateway streams object bytes from
  DataService.
  """
  @spec download_agent_artifact_request(String.t(), String.t() | nil) ::
          %{url: String.t(), token: String.t()} | nil
  def download_agent_artifact_request(token_id, object_key) do
    download_request(
      token_id,
      object_key,
      "/artifacts/agent-artifacts/#{safe_path_segment(token_id)}/download"
    )
  end

  @spec verify_token(atom(), String.t()) ::
          {:ok, %{id: String.t(), key: String.t()}} | {:error, atom()}
  def verify_token(expected_action, token) when is_binary(token) do
    with [payload_b64, sig_b64] <- String.split(token, ".", parts: 2),
         {:ok, payload_json} <- Base.url_decode64(payload_b64, padding: false),
         {:ok, payload} <- Jason.decode(payload_json),
         {:ok, signature} <- Base.url_decode64(sig_b64, padding: false),
         true <- secure_compare(signature, sign(payload_json)),
         %{"id" => id, "key" => key, "exp" => exp, "act" => action} <- payload,
         true <- action == Atom.to_string(expected_action),
         true <- exp > DateTime.to_unix(DateTime.utc_now()) do
      {:ok, %{id: id, key: key}}
    else
      _ -> {:error, :invalid_token}
    end
  end

  def verify_token(_action, _token), do: {:error, :invalid_token}

  # Shared implementation: only the URL path differs between plugin and addon blobs;
  # the signed-token payload (id/key/exp/act=download) and secret are identical.
  @spec download_request(String.t(), String.t() | nil, String.t()) ::
          %{url: String.t(), token: String.t()} | nil
  def download_request(package_id, object_key, url_path)
      when is_binary(package_id) and is_binary(object_key) and is_binary(url_path) do
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
        signature = sign(payload_json)

        token =
          Base.url_encode64(payload_json, padding: false) <>
            "." <>
            Base.url_encode64(signature, padding: false)

        %{
          url: String.trim_trailing(base_url, "/") <> url_path,
          token: token
        }
    end
  end

  def download_request(_package_id, _object_key, _url_path), do: nil

  @doc """
  Effective TTL (seconds) applied to signed download tokens. Public so config
  generation can re-version agent configs before delivered tokens expire.
  """
  @spec download_ttl_seconds() :: pos_integer()
  def download_ttl_seconds do
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

  defp sign(payload_json), do: :crypto.mac(:hmac, :sha256, signing_secret() || "", payload_json)

  defp secure_compare(left, right) when byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_left, _right), do: false

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

  defp safe_path_segment(value) when is_binary(value) do
    value
    |> URI.encode(&URI.char_unreserved?/1)
    |> case do
      "" -> "artifact"
      segment -> segment
    end
  end

  defp safe_path_segment(_value), do: "artifact"
end
