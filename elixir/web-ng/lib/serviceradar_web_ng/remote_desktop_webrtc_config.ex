defmodule ServiceRadarWebNG.RemoteDesktopWebRTCConfig do
  @moduledoc """
  Loads the deploy-time ICE/TURN configuration for remote desktop sessions.

  ICE endpoints are non-secret JSON. TURN credentials are never accepted in
  that JSON: a TURN REST shared secret must come from a mounted file and is
  used by `ServiceRadarWebNG.RemoteDesktopWebRTC` to mint short-lived,
  session-bound credentials.
  """

  @allowed_server_keys MapSet.new(["urls"])
  @allowed_schemes ~w(stun stuns turn turns)
  @max_servers 8
  @max_urls_per_server 4
  @max_json_bytes 16 * 1024
  @max_url_bytes 512
  @min_turn_secret_bytes 32
  @max_turn_secret_bytes 512
  @max_turn_secret_file_bytes @max_turn_secret_bytes + 2
  @default_credential_ttl_seconds 600
  @max_credential_ttl_seconds 3_600

  @type ice_server :: %{required(:urls) => [String.t()]}

  @spec load!(keyword()) :: %{
          ice_servers: [ice_server()],
          turn_shared_secret: String.t() | nil,
          credential_ttl_seconds: pos_integer()
        }
  def load!(opts) when is_list(opts) do
    ice_servers = load_ice_servers!(Keyword.get(opts, :ice_servers_json))

    %{
      ice_servers: ice_servers,
      turn_shared_secret:
        load_turn_shared_secret!(
          Keyword.get(opts, :turn_shared_secret_file),
          turn_configured?(ice_servers)
        ),
      credential_ttl_seconds: credential_ttl_seconds!(Keyword.get(opts, :credential_ttl_seconds))
    }
  end

  @spec load_ice_servers!(String.t() | nil) :: [ice_server()]
  def load_ice_servers!(nil), do: []
  def load_ice_servers!(""), do: []

  def load_ice_servers!(raw) when is_binary(raw) and byte_size(raw) <= @max_json_bytes do
    case Jason.decode(raw) do
      {:ok, servers} when is_list(servers) -> normalize_servers!(servers)
      {:ok, _other} -> raise ArgumentError, "remote desktop ICE server JSON must be a list"
      {:error, _error} -> raise ArgumentError, "remote desktop ICE server JSON is invalid"
    end
  end

  def load_ice_servers!(raw) when is_binary(raw) do
    raise ArgumentError, "remote desktop ICE server JSON exceeds #{@max_json_bytes} bytes"
  end

  def load_ice_servers!(_other) do
    raise ArgumentError, "remote desktop ICE server JSON must be a string"
  end

  @spec credential_ttl_seconds!(String.t() | integer() | nil) :: pos_integer()
  def credential_ttl_seconds!(nil), do: @default_credential_ttl_seconds
  def credential_ttl_seconds!(""), do: @default_credential_ttl_seconds

  def credential_ttl_seconds!(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} -> credential_ttl_seconds!(seconds)
      _other -> invalid_credential_ttl!()
    end
  end

  def credential_ttl_seconds!(seconds)
      when is_integer(seconds) and seconds > 0 and seconds <= @max_credential_ttl_seconds, do: seconds

  def credential_ttl_seconds!(_other), do: invalid_credential_ttl!()

  defp normalize_servers!(servers) when length(servers) <= @max_servers do
    Enum.map(servers, &normalize_server!/1)
  end

  defp normalize_servers!(_servers) do
    raise ArgumentError, "remote desktop ICE configuration exceeds #{@max_servers} servers"
  end

  defp normalize_server!(%{} = server) do
    keys = server |> Map.keys() |> MapSet.new()
    unexpected = MapSet.difference(keys, @allowed_server_keys)

    if MapSet.size(unexpected) > 0 do
      raise ArgumentError,
            "remote desktop ICE server entries may contain only urls; static credentials are forbidden"
    end

    %{urls: normalize_urls!(Map.get(server, "urls"))}
  end

  defp normalize_server!(_other) do
    raise ArgumentError, "remote desktop ICE server entries must be objects"
  end

  defp normalize_urls!(url) when is_binary(url), do: normalize_urls!([url])

  defp normalize_urls!([_ | _] = urls) when length(urls) <= @max_urls_per_server do
    Enum.map(urls, &normalize_url!/1)
  end

  defp normalize_urls!(_other) do
    raise ArgumentError,
          "remote desktop ICE server urls must contain between 1 and #{@max_urls_per_server} entries"
  end

  defp normalize_url!(url) when is_binary(url) and byte_size(url) <= @max_url_bytes do
    if url != String.trim(url) or String.match?(url, ~r/[\x00-\x20\x7f]/u) do
      invalid_ice_url!()
    end

    case Regex.run(~r/\A([A-Za-z]+):(.+)\z/u, url, capture: :all_but_first) do
      [raw_scheme, remainder] ->
        scheme = String.downcase(raw_scheme)

        if scheme in @allowed_schemes do
          {authority, query} = split_query!(remainder)
          validate_authority!(authority)
          validate_query!(scheme, query)
          scheme <> ":" <> authority <> query_suffix(query)
        else
          invalid_ice_url!()
        end

      _other ->
        invalid_ice_url!()
    end
  end

  defp normalize_url!(_other), do: invalid_ice_url!()

  defp split_query!(remainder) do
    if String.contains?(remainder, ["@", "/", "#"]) do
      invalid_ice_url!()
    end

    case String.split(remainder, "?", parts: 3) do
      [authority] -> {authority, nil}
      [authority, query] when query != "" -> {authority, query}
      _other -> invalid_ice_url!()
    end
  end

  defp validate_authority!("[" <> remainder) do
    case String.split(remainder, "]", parts: 2) do
      [address, suffix] when address != "" and suffix in [""] ->
        validate_ip_address!(address, :inet6)

      [address, ":" <> port] when address != "" ->
        validate_ip_address!(address, :inet6)
        validate_port!(port)

      _other ->
        invalid_ice_url!()
    end
  end

  defp validate_authority!(authority) do
    case String.split(authority, ":", parts: 3) do
      [host] ->
        validate_host!(host)

      [host, port] ->
        validate_host!(host)
        validate_port!(port)

      _other ->
        invalid_ice_url!()
    end
  end

  defp validate_host!(host) when host != "" do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {_a, _b, _c, _d}} -> true
      _other -> validate_hostname!(host)
    end
  end

  defp validate_host!(_host), do: invalid_ice_url!()

  defp validate_hostname!(host) when byte_size(host) <= 253 do
    labels = String.split(host, ".", trim: false)

    if Enum.all?(labels, &valid_hostname_label?/1) do
      true
    else
      invalid_ice_url!()
    end
  end

  defp validate_hostname!(_host), do: invalid_ice_url!()

  defp valid_hostname_label?(label) when byte_size(label) in 1..63 do
    String.match?(label, ~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\z/u)
  end

  defp valid_hostname_label?(_label), do: false

  defp validate_ip_address!(address, family) do
    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, tuple} when tuple_size(tuple) == 8 and family == :inet6 -> true
      _other -> invalid_ice_url!()
    end
  end

  defp validate_port!(port) do
    case Integer.parse(port) do
      {value, ""} when value in 1..65_535 -> true
      _other -> invalid_ice_url!()
    end
  end

  defp validate_query!(scheme, nil) when scheme in @allowed_schemes, do: true

  defp validate_query!(scheme, query) when scheme in ["turn", "turns"] and query in ["transport=udp", "transport=tcp"],
    do: true

  defp validate_query!(_scheme, _query), do: invalid_ice_url!()

  defp query_suffix(nil), do: ""
  defp query_suffix(query), do: "?" <> query

  defp load_turn_shared_secret!(nil, false), do: nil
  defp load_turn_shared_secret!("", false), do: nil

  defp load_turn_shared_secret!(path, false) when is_binary(path) do
    if String.trim(path) == "" do
      nil
    else
      raise ArgumentError,
            "remote desktop TURN shared-secret file is configured without a TURN endpoint"
    end
  end

  defp load_turn_shared_secret!(path, true) when is_binary(path) do
    normalized_path = String.trim(path)

    if normalized_path == "" do
      missing_turn_secret!()
    else
      secret = read_turn_secret!(normalized_path)
      validate_turn_secret!(secret)
    end
  end

  defp load_turn_shared_secret!(_path, true), do: missing_turn_secret!()
  defp load_turn_shared_secret!(_path, false), do: nil

  defp read_turn_secret!(path) do
    expanded_path = Path.expand(path)

    with :absolute <- Path.type(path),
         true <- path == expanded_path,
         {:ok, io_device} <-
           :file.open(String.to_charlist(expanded_path), [:read, :binary, :raw]) do
      try do
        read_bounded_turn_secret!(io_device)
      after
        :file.close(io_device)
      end
    else
      _error -> raise ArgumentError, "remote desktop TURN shared-secret file is unreadable"
    end
  end

  defp read_bounded_turn_secret!(io_device) do
    case :file.position(io_device, :cur) do
      {:ok, 0} ->
        case :file.read(io_device, @max_turn_secret_file_bytes + 1) do
          :eof ->
            ""

          {:ok, contents} when byte_size(contents) <= @max_turn_secret_file_bytes ->
            case :file.read(io_device, 1) do
              :eof -> contents
              _more_or_error -> unreadable_turn_secret!()
            end

          _oversized_or_error ->
            unreadable_turn_secret!()
        end

      _non_regular ->
        unreadable_turn_secret!()
    end
  end

  defp validate_turn_secret!(secret) do
    normalized = secret |> String.trim_trailing("\n") |> String.trim_trailing("\r")

    if byte_size(normalized) in @min_turn_secret_bytes..@max_turn_secret_bytes and
         String.valid?(normalized) and
         String.match?(normalized, ~r/\A[!-~]+\z/u) do
      normalized
    else
      raise ArgumentError,
            "remote desktop TURN shared secret must be 32-512 printable, non-whitespace bytes"
    end
  end

  defp turn_configured?(servers) do
    Enum.any?(servers, fn %{urls: urls} ->
      Enum.any?(urls, &(String.starts_with?(&1, "turn:") or String.starts_with?(&1, "turns:")))
    end)
  end

  defp missing_turn_secret! do
    raise ArgumentError,
          "remote desktop TURN endpoints require a mounted TURN REST shared-secret file"
  end

  defp unreadable_turn_secret! do
    raise ArgumentError, "remote desktop TURN shared-secret file is unreadable"
  end

  defp invalid_credential_ttl! do
    raise ArgumentError,
          "remote desktop TURN credential TTL must be between 1 and #{@max_credential_ttl_seconds} seconds"
  end

  defp invalid_ice_url! do
    raise ArgumentError,
          "remote desktop ICE URLs must use stun, stuns, turn, or turns with a valid host and optional port"
  end
end
