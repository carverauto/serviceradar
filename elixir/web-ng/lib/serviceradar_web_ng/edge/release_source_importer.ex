defmodule ServiceRadarWebNG.Edge.ReleaseSourceImporter do
  @moduledoc """
  Imports signed agent release metadata from repository-hosted release assets.
  """

  @default_manifest_asset_name "serviceradar-agent-release-manifest.json"
  @default_signature_asset_name "serviceradar-agent-release-manifest.sig"
  @default_recent_release_limit 10
  @provider_options [
    {"GitHub Releases", "github"},
    {"Forgejo Releases", "forgejo"}
  ]

  @type import_attrs :: %{
          optional(:provider) => String.t(),
          optional(String.t()) => String.t()
        }

  @spec provider_options() :: [{String.t(), String.t()}]
  def provider_options, do: @provider_options

  @spec default_manifest_asset_name() :: String.t()
  def default_manifest_asset_name, do: @default_manifest_asset_name

  @spec default_signature_asset_name() :: String.t()
  def default_signature_asset_name, do: @default_signature_asset_name

  @spec list_recent_releases(import_attrs(), pos_integer()) :: {:ok, [map()]} | {:error, String.t()}
  def list_recent_releases(attrs, limit \\ @default_recent_release_limit)

  def list_recent_releases(attrs, limit) when is_map(attrs) do
    manifest_asset_name =
      normalize_string(Map.get(attrs, "manifest_asset_name") || Map.get(attrs, :manifest_asset_name)) ||
        @default_manifest_asset_name

    signature_asset_name =
      normalize_string(Map.get(attrs, "signature_asset_name") || Map.get(attrs, :signature_asset_name)) ||
        @default_signature_asset_name

    with {:ok, repo} <- import_repo(attrs),
         {:ok, releases} <- fetch_recent_releases(repo, limit) do
      {:ok,
       releases
       |> Enum.map(&summarize_release(&1, manifest_asset_name, signature_asset_name))
       |> Enum.reject(&is_nil(&1))}
    end
  end

  def list_recent_releases(_attrs, _limit), do: {:error, "Release import settings are invalid"}

  @spec import(import_attrs()) :: {:ok, map()} | {:error, String.t()}
  def import(attrs) when is_map(attrs) do
    release_tag = Map.get(attrs, "release_tag") || Map.get(attrs, :release_tag)

    manifest_asset_name =
      normalize_string(Map.get(attrs, "manifest_asset_name") || Map.get(attrs, :manifest_asset_name)) ||
        @default_manifest_asset_name

    signature_asset_name =
      normalize_string(Map.get(attrs, "signature_asset_name") || Map.get(attrs, :signature_asset_name)) ||
        @default_signature_asset_name

    with {:ok, provider} <- selected_provider(attrs),
         {:ok, repo} <- import_repo(attrs),
         {:ok, tag} <- require_value(release_tag, "Release tag is required"),
         {:ok, release} <- fetch_release(repo, tag),
         {:ok, manifest_asset} <- fetch_release_asset(release, manifest_asset_name),
         {:ok, signature_asset} <- fetch_release_asset(release, signature_asset_name),
         {:ok, manifest_json} <- fetch_binary_asset(repo, manifest_asset),
         {:ok, signature} <- fetch_signature(repo, signature_asset),
         {:ok, manifest} <- decode_manifest(manifest_json),
         {:ok, version} <- manifest_version(manifest) do
      {:ok,
       %{
         version: version,
         signature: signature,
         release_notes: normalize_string(Map.get(release, "body")),
         manifest: manifest,
         metadata: %{
           "source" => %{
             "type" => "repo_release",
             "provider" => provider,
             "repo_url" => repo.repo_url,
             "release_tag" => tag,
             "release_name" => normalize_string(Map.get(release, "name")),
             "release_url" => normalize_string(Map.get(release, "html_url")),
             "manifest_asset_name" => manifest_asset_name,
             "signature_asset_name" => signature_asset_name,
             "imported_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
           }
         }
       }}
    end
  end

  def import(_attrs), do: {:error, "Release import settings are invalid"}

  defp selected_provider(attrs) when is_map(attrs) do
    attrs
    |> Map.get("provider", Map.get(attrs, :provider))
    |> normalize_provider()
    |> validate_provider()
  end

  defp selected_provider(_attrs), do: {:error, "Select a supported release provider"}

  defp import_repo(attrs) when is_map(attrs) do
    repo_url = Map.get(attrs, "repo_url") || Map.get(attrs, :repo_url)

    with {:ok, provider} <- selected_provider(attrs) do
      parse_repo_url(provider, repo_url)
    end
  end

  defp import_repo(_attrs), do: {:error, "Release import settings are invalid"}

  defp validate_provider(provider) when provider in ["github", "forgejo"], do: {:ok, provider}
  defp validate_provider(_provider), do: {:error, "Select a supported release provider"}

  defp parse_repo_url("github", url) do
    with {:ok, %URI{scheme: scheme, host: "github.com"} = uri} <- parse_uri(url),
         true <- scheme in ["http", "https"],
         {:ok, owner, repo} <- repo_owner_and_name(uri.path) do
      {:ok,
       %{
         provider: "github",
         repo_url: "#{scheme}://github.com/#{owner}/#{repo}",
         api_base_url: "https://api.github.com",
         owner: owner,
         repo: repo
       }}
    else
      _ -> {:error, "GitHub repository URL must look like https://github.com/<owner>/<repo>"}
    end
  end

  defp parse_repo_url("forgejo", url) do
    with {:ok, %URI{scheme: scheme, host: host} = uri} <- parse_uri(url),
         true <- scheme in ["http", "https"],
         true <- is_binary(host) and host != "",
         {:ok, owner, repo} <- repo_owner_and_name(uri.path) do
      {:ok,
       %{
         provider: "forgejo",
         repo_url: "#{scheme}://#{host_port(uri)}/#{owner}/#{repo}",
         api_base_url: "#{scheme}://#{host_port(uri)}/api/v1",
         owner: owner,
         repo: repo
       }}
    else
      _ -> {:error, "Forgejo repository URL must look like https://forgejo.example.com/<owner>/<repo>"}
    end
  end

  defp parse_uri(nil), do: {:error, :missing_repo_url}
  defp parse_uri(""), do: {:error, :missing_repo_url}

  defp parse_uri(url) when is_binary(url) do
    uri = url |> String.trim() |> URI.parse()

    if is_binary(uri.host) and uri.host != "" do
      {:ok, uri}
    else
      {:error, :invalid_repo_url}
    end
  end

  defp parse_uri(_url), do: {:error, :invalid_repo_url}

  defp host_port(%URI{scheme: "https", host: host, port: 443}), do: host
  defp host_port(%URI{scheme: "http", host: host, port: 80}), do: host
  defp host_port(%URI{host: host, port: nil}), do: host
  defp host_port(%URI{host: host, port: port}), do: "#{host}:#{port}"

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

  defp fetch_release(repo, tag) do
    url = "#{repo.api_base_url}/repos/#{repo.owner}/#{repo.repo}/releases/tags/#{URI.encode(tag)}"

    case http_client().get(url, headers: api_headers(repo.provider)) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 404}} ->
        {:error, "Release tag #{tag} was not found for #{repo.owner}/#{repo.repo}"}

      {:ok, %Req.Response{status: status}} ->
        {:error, "Release import failed with HTTP #{status}"}

      {:error, reason} ->
        {:error, "Release import failed: #{inspect(reason)}"}
    end
  end

  defp fetch_recent_releases(repo, limit) do
    url = "#{repo.api_base_url}/repos/#{repo.owner}/#{repo.repo}/releases?per_page=#{normalize_limit(limit)}"

    case http_client().get(url, headers: api_headers(repo.provider)) do
      {:ok, %Req.Response{status: 200, body: body}} when is_list(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: _body}} ->
        {:error, "Release browser returned an unexpected payload"}

      {:ok, %Req.Response{status: status}} ->
        {:error, "Recent releases could not be loaded (HTTP #{status})"}

      {:error, reason} ->
        {:error, "Recent releases could not be loaded: #{inspect(reason)}"}
    end
  end

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 20)
  defp normalize_limit(_limit), do: @default_recent_release_limit

  defp fetch_release_asset(release, asset_name) do
    assets = List.wrap(Map.get(release, "assets"))

    case Enum.find(assets, &(normalize_string(Map.get(&1, "name")) == asset_name)) do
      nil -> {:error, "Release asset #{asset_name} was not found"}
      asset -> {:ok, asset}
    end
  end

  defp fetch_binary_asset(repo, asset) do
    url = normalize_string(Map.get(asset, "browser_download_url"))

    with {:ok, asset_url} <- require_value(url, "Release asset URL is missing") do
      case http_client().get(asset_url, headers: asset_headers(repo.provider), decode_body: false) do
        {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
          {:ok, body}

        {:ok, %Req.Response{status: 200, body: body}} ->
          {:ok, IO.iodata_to_binary(body)}

        {:ok, %Req.Response{status: status}} ->
          {:error, "Release asset download failed with HTTP #{status}"}

        {:error, reason} ->
          {:error, "Release asset download failed: #{inspect(reason)}"}
      end
    end
  end

  defp fetch_signature(repo, asset) do
    with {:ok, signature_blob} <- fetch_binary_asset(repo, asset) do
      require_value(signature_blob, "Release signature asset is empty")
    end
  end

  defp summarize_release(release, manifest_asset_name, signature_asset_name) when is_map(release) do
    tag = normalize_string(Map.get(release, "tag_name"))
    assets = List.wrap(Map.get(release, "assets"))

    if is_nil(tag) do
      nil
    else
      manifest_present? = release_asset_present?(assets, manifest_asset_name)
      signature_present? = release_asset_present?(assets, signature_asset_name)

      %{
        tag: tag,
        name: normalize_string(Map.get(release, "name")) || tag,
        body: normalize_string(Map.get(release, "body")),
        html_url: normalize_string(Map.get(release, "html_url")),
        published_at:
          normalize_string(Map.get(release, "published_at")) ||
            normalize_string(Map.get(release, "created_at")),
        draft?: Map.get(release, "draft") == true,
        prerelease?: Map.get(release, "prerelease") == true,
        manifest_present?: manifest_present?,
        signature_present?: signature_present?,
        import_ready?: manifest_present? and signature_present?,
        asset_names:
          assets
          |> Enum.map(&normalize_string(Map.get(&1, "name")))
          |> Enum.reject(&is_nil/1)
      }
    end
  end

  defp summarize_release(_release, _manifest_asset_name, _signature_asset_name), do: nil

  defp release_asset_present?(assets, asset_name) when is_list(assets) do
    Enum.any?(assets, &(normalize_string(Map.get(&1, "name")) == asset_name))
  end

  defp decode_manifest(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = manifest} -> {:ok, manifest}
      {:ok, _other} -> {:error, "Release manifest asset must contain a JSON object"}
      {:error, _reason} -> {:error, "Release manifest asset is not valid JSON"}
    end
  end

  defp decode_manifest(_body), do: {:error, "Release manifest asset is not valid JSON"}

  defp manifest_version(manifest) when is_map(manifest) do
    manifest
    |> Map.get("version")
    |> require_value("Release manifest must include a version")
  end

  defp require_value(value, message) do
    case normalize_string(value) do
      nil -> {:error, message}
      present -> {:ok, present}
    end
  end

  defp normalize_provider(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_provider(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_provider()
  defp normalize_provider(_value), do: nil

  defp normalize_string(nil), do: nil

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(value), do: value |> to_string() |> normalize_string()

  defp api_headers("github") do
    [{"user-agent", "serviceradar"}, {"accept", "application/vnd.github+json"} | auth_headers("github")]
  end

  defp api_headers("forgejo") do
    [{"user-agent", "serviceradar"}, {"accept", "application/json"} | auth_headers("forgejo")]
  end

  defp asset_headers(provider), do: [{"user-agent", "serviceradar"} | auth_headers(provider)]

  defp auth_headers("github") do
    case Application.get_env(:serviceradar_web_ng, :agent_release_import_github_token) ||
           System.get_env("GITHUB_TOKEN") do
      nil -> []
      token -> [{"authorization", "Bearer #{token}"}]
    end
  end

  defp auth_headers("forgejo") do
    case Application.get_env(:serviceradar_web_ng, :agent_release_import_forgejo_token) ||
           System.get_env("FORGEJO_TOKEN") do
      nil -> []
      token -> [{"authorization", "token #{token}"}]
    end
  end

  defp http_client do
    Application.get_env(:serviceradar_web_ng, :agent_release_import_http_client, Req)
  end
end
