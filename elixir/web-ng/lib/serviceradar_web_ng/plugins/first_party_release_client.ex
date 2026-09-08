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

  alias ServiceRadar.Plugins.RepoUrl
  alias ServiceRadar.Policies.OutboundURLPolicy
  alias ServiceRadarWebNG.Plugins.CosignVerifier
  alias ServiceRadarWebNG.Plugins.Storage

  require Logger

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
    # Parsing lives in `ServiceRadar.Plugins.RepoUrl` because `PluginRepository`
    # validates the same URLs at write time and core cannot depend on web-ng.
    # Two parsers would be two chances to disagree, and disagreeing in the
    # permissive direction means a repository row that saves cleanly and then
    # fails every import.
    case RepoUrl.parse(url) do
      {:ok, parsed} ->
        {:ok,
         %{
           provider: parsed.provider,
           repo_url: parsed.repo_url,
           api_base_url: "https://#{@github_api_host}",
           owner: parsed.owner,
           repo: parsed.repo,
           token: nil
         }}

      {:error, _reason} ->
        {:error, "GitHub repository URL must look like https://github.com/<owner>/<repo>"}
    end
  end

  def parse_repo_url(_url), do: {:error, "GitHub repository URL is required"}

  @doc """
  Binds a repository's access token to a parsed repo for this request.

  The token rides on the repo rather than being read from the environment so
  two private repositories can be reachable at once; the global
  `GITHUB_TOKEN` remains the fallback for the built-in source.
  """
  def with_token(repo, token) when is_map(repo), do: Map.put(repo, :token, token)

  # --- release + asset fetch ----------------------------------------------------

  def fetch_release(repo, tag) do
    url = "#{repo.api_base_url}/repos/#{repo.owner}/#{repo.repo}/releases/tags/#{URI.encode(tag)}"

    with {:ok, request_url} <- validate_provider_api_url(repo, url),
         {:ok, response} <- request(request_url, headers: api_headers(repo), decode_body: true) do
      case response do
        %Req.Response{status: 200, body: body} when is_map(body) -> {:ok, body}
        %Req.Response{status: 404} -> {:error, not_found_reason(repo, "Release tag #{tag} was not found")}
        %Req.Response{status: status} when status in [401, 403] -> {:error, credential_reason(repo, status)}
        %Req.Response{status: status} -> {:error, "Release import failed with HTTP #{status}"}
      end
    end
  end

  @doc """
  True when GitHub answered that the requested release catalog does not exist.

  Used by automatic sync to distinguish "this tag was never published" or
  "this private repository is invisible without a token" from retryable
  credential/transport failures. GitHub reports both cases as HTTP 404.
  """
  @spec missing_release?(term()) :: boolean()
  def missing_release?(reason) when is_binary(reason) do
    (String.contains?(reason, "Release tag ") and String.contains?(reason, " was not found")) or
      String.contains?(reason, "Repository or releases not found")
  end

  def missing_release?(_reason), do: false

  @doc """
  True when a discovery failure is a property of the published release rather
  than of the attempt, so every retry reports the same thing.

  Kept separate from `missing_release?/1`, which decides only whether discovery
  falls back to the recent-release feed: a release GitHub does serve but that
  publishes no catalog index asset must still surface as that repository's sync
  error instead of quietly importing a different release. Neither outcome
  changes when Oban tries again seconds later, so an unattended sync records the
  reason and leaves the next attempt to its scheduled successor.
  """
  @spec permanent_failure?(term()) :: boolean()
  def permanent_failure?(reason) when is_binary(reason) do
    missing_release?(reason) or
      (String.contains?(reason, "Release asset ") and String.contains?(reason, " was not found"))
  end

  def permanent_failure?(_reason), do: false

  # Sentinel release option in the Plugins settings UI meaning "every release
  # this repository publishes" (see @all_releases_tag in
  # Admin.PluginPackageLive.Index). It is not a GitHub tag, so the
  # unattended-sync fallback must not treat it as an unpublished deployed tag:
  # the admin import keeps its historical exact-only lookup and the 404
  # surfaces instead of silently importing another feed.
  @admin_all_releases_sentinel "__all_releases__"

  @doc """
  The Plugins settings UI "all releases" sentinel, which is never a GitHub tag.
  """
  @spec admin_all_releases_sentinel() :: String.t()
  def admin_all_releases_sentinel, do: @admin_all_releases_sentinel

  @doc """
  Discovers catalog entries for unattended sync.

  Prefers the exact deployed release tag when GitHub has that release.
  When that tag 404s -- unpublished VERSION, a sha-style demo rollout, or a
  private repository the process cannot see -- falls back to the recent-release
  feed. Errors from that feed are returned to the caller. The success triple
  reports which feed served the entries so callers do not re-filter a fallback
  feed by the tag that 404d.
  """
  @spec resolve_catalog(String.t() | nil, (String.t() -> {:ok, term()} | {:error, term()}), (-> {:ok, term()}
                                                                                                | {:error, term()})) ::
          {:ok, term(), :exact | :recent} | {:error, term()}
  def resolve_catalog(release_tag, exact_fun, recent_fun)
      when is_binary(release_tag) and release_tag != "" and is_function(exact_fun, 1) and is_function(recent_fun, 0) do
    case exact_fun.(release_tag) do
      {:ok, items} ->
        {:ok, items, :exact}

      {:error, reason} ->
        if missing_release?(reason) do
          Logger.warning(
            "Deployed GitHub release #{release_tag} is not available; falling back to recent releases",
            reason: inspect(reason, limit: 20, printable_limit: 500)
          )

          case recent_fun.() do
            {:ok, items} -> {:ok, items, :recent}
            {:error, _} = error -> error
          end
        else
          {:error, reason}
        end
    end
  end

  def resolve_catalog(_release_tag, _exact_fun, recent_fun) when is_function(recent_fun, 0) do
    case recent_fun.() do
      {:ok, items} -> {:ok, items, :recent}
      {:error, _} = error -> error
    end
  end

  def fetch_recent_releases(repo, limit) do
    url = "#{repo.api_base_url}/repos/#{repo.owner}/#{repo.repo}/releases?per_page=#{normalize_limit(limit)}"

    with {:ok, request_url} <- validate_provider_api_url(repo, url),
         {:ok, response} <- request(request_url, headers: api_headers(repo), decode_body: true) do
      case response do
        %Req.Response{status: 200, body: body} when is_list(body) -> {:ok, body}
        %Req.Response{status: 200} -> {:error, "Plugin release browser returned an unexpected payload"}
        %Req.Response{status: 404} -> {:error, not_found_reason(repo, "Repository or releases not found")}
        %Req.Response{status: status} when status in [401, 403] -> {:error, credential_reason(repo, status)}
        %Req.Response{status: status} -> {:error, "Recent plugin releases could not be loaded (HTTP #{status})"}
      end
    end
  end

  defp not_found_reason(repo, fallback) do
    if repo_token(repo) do
      fallback <>
        ". If this repository is private, its access token may lack access to it " <>
        "(GitHub answers 404, not 403, for a repository the token cannot see)."
    else
      fallback <>
        ". If this repository is private, attach a GitHub access token to it: " <>
        "an unauthenticated request cannot see private repositories and GitHub " <>
        "reports that as 404."
    end
  end

  defp credential_reason(repo, status) do
    if repo_token(repo) do
      "Plugin repository rejected the configured access token (HTTP #{status}); " <>
        "the token may be expired or missing repository read access."
    else
      "Plugin repository requires authentication (HTTP #{status}); attach a GitHub access token."
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
    if repo_token(repo) do
      # A private repository's `browser_download_url` returns 404 for a PAT:
      # private release assets are only reachable through the API endpoint, which
      # 302s to a short-lived pre-signed URL.
      with {:ok, url} <- require_value(Map.get(asset, "url"), "Release asset API URL is missing"),
           {:ok, request_url} <- validate_provider_asset_url(repo, url) do
        fetch_url_binary(repo, request_url, @max_asset_redirects, :api)
      end
    else
      with {:ok, url} <-
             require_value(Map.get(asset, "browser_download_url"), "Release asset URL is missing"),
           {:ok, request_url} <- validate_provider_asset_url(repo, url) do
        fetch_url_binary(repo, request_url)
      end
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
    headers = [{"accept", "application/vnd.oci.image.manifest.v1+json"} | asset_headers(repo, url)]

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
    case request_oci(url, ref, headers: asset_headers(repo, url), decode_body: false) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, IO.iodata_to_binary(body)}

      {:ok, %Req.Response{status: status} = response} when status in [301, 302, 303, 307, 308] ->
        with {:ok, redirect_url} <- redirect_location(url, response),
             {:ok, request_url} <- validate_provider_asset_url(repo, redirect_url) do
          # Always :asset from here: the pre-signed target must not receive the
          # Authorization header, and auth_host?/1 is what enforces that.
          fetch_url_binary(repo, request_url, remaining_redirects - 1, :asset)
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

  def fetch_url_binary(repo, url), do: fetch_url_binary(repo, url, @max_asset_redirects, :asset)

  def fetch_url_binary(repo, url, remaining_redirects), do: fetch_url_binary(repo, url, remaining_redirects, :asset)

  def fetch_url_binary(_repo, _url, remaining_redirects, _mode) when remaining_redirects < 0 do
    {:error, "Plugin artifact download exceeded redirect limit"}
  end

  def fetch_url_binary(repo, url, remaining_redirects, mode) do
    headers =
      case mode do
        :api -> asset_api_headers(repo)
        :asset -> asset_headers(repo, url)
      end

    case request(url, headers: headers, decode_body: false) do
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

  defp api_headers(repo) do
    [{"user-agent", "serviceradar"}, {"accept", "application/vnd.github+json"} | auth_headers(repo)]
  end

  defp asset_headers(repo, url) do
    headers = [{"user-agent", "serviceradar"}]

    # Deliberately narrow. A release-asset download 302s to a pre-signed URL on
    # objects.githubusercontent.com that carries its own authorization;
    # forwarding the PAT there both breaks the request and discloses the token
    # to a host with no business seeing it. Covered by a test so this stays a
    # decision rather than an accident of the host list.
    if auth_host?(url) do
      headers ++ auth_headers(repo)
    else
      headers
    end
  end

  # Binary asset downloads through the API endpoint must ask for the bytes;
  # without this GitHub returns the asset's JSON metadata instead.
  defp asset_api_headers(repo) do
    [{"user-agent", "serviceradar"}, {"accept", "application/octet-stream"} | auth_headers(repo)]
  end

  defp auth_headers(repo) do
    case repo_token(repo) || configured_token() do
      nil -> []
      token -> [{"authorization", "Bearer #{token}"}]
    end
  end

  defp repo_token(%{token: token}) when is_binary(token) and token != "", do: token
  defp repo_token(_repo), do: nil

  defp configured_token do
    Application.get_env(:serviceradar_web_ng, :first_party_plugin_import_github_token) ||
      System.get_env("GITHUB_TOKEN") ||
      System.get_env("GH_TOKEN")
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
