defmodule ServiceRadar.Plugins.RepoUrl do
  @moduledoc """
  Canonical parser for a plugin catalog repository URL.

  This lives in core rather than in web-ng's `FirstPartyReleaseClient` because
  `PluginRepository` has to validate the same URLs the importer will later
  resolve, and core cannot depend on web-ng. Two parsers would be two chances to
  disagree about what a valid source is -- and disagreeing in the permissive
  direction means a row that saves cleanly and then fails every import.

  The importer's richer struct (api_base_url and friends) is built on top of
  this; see `ServiceRadarWebNG.Plugins.FirstPartyReleaseClient.parse_repo_url/1`.
  """

  @github_host "github.com"

  @type parsed :: %{
          provider: String.t(),
          repo_url: String.t(),
          host: String.t(),
          owner: String.t(),
          repo: String.t()
        }

  @doc "The trusted GitHub web host."
  @spec github_host() :: String.t()
  def github_host, do: @github_host

  @doc """
  Parses `https://github.com/<owner>/<repo>` into its parts.

  Returns the normalized URL with any `.git` suffix and trailing path removed,
  so two spellings of the same repository cannot both be stored (the table has a
  unique index on `repo_url`, which only helps if the value is normalized first).
  """
  @spec parse(term()) :: {:ok, parsed()} | {:error, atom()}
  def parse(url) when is_binary(url) do
    with %URI{scheme: "https", host: @github_host} = uri <- URI.parse(String.trim(url)),
         {:ok, owner, repo} <- owner_and_repo(uri.path) do
      {:ok,
       %{
         provider: "github",
         repo_url: "https://#{host_port(uri)}/#{owner}/#{repo}",
         host: @github_host,
         owner: owner,
         repo: repo
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_repo_url}
    end
  end

  def parse(_url), do: {:error, :invalid_repo_url}

  @doc "Normalized URL, or the original value when it does not parse."
  @spec normalize(term()) :: term()
  def normalize(url) do
    case parse(url) do
      {:ok, %{repo_url: repo_url}} -> repo_url
      {:error, _reason} -> url
    end
  end

  @doc "Human-readable reason for a parse failure."
  @spec describe_error(atom()) :: String.t()
  def describe_error(:invalid_repo_path),
    do: "must include an owner and a repository, like https://github.com/owner/repo"

  def describe_error(_reason),
    do: "must be a GitHub repository URL like https://github.com/owner/repo"

  defp owner_and_repo(path) when is_binary(path) do
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

  defp owner_and_repo(_path), do: {:error, :invalid_repo_path}

  defp host_port(%URI{host: host, port: port}) when port in [nil, 443], do: host
  defp host_port(%URI{host: host, port: port}), do: "#{host}:#{port}"
end
