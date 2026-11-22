defmodule ServiceRadar.Catalog.RepoUrl do
  @moduledoc """
  Canonical HTTPS repository and catalog portal URL parser and normalizer for
  `CatalogRepository` across GitHub, GitLab (including nested group/subgroup paths),
  Gitea/Forgejo, and direct HTTPS catalog portal endpoints (such as
  `https://developer.serviceradar.cloud` / `https://developer.serviceradar.cloud/packs/index.json`).

  Rejects non-HTTPS schemes, embedded credentials (`userinfo`), query strings,
  and fragments.
  """

  @type provider :: :github | :gitlab | :gitea | :portal
  @type mode :: :release_catalog | :gitops_tree

  @type parsed :: %{
          provider: provider(),
          kind: :git_repo | :portal_index,
          repo_url: String.t(),
          index_url: String.t() | nil,
          scheme: String.t(),
          host: String.t(),
          port: pos_integer(),
          owner: String.t() | nil,
          repo: String.t() | nil,
          full_path: String.t(),
          api_base_url: String.t()
        }

  @default_portal_index_path "packs/index.json"

  @doc """
  Parses and normalizes an HTTPS repository or catalog portal URL for `provider`
  and optional `mode` (`:release_catalog | :gitops_tree`).
  """
  @spec parse(term(), provider() | String.t() | nil, mode() | String.t() | nil) ::
          {:ok, parsed()} | {:error, atom()}
  def parse(url, provider \\ nil, mode \\ :release_catalog)

  def parse(url, provider, mode) when is_binary(url) do
    normalized_mode = normalize_mode(mode)

    with {:ok, uri} <- parse_https_uri(url),
         :ok <- validate_host(uri.host),
         {:ok, normalized_provider} <- normalize_provider(provider, uri, normalized_mode) do
      if portal_endpoint?(uri, normalized_provider, normalized_mode) do
        build_portal_parsed(uri)
      else
        build_git_repo_parsed(uri, normalized_provider)
      end
    end
  end

  def parse(_url, _provider, _mode), do: {:error, :invalid_repo_url}

  @doc """
  Returns the canonical normalized repository or portal URL, or the original value if invalid.
  """
  @spec normalize(term(), provider() | String.t() | nil, mode() | String.t() | nil) :: term()
  def normalize(url, provider \\ nil, mode \\ :release_catalog) do
    case parse(url, provider, mode) do
      {:ok, %{repo_url: normalized}} -> normalized
      {:error, _} -> url
    end
  end

  @doc """
  Human-readable validation message for a URL parse error.
  """
  @spec describe_error(atom()) :: String.t()
  def describe_error(:insecure_scheme), do: "must use https://"
  def describe_error(:userinfo_forbidden), do: "must not embed credentials in the repository URL"

  def describe_error(:portal_not_gitops),
    do: "gitops_tree repositories must point to a GitHub, GitLab, or Gitea repository URL"

  def describe_error(:invalid_repo_path),
    do: "must include owner and repository path segments (e.g. https://github.com/owner/repo)"

  def describe_error(_reason),
    do:
      "must be a valid HTTPS repository or catalog portal URL (e.g. https://github.com/carverauto/serviceradar or https://developer.serviceradar.cloud/packs/index.json)"

  defp normalize_mode(:gitops_tree), do: :gitops_tree
  defp normalize_mode("gitops_tree"), do: :gitops_tree
  defp normalize_mode(_), do: :release_catalog

  defp normalize_provider(nil, %URI{host: host, path: path}, mode) when is_binary(host) do
    down = String.downcase(host)
    trimmed_path = String.trim(path || "", "/")

    cond do
      mode == :release_catalog and
          (down == "developer.serviceradar.cloud" or String.ends_with?(trimmed_path, ".json") or
             trimmed_path == "") ->
        {:ok, :portal}

      down == "github.com" or String.contains?(down, "github") ->
        {:ok, :github}

      down == "gitlab.com" or String.contains?(down, "gitlab") ->
        {:ok, :gitlab}

      true ->
        {:ok, :gitea}
    end
  end

  defp normalize_provider(:portal, _uri, :gitops_tree), do: {:error, :portal_not_gitops}
  defp normalize_provider("portal", _uri, :gitops_tree), do: {:error, :portal_not_gitops}

  defp normalize_provider(provider, uri, mode)
       when provider in [:github, :gitlab, :gitea, :portal] do
    down = String.downcase(uri.host || "")
    trimmed_path = String.trim(uri.path || "", "/")

    if mode == :release_catalog and provider != :portal and
         (down == "developer.serviceradar.cloud" or String.ends_with?(trimmed_path, ".json") or
            trimmed_path in ["", "packs"]) do
      {:ok, :portal}
    else
      {:ok, provider}
    end
  end

  defp normalize_provider("github", uri, mode), do: normalize_provider(:github, uri, mode)
  defp normalize_provider("gitlab", uri, mode), do: normalize_provider(:gitlab, uri, mode)
  defp normalize_provider("gitea", uri, mode), do: normalize_provider(:gitea, uri, mode)
  defp normalize_provider("portal", uri, mode), do: normalize_provider(:portal, uri, mode)
  defp normalize_provider(_other, _uri, _mode), do: {:error, :invalid_provider}

  defp portal_endpoint?(_uri, :portal, :release_catalog), do: true
  defp portal_endpoint?(_uri, _provider, _mode), do: false

  defp build_portal_parsed(uri) do
    origin = origin_string(uri)
    raw_segments = String.split(uri.path || "", "/", trim: true)

    with :ok <- validate_portal_segments(raw_segments) do
      index_rel_path =
        cond do
          raw_segments == [] ->
            @default_portal_index_path

          String.ends_with?(List.last(raw_segments), ".json") ->
            Enum.join(raw_segments, "/")

          true ->
            Enum.join(raw_segments ++ ["index.json"], "/")
        end

      canonical_url =
        if raw_segments == [] do
          "#{origin}/#{@default_portal_index_path}"
        else
          "#{origin}/#{Enum.join(raw_segments, "/")}"
        end

      {:ok,
       %{
         provider: :portal,
         kind: :portal_index,
         repo_url: canonical_url,
         index_url: "#{origin}/#{index_rel_path}",
         scheme: "https",
         host: String.downcase(uri.host),
         port: uri.port || 443,
         owner: nil,
         repo: nil,
         full_path: index_rel_path,
         api_base_url: origin
       }}
    end
  end

  defp validate_portal_segments(segments) do
    if Enum.all?(segments, &valid_segment?/1) do
      :ok
    else
      {:error, :invalid_repo_path}
    end
  end

  defp build_git_repo_parsed(uri, provider) do
    with {:ok, segments} <- extract_segments(uri.path, provider) do
      full_path = Enum.join(segments, "/")
      repo = List.last(segments)
      owner = segments |> Enum.drop(-1) |> Enum.join("/")
      origin = origin_string(uri)

      {:ok,
       %{
         provider: provider,
         kind: :git_repo,
         repo_url: "#{origin}/#{full_path}",
         index_url: nil,
         scheme: "https",
         host: String.downcase(uri.host),
         port: uri.port || 443,
         owner: owner,
         repo: repo,
         full_path: full_path,
         api_base_url: api_base_url(origin, String.downcase(uri.host), provider)
       }}
    end
  end

  defp parse_https_uri(url) do
    trimmed = String.trim(url)

    case URI.parse(trimmed) do
      %URI{scheme: scheme} when scheme != "https" ->
        {:error, :insecure_scheme}

      %URI{userinfo: userinfo} when not is_nil(userinfo) ->
        {:error, :userinfo_forbidden}

      %URI{host: host, query: nil, fragment: nil, port: port} = uri
      when is_binary(host) and host != "" and (is_nil(port) or port in 1..65_535) ->
        {:ok, uri}

      _ ->
        {:error, :invalid_repo_url}
    end
  end

  defp validate_host(host) when is_binary(host) do
    down = String.downcase(host)

    if String.contains?(down, [" ", "/", "\\"]) do
      {:error, :invalid_repo_url}
    else
      :ok
    end
  end

  defp extract_segments(path, provider) when is_binary(path) do
    raw_segments =
      path
      |> String.split("/", trim: true)
      |> drop_gitlab_delimiter()

    case {provider, raw_segments} do
      {_, segments} when length(segments) < 2 ->
        {:error, :invalid_repo_path}

      {:gitlab, segments} ->
        normalize_segments(segments)

      {_, [owner, repo | _rest]} ->
        normalize_segments([owner, repo])
    end
  end

  defp extract_segments(_path, _provider), do: {:error, :invalid_repo_path}

  defp drop_gitlab_delimiter(segments) do
    Enum.take_while(segments, &(&1 != "-"))
  end

  defp normalize_segments(segments) do
    last_idx = length(segments) - 1

    cleaned =
      segments
      |> Enum.with_index()
      |> Enum.map(fn {seg, idx} ->
        if idx == last_idx, do: String.trim_trailing(seg, ".git"), else: seg
      end)

    if Enum.all?(cleaned, &valid_segment?/1) do
      {:ok, cleaned}
    else
      {:error, :invalid_repo_path}
    end
  end

  defp valid_segment?(seg) when is_binary(seg) do
    seg != "" and seg not in [".", ".."] and Regex.match?(~r/\A[A-Za-z0-9._-]+\z/, seg)
  end

  defp origin_string(%URI{host: host, port: port}) when port in [nil, 443] do
    "https://#{String.downcase(host)}"
  end

  defp origin_string(%URI{host: host, port: port}) do
    "https://#{String.downcase(host)}:#{port}"
  end

  defp api_base_url(_origin, "github.com", :github), do: "https://api.github.com"
  defp api_base_url(origin, _host, :github), do: "#{origin}/api/v3"
  defp api_base_url(origin, _host, :gitlab), do: "#{origin}/api/v4"
  defp api_base_url(origin, _host, :gitea), do: "#{origin}/api/v1"
end
