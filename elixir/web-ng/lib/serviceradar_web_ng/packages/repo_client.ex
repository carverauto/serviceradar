defmodule ServiceRadarWebNG.Packages.RepoClient do
  @moduledoc """
  Shared GitHub repository client for plugin, dashboard, and report import sources.

  All external HTTP goes through `ServiceRadar.HTTP.EgressClient` by default,
  routing requests through the configured egress proxy in proxied deployments.
  The HTTP client is injectable via `opts[:http_client]` for testing.

  Covered: repository-URL parsing (HTTPS and SSH), repo-boundary enforcement,
  ref resolution and normalization, path validation, raw file fetch, GitHub API
  calls, GitHub release listing, index-asset decode, and GPG signature
  verification policy.

  OCI/Cosign and first-party bundle machinery are not here; they stay in
  `ServiceRadarWebNG.Plugins.FirstPartyReleaseClient`.

  ## HTTP client injection

  Every function that performs HTTP accepts an `opts` keyword list. Pass
  `http_client: MyMockClient` in tests; the module must implement
  `fetch_body/2` matching `ServiceRadar.HTTP.EgressClient.fetch_body/2`:
  `{:ok, %Req.Response{}}` or `{:error, term()}`.
  """

  alias ServiceRadar.HTTP.EgressClient
  alias ServiceRadar.Plugins.RepoUrl

  @github_api_host "api.github.com"
  @max_ref_length 200
  @max_path_length 240

  # ---------------------------------------------------------------------------
  # URL parsing
  # ---------------------------------------------------------------------------

  @doc """
  Parses a GitHub repository URL (HTTPS or SSH form) into `%{owner:, repo:}`.

  For HTTPS URLs, delegates to `ServiceRadar.Plugins.RepoUrl` so this parser
  stays in sync with the canonical one that validates URLs at write time.
  SSH remote form (`host:owner/repo`) is also accepted because operator-supplied
  refs sometimes come from `git clone` output.
  """
  @spec parse_repo_url(term()) :: {:ok, %{owner: String.t(), repo: String.t()}} | {:error, atom()}
  def parse_repo_url(nil), do: {:error, :missing_repo_url}
  def parse_repo_url(""), do: {:error, :missing_repo_url}

  def parse_repo_url(url) when is_binary(url) do
    trimmed = String.trim(url)

    if trimmed == "" do
      {:error, :missing_repo_url}
    else
      case RepoUrl.parse(trimmed) do
        {:ok, %{owner: owner, repo: repo}} ->
          {:ok, %{owner: owner, repo: repo}}

        {:error, _} ->
          case Regex.run(~r/^git@github\.com:([^\/]+)\/(.+?)(?:\.git)?$/, trimmed) do
            [_full, owner, repo] -> {:ok, %{owner: owner, repo: repo}}
            _ -> {:error, :invalid_repo_url}
          end
      end
    end
  end

  def parse_repo_url(_url), do: {:error, :invalid_repo_url}

  # ---------------------------------------------------------------------------
  # Repo boundary enforcement
  # ---------------------------------------------------------------------------

  @doc """
  Enforces the operator-configured repository allowlist.

  When no GitHub token is configured, any public repository is reachable and
  `:ok` is returned. When a token is present, the repository and owner must
  appear in the policy's trusted lists.

  Accepts `opts[:github_token]` to override the environment token lookup.
  """
  @spec enforce_repo_boundary(%{owner: String.t(), repo: String.t()}, keyword()) ::
          :ok | {:error, :untrusted_repo}
  def enforce_repo_boundary(%{owner: owner, repo: repo}, opts \\ []) do
    token = opts[:github_token] || configured_github_token()

    if token in [nil, ""] do
      :ok
    else
      policy = verification_policy(opts)
      normalized = normalize_repository("#{owner}/#{repo}")

      if normalized in policy.trusted_github_repositories or
           String.downcase(owner) in policy.trusted_github_owners do
        :ok
      else
        {:error, :untrusted_repo}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Ref resolution
  # ---------------------------------------------------------------------------

  @doc """
  Resolves `ref` to a commit SHA, populating GPG verification metadata via the
  GitHub Commits API. A nil or empty ref resolves the repository's default
  branch.
  """
  @spec resolve_ref(%{owner: String.t(), repo: String.t()}, String.t() | nil, keyword()) ::
          {:ok, %{sha: String.t(), verification: map()}} | {:error, term()}
  def resolve_ref(repo, ref, opts \\ [])

  def resolve_ref(repo, ref, opts) when is_binary(ref) do
    if String.trim(ref) == "",
      do: resolve_ref(repo, nil, opts),
      else: fetch_commit_verification(repo, String.trim(ref), opts)
  end

  def resolve_ref(repo, _ref, opts) do
    case fetch_default_branch(repo, opts) do
      {:ok, branch} -> fetch_commit_verification(repo, branch, opts)
      {:error, _} -> fetch_commit_verification(repo, "main", opts)
    end
  end

  @doc "Validates and normalizes a git ref (branch, tag, or commit SHA)."
  @spec normalize_ref(String.t()) :: {:ok, String.t()} | {:error, :invalid_ref}
  def normalize_ref(ref) when is_binary(ref) do
    trimmed = String.trim(ref)

    cond do
      trimmed == "" -> {:error, :invalid_ref}
      String.length(trimmed) > @max_ref_length -> {:error, :invalid_ref}
      String.contains?(trimmed, ["..", "\\", <<0>>]) -> {:error, :invalid_ref}
      not Regex.match?(~r/\A[0-9A-Za-z._\-\/]+\z/, trimmed) -> {:error, :invalid_ref}
      true -> {:ok, trimmed}
    end
  end

  @doc "Validates and normalizes a repository-relative file path."
  @spec normalize_repo_path(String.t(), atom()) :: {:ok, String.t()} | {:error, atom()}
  def normalize_repo_path(path, error_atom) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" ->
        {:error, error_atom}

      String.length(trimmed) > @max_path_length ->
        {:error, error_atom}

      String.starts_with?(trimmed, "/") ->
        {:error, error_atom}

      String.contains?(trimmed, ["\\", <<0>>]) ->
        {:error, error_atom}

      true ->
        segments = String.split(trimmed, "/", trim: true)

        if segments == [] or
             Enum.any?(segments, &(&1 in [".", ".."])) or
             Enum.any?(segments, &(not Regex.match?(~r/\A[0-9A-Za-z._\-]+\z/, &1))) do
          {:error, error_atom}
        else
          {:ok, Enum.join(segments, "/")}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Raw file fetch
  # ---------------------------------------------------------------------------

  @doc """
  Fetches a file at `path` from `repo` at `ref` on `raw.githubusercontent.com`,
  returning the contents as a binary.

  Routes through the configured HTTP client (EgressClient by default).
  """
  @spec fetch_raw(%{owner: String.t(), repo: String.t()}, String.t(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def fetch_raw(%{owner: owner, repo: repo}, ref, path, opts \\ []) do
    url = "https://raw.githubusercontent.com/#{owner}/#{repo}/#{ref}/#{encode_path(path)}"
    headers = build_headers(opts, [])

    case do_fetch_body(url, headers, opts) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: 200, body: body}} -> {:ok, IO.iodata_to_binary(body)}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # GitHub API calls
  # ---------------------------------------------------------------------------

  @doc "GET `url` against the GitHub API and return the decoded JSON response body."
  @spec github_api_get(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def github_api_get(url, opts \\ []) do
    headers = build_headers(opts, [{"accept", "application/vnd.github+json"}])

    case do_fetch_body(url, headers, opts) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:error, :invalid_json}
        end

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Release listing
  # ---------------------------------------------------------------------------

  @doc "Fetches release metadata for `tag` from the GitHub Releases API."
  @spec fetch_release(%{owner: String.t(), repo: String.t()}, String.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def fetch_release(%{owner: owner, repo: repo} = parsed, tag, opts \\ []) do
    url = "https://#{@github_api_host}/repos/#{owner}/#{repo}/releases/tags/#{URI.encode(tag)}"
    headers = build_headers(opts, [{"accept", "application/vnd.github+json"}])

    case do_fetch_body(url, headers, opts) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, %{} = decoded} -> {:ok, decoded}
          _ -> {:error, "Release import returned unexpected payload"}
        end

      {:ok, %{status: 404}} ->
        {:error, not_found_reason(parsed, opts, "Release tag #{tag} was not found")}

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, credential_reason(parsed, opts, status)}

      {:ok, %{status: status}} ->
        {:error, "Release import failed with HTTP #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc "Fetches the `limit` most recent releases for a repository."
  @spec fetch_recent_releases(%{owner: String.t(), repo: String.t()}, pos_integer(), keyword()) ::
          {:ok, list()} | {:error, String.t()}
  def fetch_recent_releases(%{owner: owner, repo: repo} = parsed, limit, opts \\ []) do
    capped = normalize_limit(limit)
    url = "https://#{@github_api_host}/repos/#{owner}/#{repo}/releases?per_page=#{capped}"
    headers = build_headers(opts, [{"accept", "application/vnd.github+json"}])

    case do_fetch_body(url, headers, opts) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, releases} when is_list(releases) -> {:ok, releases}
          _ -> {:error, "Plugin release browser returned an unexpected payload"}
        end

      {:ok, %{status: 200}} ->
        {:error, "Plugin release browser returned an unexpected payload"}

      {:ok, %{status: 404}} ->
        {:error, not_found_reason(parsed, opts, "Repository or releases not found")}

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, credential_reason(parsed, opts, status)}

      {:ok, %{status: status}} ->
        {:error, "Recent plugin releases could not be loaded (HTTP #{status})"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc "Decodes a JSON release index asset body into a map."
  @spec decode_index(binary()) :: {:ok, map()} | {:error, String.t()}
  def decode_index(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = index} -> {:ok, index}
      {:ok, _} -> {:error, "Plugin import index must contain a JSON object"}
      {:error, _} -> {:error, "Plugin import index asset is not valid JSON"}
    end
  end

  # ---------------------------------------------------------------------------
  # Verification policy
  # ---------------------------------------------------------------------------

  @doc """
  Enforces the operator-configured GPG verification policy for a GitHub import.

  Reads from the `:plugin_verification` application config or `opts[:verification_config]`.
  """
  @spec enforce_verification_policy(%{verification: map()}, keyword()) ::
          :ok | {:error, atom()}
  def enforce_verification_policy(%{verification: verification}, opts \\ []) do
    policy = verification_policy(opts)
    signer = fetch_signer(verification)

    cond do
      not policy.require_gpg_for_github -> :ok
      Map.get(verification, "verified") != true -> {:error, :verification_required}
      policy.trusted_github_signers == [] -> {:error, :trusted_signers_not_configured}
      signer in policy.trusted_github_signers -> :ok
      true -> {:error, :untrusted_signer}
    end
  end

  @doc "Extracts GPG verification metadata from a resolved commit for storage."
  @spec verification_metadata(%{verification: map(), sha: String.t()}, String.t()) ::
          {map(), DateTime.t() | nil, String.t() | nil, String.t()}
  def verification_metadata(%{verification: verification, sha: sha}, ref) do
    verified = Map.get(verification, "verified") == true
    reason = Map.get(verification, "reason")
    signer = fetch_signer(verification)
    source_commit = sha || ref

    signature =
      drop_blank_values(%{
        "source" => "github",
        "verified" => verified,
        "reason" => reason,
        "signer" => signer,
        "commit" => source_commit
      })

    gpg_verified_at = if verified, do: DateTime.utc_now()
    gpg_key_id = if verified, do: signer

    {signature, gpg_verified_at, gpg_key_id, source_commit}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp fetch_default_branch(%{owner: owner, repo: repo}, opts) do
    url = "https://#{@github_api_host}/repos/#{owner}/#{repo}"

    with {:ok, body} <- github_api_get(url, opts),
         branch when is_binary(branch) <- Map.get(body, "default_branch"),
         true <- branch != "" do
      {:ok, branch}
    else
      _ -> {:error, :default_branch_not_found}
    end
  end

  defp fetch_commit_verification(%{owner: owner, repo: repo}, ref, opts) do
    with {:ok, normalized} <- normalize_ref(ref) do
      url =
        "https://#{@github_api_host}/repos/#{owner}/#{repo}/commits/#{URI.encode_www_form(normalized)}"

      case github_api_get(url, opts) do
        {:ok, body} ->
          sha = Map.get(body, "sha")

          if valid_commit_sha?(sha) do
            {:ok, %{sha: sha, verification: verification_from_body(body)}}
          else
            {:error, :invalid_ref}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp verification_from_body(body) when is_map(body) do
    case get_in(body, ["commit", "verification"]) do
      %{} = verification -> verification
      _ -> Map.get(body, "verification") || %{}
    end
  end

  defp fetch_signer(verification) when is_map(verification) do
    signer = Map.get(verification, "signer") || %{}

    cond do
      is_binary(Map.get(signer, "login")) -> Map.get(signer, "login")
      is_binary(Map.get(signer, "name")) -> Map.get(signer, "name")
      true -> nil
    end
  end

  defp verification_policy(opts) do
    config =
      Keyword.get(opts, :verification_config) ||
        Application.get_env(:serviceradar_web_ng, :plugin_verification, [])

    %{
      require_gpg_for_github: Keyword.get(config, :require_gpg_for_github, false),
      trusted_github_signers:
        config
        |> Keyword.get(:trusted_github_signers, [])
        |> Enum.map(&normalize_signer/1)
        |> Enum.reject(&is_nil/1),
      trusted_github_owners:
        config
        |> Keyword.get(:trusted_github_owners, [])
        |> Enum.map(&normalize_signer/1)
        |> Enum.reject(&is_nil/1),
      trusted_github_repositories:
        config
        |> Keyword.get(:trusted_github_repositories, [])
        |> Enum.map(&normalize_repository/1)
        |> Enum.reject(&is_nil/1)
    }
  end

  defp normalize_signer(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      s -> String.downcase(s)
    end
  end

  defp normalize_signer(_), do: nil

  defp normalize_repository(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      r -> r
    end
  end

  defp normalize_repository(_), do: nil

  defp configured_github_token do
    Application.get_env(:serviceradar_web_ng, :github_token) || System.get_env("GITHUB_TOKEN")
  end

  defp not_found_reason(_repo, opts, fallback) do
    token = opts[:github_token] || configured_github_token()

    if token do
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

  defp credential_reason(_repo, opts, status) do
    token = opts[:github_token] || configured_github_token()

    if token do
      "Plugin repository rejected the configured access token (HTTP #{status}); " <>
        "the token may be expired or missing repository read access."
    else
      "Plugin repository requires authentication (HTTP #{status}); attach a GitHub access token."
    end
  end

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 50)
  defp normalize_limit(_), do: 10

  defp build_headers(opts, extra) do
    token = opts[:github_token] || configured_github_token()
    base = [{"user-agent", "serviceradar"} | extra]

    case token do
      nil -> base
      "" -> base
      t -> [{"authorization", "Bearer #{t}"} | base]
    end
  end

  defp encode_path(path) do
    path |> String.split("/", trim: true) |> Enum.map_join("/", &URI.encode_www_form/1)
  end

  defp valid_commit_sha?(value) when is_binary(value) do
    Regex.match?(~r/\A[0-9a-f]{40}\z/i, value)
  end

  defp valid_commit_sha?(_), do: false

  defp drop_blank_values(map) when is_map(map) do
    map
    |> Enum.reject(fn {_, v} -> is_nil(v) or (is_binary(v) and String.trim(v) == "") end)
    |> Map.new()
  end

  defp do_fetch_body(url, headers, opts) do
    client = Keyword.get(opts, :http_client, EgressClient)
    client.fetch_body(url, headers: headers)
  end
end
