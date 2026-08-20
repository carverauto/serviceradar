defmodule ServiceRadarWebNG.Plugins.FirstPartyReleaseClient do
  @moduledoc """
  Shared transport for importing first-party artifacts from GitHub Releases
  and the Carver OCI registry. Extracted from `FirstPartyImporter`
  (issue 3425) so both the Wasm plugin importer and the native add-on importer
  reuse one HTTP/OCI/cosign client instead of duplicating it.

  Covers: repo-URL parsing, release + asset fetch, JSON index decode, OCI manifest
  /blob fetch (with registry bearer-token + docker-config auth and redirect
  handling), Cosign verification, trusted-host/URL validation, and digest/string
  utilities. Nothing here is plugin- or addon-specific; the index entry shape,
  bundle layout, and persistence stay in each importer.

  Injection seams (unchanged from FirstPartyImporter so existing config + tests
  keep working): `:first_party_plugin_import_http_client` (HTTP client, default
  `Req`), `:first_party_plugin_cosign_verifier` (default `CosignVerifier`),
  `:first_party_plugin_import_github_token` / `GITHUB_TOKEN`, and
  `:first_party_plugin_import` (`:repo_url`, `:registry_docker_config_json/file`).
  """

  alias ServiceRadar.Policies.OutboundURLPolicy
  alias ServiceRadarWebNG.Plugins.CosignVerifier
  alias ServiceRadarWebNG.Plugins.Storage

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  @github_host "github.com"
  @github_api_host "api.github.com"
  @default_repo_url "https://github.com/carverauto/serviceradar"
  @oci_registry "registry.carverauto.dev"
  @github_asset_hosts [
    @github_host,
    @github_api_host,
    "objects.githubusercontent.com",
    "release-assets.githubusercontent.com",
    "github-releases.githubusercontent.com"
  ]
  @max_asset_redirects 5

  @doc "The trusted GitHub web host."
  def github_host, do: @github_host

  @doc "The default first-party repository URL."
  def default_repo_url, do: @default_repo_url

  # --- repo parsing -------------------------------------------------------------

  def parse_repo_url(url) when is_binary(url) do
    with %URI{scheme: "https", host: @github_host} = uri <- URI.parse(String.trim(url)),
         {:ok, owner, repo} <- repo_owner_and_name(uri.path) do
      {:ok,
       %{
         provider: "github",
         repo_url: "https://#{host_port(uri)}/#{owner}/#{repo}",
         api_base_url: "https://#{@github_api_host}",
         owner: owner,
         repo: repo
       }}
    else
      _ -> {:error, "GitHub repository URL must look like https://github.com/<owner>/<repo>"}
    end
  end

  def parse_repo_url(_url), do: {:error, "GitHub repository URL is required"}

  defp repo_owner_and_name(path) when is_binary(path) do
    case path |> String.split("/", trim: true) |> Enum.take(2) do
      [owner, repo] ->
        repo = String.trim_trailing(repo, ".git")

        if owner != "" and repo != "" do
          {:ok, owner, repo}
        else
          {:error, :invalid_repo_path}
        end

      _ ->
        {:error, :invalid_repo_path}
    end
  end

  defp host_port(%URI{scheme: "https", host: host, port: 443}), do: host
  defp host_port(%URI{host: host, port: nil}), do: host
  defp host_port(%URI{host: host, port: port}), do: "#{host}:#{port}"

  # --- release + asset fetch ----------------------------------------------------

  def fetch_release(repo, tag) do
    url = "#{repo.api_base_url}/repos/#{repo.owner}/#{repo.repo}/releases/tags/#{URI.encode(tag)}"

    with {:ok, request_url} <- validate_provider_api_url(repo, url),
         {:ok, response} <- request(request_url, headers: api_headers("github"), decode_body: true) do
      case response do
        %Req.Response{status: 200, body: body} when is_map(body) -> {:ok, body}
        %Req.Response{status: 404} -> {:error, "Release tag #{tag} was not found"}
        %Req.Response{status: status} -> {:error, "Release import failed with HTTP #{status}"}
      end
    end
  end

  def fetch_recent_releases(repo, limit) do
    url = "#{repo.api_base_url}/repos/#{repo.owner}/#{repo.repo}/releases?per_page=#{normalize_limit(limit)}"

    with {:ok, request_url} <- validate_provider_api_url(repo, url),
         {:ok, response} <- request(request_url, headers: api_headers("github"), decode_body: true) do
      case response do
        %Req.Response{status: 200, body: body} when is_list(body) -> {:ok, body}
        %Req.Response{status: 200} -> {:error, "Plugin release browser returned an unexpected payload"}
        %Req.Response{status: status} -> {:error, "Recent plugin releases could not be loaded (HTTP #{status})"}
      end
    end
  end

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 50)
  defp normalize_limit(_limit), do: 10

  def fetch_release_asset(release, asset_name) do
    assets = List.wrap(Map.get(release, "assets"))

    case Enum.find(assets, &(normalize_string(Map.get(&1, "name")) == asset_name)) do
      nil -> {:error, "Release asset #{asset_name} was not found"}
      asset -> {:ok, asset}
    end
  end

  def fetch_binary_asset(repo, asset) do
    with {:ok, url} <- require_value(Map.get(asset, "browser_download_url"), "Release asset URL is missing"),
         {:ok, request_url} <- validate_provider_asset_url(repo, url) do
      fetch_url_binary(repo, request_url)
    end
  end

  def release_asset_present?(release, asset_name) do
    release
    |> Map.get("assets")
    |> List.wrap()
    |> Enum.any?(&(normalize_string(Map.get(&1, "name")) == asset_name))
  end

  def decode_index(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = index} -> {:ok, index}
      {:ok, _} -> {:error, "Plugin import index must contain a JSON object"}
      {:error, _} -> {:error, "Plugin import index asset is not valid JSON"}
    end
  end

  # --- OCI fetch ----------------------------------------------------------------

  def parse_oci_ref(ref) when is_binary(ref) do
    ref = String.trim(ref)

    cond do
      ref == "" ->
        {:error, :invalid_oci_ref}

      String.contains?(ref, "@") ->
        [name, digest] = String.split(ref, "@", parts: 2)
        parse_oci_name(name, digest)

      true ->
        case Regex.run(~r/^(.+):([^\/:]+)$/, ref) do
          [_full, name, tag] -> parse_oci_name(name, tag)
          _ -> {:error, :invalid_oci_ref}
        end
    end
  end

  def parse_oci_ref(_ref), do: {:error, :invalid_oci_ref}

  defp parse_oci_name(name, reference) do
    case String.split(name, "/", parts: 2) do
      [registry, repository] when registry != "" and repository != "" and reference != "" ->
        {:ok, %{registry: registry, repository: repository, reference: reference}}

      _ ->
        {:error, :invalid_oci_ref}
    end
  end

  def validate_oci_registry(@oci_registry), do: :ok
  def validate_oci_registry(_registry), do: {:error, :untrusted_oci_registry}

  def fetch_oci_manifest(repo, ref) do
    url = "https://#{ref.registry}/v2/#{ref.repository}/manifests/#{ref.reference}"
    headers = [{"accept", "application/vnd.oci.image.manifest.v1+json"} | asset_headers("github", url)]

    with {:ok, request_url} <- validate_provider_asset_url(repo, url),
         {:ok, response} <- request_oci(request_url, ref, headers: headers, decode_body: true) do
      case response do
        %Req.Response{status: 200, body: body} when is_map(body) ->
          {:ok, manifest_content(body), response_digest(response)}

        %Req.Response{status: status} ->
          {:error, {:oci_manifest_http_error, status}}
      end
    end
  end

  def fetch_oci_blob(repo, ref, digest) do
    url = "https://#{ref.registry}/v2/#{ref.repository}/blobs/#{digest}"

    with {:ok, request_url} <- validate_provider_asset_url(repo, url) do
      fetch_oci_blob_binary(repo, ref, request_url, @max_asset_redirects)
    end
  end

  defp fetch_oci_blob_binary(_repo, _ref, _url, remaining_redirects) when remaining_redirects < 0 do
    {:error, "Plugin artifact download exceeded redirect limit"}
  end

  defp fetch_oci_blob_binary(repo, ref, url, remaining_redirects) do
    case request_oci(url, ref, headers: asset_headers("github", url), decode_body: false) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, IO.iodata_to_binary(body)}

      {:ok, %Req.Response{status: status} = response} when status in [301, 302, 303, 307, 308] ->
        with {:ok, redirect_url} <- redirect_location(url, response),
             {:ok, request_url} <- validate_provider_asset_url(repo, redirect_url) do
          fetch_url_binary(repo, request_url, remaining_redirects - 1)
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:artifact_http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def find_layer(manifest, media_type) do
    layer =
      manifest
      |> Map.get("layers", [])
      |> Enum.find(&(Map.get(&1, "mediaType") == media_type))

    case layer do
      %{"digest" => digest} when is_binary(digest) -> {:ok, layer}
      _ -> {:error, :oci_layer_missing}
    end
  end

  @doc "All layers matching `media_type` (native add-ons carry one tarball + one signature layer per arch)."
  def layers_by_media_type(manifest, media_type) do
    manifest
    |> Map.get("layers", [])
    |> Enum.filter(&(Map.get(&1, "mediaType") == media_type))
  end

  defp manifest_content(%{"content" => %{} = content}), do: content
  defp manifest_content(%{} = manifest), do: manifest

  defp response_digest(response) do
    response
    |> Req.Response.get_header("docker-content-digest")
    |> List.first()
    |> normalize_string()
  end

  # --- HTTP + registry auth -----------------------------------------------------

  def request(url, opts) do
    request_opts =
      opts
      |> Keyword.put(:redirect, false)
      |> Keyword.merge(req_opts())

    http_client().get(url, request_opts)
  end

  defp request_oci(url, ref, opts) do
    case request(url, opts) do
      {:ok, %Req.Response{status: 401} = response} ->
        with {:ok, token} <- fetch_oci_bearer_token(ref, response) do
          headers =
            opts
            |> Keyword.get(:headers, [])
            |> put_header("authorization", "Bearer #{token}")

          request(url, Keyword.put(opts, :headers, headers))
        end

      other ->
        other
    end
  end

  defp fetch_oci_bearer_token(ref, response) do
    with {:ok, challenge} <- oci_bearer_challenge(response),
         {:ok, token_url} <- oci_token_url(challenge, ref),
         headers = [{"accept", "application/json"} | registry_basic_auth_headers(ref.registry)],
         {:ok, %Req.Response{status: 200, body: body}} <- request(token_url, headers: headers, decode_body: true),
         token when is_binary(token) and token != "" <- Map.get(body, "token") || Map.get(body, "access_token") do
      {:ok, token}
    else
      {:ok, %Req.Response{status: status}} -> {:error, {:oci_token_http_error, status}}
      nil -> {:error, :oci_token_missing}
      "" -> {:error, :oci_token_missing}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :oci_token_missing}
    end
  end

  defp oci_bearer_challenge(response) do
    response
    |> Req.Response.get_header("www-authenticate")
    |> List.wrap()
    |> Enum.find_value(fn header ->
      if String.starts_with?(String.downcase(header), "bearer ") do
        params =
          ~r/([A-Za-z_]+)="([^"]*)"/
          |> Regex.scan(header)
          |> Map.new(fn [_match, key, value] -> {String.downcase(key), value} end)

        {:ok, params}
      end
    end)
    |> case do
      {:ok, %{"realm" => _realm} = params} -> {:ok, params}
      _ -> {:error, :oci_auth_challenge_missing}
    end
  end

  defp oci_token_url(%{"realm" => realm} = challenge, ref) do
    params =
      challenge
      |> Map.take(["service", "scope"])
      |> Map.update("scope", "repository:#{ref.repository}:pull", fn
        "" -> "repository:#{ref.repository}:pull"
        scope -> scope
      end)
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

    case validate_url(realm) do
      {:ok, %URI{host: @oci_registry} = uri} ->
        query =
          uri.query
          |> decode_query()
          |> Kernel.++(params)
          |> URI.encode_query()

        {:ok, URI.to_string(%{uri | query: query})}

      {:ok, _uri} ->
        {:error, :untrusted_oci_token_realm}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_query(nil), do: []
  defp decode_query(query), do: query |> URI.decode_query() |> Enum.to_list()

  defp registry_basic_auth_headers(registry) do
    case registry_basic_auth(registry) do
      {:ok, auth} -> [{"authorization", "Basic #{auth}"}]
      :error -> []
    end
  end

  defp registry_basic_auth(registry) do
    config = Application.get_env(:serviceradar_web_ng, :first_party_plugin_import, [])

    config
    |> registry_docker_config_payload()
    |> decode_docker_auth(registry)
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp registry_docker_config_payload(config) do
    cond do
      payload = Keyword.get(config, :registry_docker_config_json) ->
        payload

      path = Keyword.get(config, :registry_docker_config_file) ->
        case File.read(path) do
          {:ok, payload} -> payload
          {:error, _reason} -> nil
        end

      true ->
        nil
    end
  end

  defp decode_docker_auth(nil, _registry), do: :error

  defp decode_docker_auth(payload, registry) when is_binary(payload) do
    with {:ok, %{"auths" => auths}} when is_map(auths) <- Jason.decode(payload),
         {:ok, auth_config} <- find_registry_auth(auths, registry) do
      cond do
        auth = normalize_string(Map.get(auth_config, "auth")) ->
          {:ok, auth}

        username = normalize_string(Map.get(auth_config, "username")) ->
          password = normalize_string(Map.get(auth_config, "password")) || ""
          {:ok, Base.encode64("#{username}:#{password}")}

        true ->
          :error
      end
    else
      _ -> :error
    end
  end

  defp decode_docker_auth(_payload, _registry), do: :error

  defp find_registry_auth(auths, registry) do
    auths
    |> Enum.find_value(fn {key, value} ->
      if docker_auth_key_matches?(key, registry), do: {:ok, value}
    end)
    |> case do
      {:ok, %{} = auth_config} -> {:ok, auth_config}
      _ -> :error
    end
  end

  defp docker_auth_key_matches?(key, registry) do
    case URI.parse(key) do
      %URI{host: host} when is_binary(host) -> host == registry
      %URI{path: ^registry} -> true
      _ -> false
    end
  end

  defp put_header(headers, key, value) do
    normalized_key = String.downcase(key)

    headers
    |> Enum.reject(fn {existing_key, _value} -> String.downcase(to_string(existing_key)) == normalized_key end)
    |> then(&[{key, value} | &1])
  end

  def fetch_url_binary(repo, url), do: fetch_url_binary(repo, url, @max_asset_redirects)

  def fetch_url_binary(_repo, _url, remaining_redirects) when remaining_redirects < 0 do
    {:error, "Plugin artifact download exceeded redirect limit"}
  end

  def fetch_url_binary(repo, url, remaining_redirects) do
    case request(url, headers: asset_headers(url), decode_body: false) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, IO.iodata_to_binary(body)}

      {:ok, %Req.Response{status: status} = response} when status in [301, 302, 303, 307, 308] ->
        with {:ok, redirect_url} <- redirect_location(url, response),
             {:ok, request_url} <- validate_provider_asset_url(repo, redirect_url) do
          fetch_url_binary(repo, request_url, remaining_redirects - 1)
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:artifact_http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp redirect_location(request_url, response) do
    case Req.Response.get_header(response, "location") do
      [location | _] ->
        resolved =
          request_url
          |> URI.parse()
          |> URI.merge(location)
          |> URI.to_string()

        {:ok, resolved}

      _ ->
        {:error, :missing_redirect_location}
    end
  end

  defp http_client do
    Application.get_env(:serviceradar_web_ng, :first_party_plugin_import_http_client, Req)
  end

  defp req_opts do
    [connect_options: [timeout: 5_000], receive_timeout: 10_000, redirect: false]
  end

  defp api_headers("github") do
    [{"user-agent", "serviceradar"}, {"accept", "application/vnd.github+json"} | auth_headers()]
  end

  defp asset_headers("github", url), do: asset_headers(url)

  defp asset_headers(url) do
    headers = [{"user-agent", "serviceradar"}]

    if auth_host?(url) do
      headers ++ auth_headers()
    else
      headers
    end
  end

  defp auth_headers do
    case Application.get_env(:serviceradar_web_ng, :first_party_plugin_import_github_token) ||
           System.get_env("GITHUB_TOKEN") ||
           System.get_env("GH_TOKEN") do
      nil -> []
      token -> [{"authorization", "Bearer #{token}"}]
    end
  end

  defp auth_host?(url) do
    case URI.parse(url) do
      %URI{host: host} when host in [@github_host, @github_api_host] -> true
      _ -> false
    end
  end

  # --- URL validation -----------------------------------------------------------

  def validate_provider_api_url(_repo, url) do
    with {:ok, uri} <- validate_url(url),
         true <- uri.host == @github_api_host do
      {:ok, URI.to_string(uri)}
    else
      false -> {:error, "plugin import provider URL is not trusted"}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_provider_asset_url(_repo, url) do
    with {:ok, uri} <- validate_url(url),
         true <- uri.host in [@oci_registry | @github_asset_hosts] do
      {:ok, URI.to_string(uri)}
    else
      false -> {:error, "plugin import asset URL is not trusted"}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_url(url) do
    case URI.parse(String.trim(to_string(url))) do
      %URI{scheme: "https", host: host} = uri
      when host in [@oci_registry | @github_asset_hosts] ->
        {:ok, uri}

      _ ->
        case OutboundURLPolicy.validate_https_public_url(url) do
          {:ok, %URI{scheme: "https"} = uri} -> {:ok, uri}
          {:error, _reason} = error -> error
          _ -> {:error, :disallowed_url}
        end
    end
  end

  # --- cosign + digest + string utils ------------------------------------------

  def verify_cosign_signature(nil, _digest), do: {:error, :oci_ref_required}
  def verify_cosign_signature(_ref, nil), do: {:error, :oci_digest_required}

  def verify_cosign_signature(ref, digest) do
    verifier = Application.get_env(:serviceradar_web_ng, :first_party_plugin_cosign_verifier, CosignVerifier)
    verifier.verify(%{ref: ref, digest: digest})
  end

  def verify_declared_digest(nil, _actual), do: :ok
  def verify_declared_digest("", _actual), do: :ok
  def verify_declared_digest(_declared, nil), do: :ok

  def verify_declared_digest(declared, actual) do
    if normalize_digest(declared) == normalize_digest(actual) do
      :ok
    else
      {:error, :oci_digest_mismatch}
    end
  end

  def digest_matches?(nil, _payload), do: true
  def digest_matches?("", _payload), do: true

  def digest_matches?(expected, payload) when is_binary(expected) and is_binary(payload) do
    normalize_digest(expected) == normalize_digest(Storage.sha256(payload))
  end

  def normalize_digest(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace_prefix("sha256:", "")
  end

  def normalize_digest(_value), do: nil

  def normalize_string(nil), do: nil

  def normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  def normalize_string(value), do: value |> to_string() |> normalize_string()

  def require_value(value, message) do
    case normalize_string(value) do
      nil -> {:error, message}
      present -> {:ok, present}
    end
  end
end
