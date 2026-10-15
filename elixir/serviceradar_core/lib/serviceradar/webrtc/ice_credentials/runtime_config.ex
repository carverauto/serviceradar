defmodule ServiceRadar.WebRTC.IceCredentials.RuntimeConfig do
  @moduledoc """
  Builds the `ServiceRadar.WebRTC.IceCredentials` configuration from a
  release's environment, failing at boot on static configuration errors.

  web-ng and core-elx each call `load!/1` from `config/runtime.exs` with
  the values the Helm chart renders:

    * `:backend` — `SERVICERADAR_WEBRTC_ICE_BACKEND`: `none` (default) or
      `static_secret`.
    * `:ttl_seconds` — `SERVICERADAR_WEBRTC_ICE_CREDENTIAL_TTL_SECONDS`,
      60..3600, default 600.
    * `:secret_file` — `SERVICERADAR_WEBRTC_TURN_SHARED_SECRET_FILE`, the
      mounted TURN REST shared secret. Required by `static_secret`; the file
      is validated here (32..512 printable bytes) and read again on every
      mint, so a rotated Secret takes effect without a restart.
    * `:turn_urls_json` — `SERVICERADAR_WEBRTC_TURN_URLS_JSON`, a JSON list
      of `turn:`/`turns:` URLs. web-ng gets the browser-facing URLs, core-elx
      the in-cluster TURN Service URL. Required by `static_secret`.

  The URLs are public endpoint metadata: userinfo, credentials and any query
  other than `transport=udp|tcp` are rejected.
  """

  alias ServiceRadar.WebRTC.IceCredentials
  alias ServiceRadar.WebRTC.IceCredentials.StaticSecret

  @max_turn_urls 8
  @max_url_bytes 512
  @turn_url ~r/\Aturns?:(?:[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?|\[[0-9A-Fa-f:.]+\])(?::[0-9]{1,5})?(?:\?transport=(?:udp|tcp))?\z/

  @spec load!(keyword()) :: keyword()
  def load!(opts) when is_list(opts) do
    backend = backend!(Keyword.get(opts, :backend))
    ttl = ttl_seconds!(Keyword.get(opts, :ttl_seconds))
    turn_urls = turn_urls!(Keyword.get(opts, :turn_urls_json))
    base = [backend: backend, default_ttl_seconds: ttl, turn_urls: turn_urls]

    case backend do
      :none ->
        base

      :static_secret ->
        if turn_urls == [] do
          raise ArgumentError, "WebRTC static_secret ICE backend requires at least one TURN URL"
        end

        base ++ [static_secret: [secret_file: secret_file!(Keyword.get(opts, :secret_file))]]
    end
  end

  defp backend!(value) when value in [nil, "", "none"], do: :none
  defp backend!("static_secret"), do: :static_secret

  defp backend!(_other) do
    raise ArgumentError, "WebRTC ICE backend must be none or static_secret"
  end

  defp ttl_seconds!(value) when value in [nil, ""], do: IceCredentials.default_ttl_seconds()

  defp ttl_seconds!(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} -> ttl_seconds!(seconds)
      _other -> invalid_ttl!()
    end
  end

  defp ttl_seconds!(seconds) when is_integer(seconds) do
    if seconds in IceCredentials.min_ttl_seconds()..IceCredentials.max_ttl_seconds() do
      seconds
    else
      invalid_ttl!()
    end
  end

  defp ttl_seconds!(_other), do: invalid_ttl!()

  defp invalid_ttl! do
    raise ArgumentError,
          "WebRTC ICE credential TTL must be between #{IceCredentials.min_ttl_seconds()} " <>
            "and #{IceCredentials.max_ttl_seconds()} seconds"
  end

  defp turn_urls!(value) when value in [nil, ""], do: []

  defp turn_urls!(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, urls} when is_list(urls) and length(urls) <= @max_turn_urls ->
        Enum.map(urls, &turn_url!/1)

      _other ->
        raise ArgumentError,
              "WebRTC TURN URLs must be a JSON list of at most #{@max_turn_urls} URLs"
    end
  end

  defp turn_url!(url) when is_binary(url) and byte_size(url) <= @max_url_bytes do
    if Regex.match?(@turn_url, url) do
      url
    else
      raise ArgumentError,
            "WebRTC TURN URLs must use turn: or turns: with a host, optional port and " <>
              "optional transport=udp|tcp; credentials are forbidden"
    end
  end

  defp turn_url!(_url) do
    raise ArgumentError, "WebRTC TURN URLs must be strings of at most #{@max_url_bytes} bytes"
  end

  defp secret_file!(path) when is_binary(path) and path != "" do
    case StaticSecret.load_shared_secret(path) do
      {:ok, _secret} ->
        path

      {:error, reason} ->
        raise ArgumentError,
              "WebRTC TURN shared-secret file is unusable (#{inspect(reason)}); it must hold " <>
                "32-512 printable, non-whitespace bytes"
    end
  end

  defp secret_file!(_path) do
    raise ArgumentError,
          "WebRTC static_secret ICE backend requires a mounted TURN shared-secret file"
  end
end
