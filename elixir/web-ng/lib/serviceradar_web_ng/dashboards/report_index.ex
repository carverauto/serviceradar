defmodule ServiceRadarWebNG.Dashboards.ReportIndex do
  @moduledoc """
  Parses the index listing the report definitions a release ships.

  The same file is read two ways: from this build's `priv/dashboards/index.json`
  when the service creates its enabled-by-default reports at startup, and from
  the OSS repository at a release tag when an operator imports first-party
  reports. Both go through `parse/2`, so a release cannot publish an index this
  build would read differently from its own.

  ## Shape

      {
        "version": 1,
        "reports": [
          {"slug": "new-devices", "path": "new-devices.json", "enabled_by_default": true}
        ]
      }

  `path` is relative to the index's own directory. `enabled_by_default` is
  required rather than defaulted: whether a report appears unasked on every
  installation is a decision the index states, not one a missing key makes.
  """

  alias ServiceRadarWebNG.Dashboards.Definition
  alias ServiceRadarWebNG.Packages.RepoClient

  @file_name "index.json"
  @repo_dir "elixir/web-ng/priv/dashboards"
  @supported_versions [1]

  @type entry :: %{slug: String.t(), path: String.t(), enabled_by_default: boolean()}

  @doc "File name of the index inside a definition directory."
  @spec file_name() :: String.t()
  def file_name, do: @file_name

  @doc "Directory holding the definitions, relative to the OSS repository root."
  @spec repo_dir() :: String.t()
  def repo_dir, do: @repo_dir

  @doc "Repository-relative path of a definition listed in the index."
  @spec repo_path(String.t()) :: String.t()
  def repo_path(path), do: Path.join(@repo_dir, path)

  @doc """
  The release tag of the running build, or nil when it is not known.

  Helm sets `SERVICERADAR_RELEASE_VERSION` to the published `v<semver>` tag.
  """
  @spec running_release_tag() :: String.t() | nil
  def running_release_tag do
    case System.get_env("SERVICERADAR_RELEASE_VERSION") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          tag -> tag
        end

      _ ->
        nil
    end
  end

  @doc "Decodes and parses an index body. `source` names it in errors."
  @spec decode(binary(), String.t()) :: {:ok, [entry()]} | {:error, String.t()}
  def decode(body, source) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        parse(decoded, source)

      {:error, %Jason.DecodeError{} = err} ->
        {:error, "#{source}: invalid JSON (#{Exception.message(err)})"}
    end
  end

  @doc "Parses a decoded index map into its entries."
  @spec parse(term(), String.t()) :: {:ok, [entry()]} | {:error, String.t()}
  def parse(%{"version" => version} = raw, source) when is_integer(version) do
    if version in @supported_versions do
      parse_reports(Map.get(raw, "reports"), source)
    else
      {:error,
       "#{source}: unsupported index version #{version}; " <>
         "this build understands #{inspect(@supported_versions)}"}
    end
  end

  def parse(raw, source) when is_map(raw), do: {:error, "#{source}: missing required integer \"version\""}
  def parse(_raw, source), do: {:error, "#{source}: index must be a JSON object"}

  defp parse_reports(reports, source) when is_list(reports) do
    reports
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
      case parse_entry(entry, "#{source} report #{index}") do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} ->
        entries = Enum.reverse(entries)

        with :ok <- refute_duplicates(entries, :slug, source),
             :ok <- refute_duplicates(entries, :path, source) do
          {:ok, entries}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_reports(_reports, source), do: {:error, "#{source}: \"reports\" must be an array"}

  defp parse_entry(%{} = entry, where) do
    with {:ok, slug} <- entry_slug(entry, where),
         {:ok, path} <- entry_path(entry, where),
         {:ok, enabled} <- entry_enabled(entry, where) do
      {:ok, %{slug: slug, path: path, enabled_by_default: enabled}}
    end
  end

  defp parse_entry(_entry, where), do: {:error, "#{where}: must be a JSON object"}

  defp entry_slug(entry, where) do
    slug = Map.get(entry, "slug")

    if Definition.valid_slug?(slug) do
      {:ok, slug}
    else
      {:error, "#{where}: slug #{inspect(slug)} is not a valid dashboard slug"}
    end
  end

  # The path is joined onto a local directory and onto a repository URL, so it is
  # held to the repository path rules: relative, no traversal, no odd characters.
  defp entry_path(entry, where) do
    with path when is_binary(path) <- Map.get(entry, "path"),
         {:ok, normalized} <- RepoClient.normalize_repo_path(path, :invalid_path),
         true <- String.ends_with?(normalized, ".json") and normalized != @file_name do
      {:ok, normalized}
    else
      _ ->
        {:error,
         "#{where}: path #{inspect(Map.get(entry, "path"))} must be a relative .json file inside the index directory"}
    end
  end

  defp entry_enabled(entry, where) do
    case Map.get(entry, "enabled_by_default") do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, "#{where}: missing required boolean \"enabled_by_default\""}
    end
  end

  defp refute_duplicates(entries, key, source) do
    entries
    |> Enum.frequencies_by(&Map.fetch!(&1, key))
    |> Enum.find(fn {_value, count} -> count > 1 end)
    |> case do
      nil -> :ok
      {value, _count} -> {:error, "#{source}: #{key} #{inspect(value)} is listed more than once"}
    end
  end
end
