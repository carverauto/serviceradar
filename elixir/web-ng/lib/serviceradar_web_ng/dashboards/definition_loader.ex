defmodule ServiceRadarWebNG.Dashboards.DefinitionLoader do
  @moduledoc """
  Loads declarative dashboard definitions that ship with the product.

  Definitions live in `priv/dashboards/*.json`, listed by
  `priv/dashboards/index.json` (see `ServiceRadarWebNG.Dashboards.ReportIndex`),
  and are read at runtime, not
  embedded at compile time, so a shipped dashboard can be inspected or corrected in
  a release without a rebuild. `priv/**` is already a declared Bazel input and Mix
  releases carry `priv`, so nothing extra is needed to make them present.

  A malformed definition is a loud failure, not a skipped file. Returning the
  errors rather than filtering them out is deliberate: a definition that silently
  fails to load is indistinguishable from one that was never shipped, and the
  symptom -- a dashboard missing from the library -- gives no hint where to look.
  """

  alias ServiceRadarWebNG.Dashboards.Definition
  alias ServiceRadarWebNG.Dashboards.ReportIndex

  require Logger

  @definition_dir "dashboards"

  @doc "Directory holding the shipped definitions."
  @spec definition_dir() :: String.t()
  def definition_dir do
    :serviceradar_web_ng
    |> :code.priv_dir()
    |> Path.join(@definition_dir)
  end

  @doc """
  Loads and validates every definition the directory's `index.json` lists.

  Each returned definition carries the index's `enabled_by_default`, its
  `source_path` relative to the index, and the `content_hash` of its bytes.

  Returns the valid definitions and the errors separately so a caller can create
  what loaded while still surfacing what did not. A `.json` file the index does
  not list is an error, not an omission: it would otherwise ship and never be
  created, which is the silent-skip failure this loader exists to prevent.
  """
  @spec load_all(String.t() | nil) :: %{definitions: [map()], errors: [String.t()]}
  def load_all(dir \\ nil) do
    dir = dir || definition_dir()

    case File.ls(dir) do
      {:ok, entries} ->
        files = entries |> Enum.filter(&String.ends_with?(&1, ".json")) |> Enum.sort()
        load_indexed(dir, files)

      {:error, :enoent} ->
        # No directory is a legitimate state for a build that ships none.
        %{definitions: [], errors: []}

      {:error, reason} ->
        %{definitions: [], errors: ["#{dir}: cannot list definitions (#{inspect(reason)})"]}
    end
  end

  @doc "Loads and validates a single definition file, recording its content hash."
  @spec load_one(String.t()) :: {:ok, map()} | {:error, String.t()}
  def load_one(path) do
    source = Path.basename(path)

    with {:ok, body} <- read_file(path, source),
         {:ok, decoded} <- decode(body, source),
         {:ok, definition} <- Definition.validate(decoded, source) do
      {:ok, Map.put(definition, :content_hash, sha256(body))}
    end
  end

  @doc "Lowercase hex SHA256 of a definition's bytes."
  @spec sha256(binary()) :: String.t()
  def sha256(body), do: :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)

  defp load_indexed(_dir, []), do: %{definitions: [], errors: []}

  defp load_indexed(dir, files) do
    index_name = ReportIndex.file_name()

    with {:ok, body} <- read_file(Path.join(dir, index_name), index_name),
         {:ok, entries} <- ReportIndex.decode(body, index_name) do
      listed = MapSet.new(entries, & &1.path)

      unlisted =
        files
        |> Enum.reject(&(&1 == index_name or MapSet.member?(listed, &1)))
        |> Enum.map(&{:error, "#{&1}: not listed in #{index_name}, so it would never be created"})

      entries
      |> Enum.map(&load_entry(dir, &1))
      |> Kernel.++(unlisted)
      |> split_results()
    else
      {:error, reason} -> %{definitions: [], errors: [reason]}
    end
  end

  defp load_entry(dir, entry) do
    case load_one(Path.join(dir, entry.path)) do
      {:ok, %{slug: slug} = definition} when slug == entry.slug ->
        {:ok, Map.merge(definition, %{enabled_by_default: entry.enabled_by_default, source_path: entry.path})}

      {:ok, %{slug: slug}} ->
        {:error, "#{entry.path}: slug #{inspect(slug)} does not match its index entry #{inspect(entry.slug)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_file(path, source) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, "#{source}: cannot read (#{inspect(reason)})"}
    end
  end

  defp decode(body, source) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, %Jason.DecodeError{} = err} ->
        {:error, "#{source}: invalid JSON (#{Exception.message(err)})"}
    end
  end

  defp split_results(results) do
    {oks, errors} =
      Enum.split_with(results, fn
        {:ok, _} -> true
        {:error, _} -> false
      end)

    %{
      definitions: Enum.map(oks, fn {:ok, definition} -> definition end),
      errors: Enum.map(errors, fn {:error, reason} -> reason end)
    }
  end
end
