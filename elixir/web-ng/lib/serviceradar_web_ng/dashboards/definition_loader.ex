defmodule ServiceRadarWebNG.Dashboards.DefinitionLoader do
  @moduledoc """
  Loads declarative dashboard definitions that ship with the product.

  Definitions live in `priv/dashboards/*.json` and are read at runtime, not
  embedded at compile time, so a shipped dashboard can be inspected or corrected in
  a release without a rebuild. `priv/**` is already a declared Bazel input and Mix
  releases carry `priv`, so nothing extra is needed to make them present.

  A malformed definition is a loud failure, not a skipped file. Returning the
  errors rather than filtering them out is deliberate: a definition that silently
  fails to load is indistinguishable from one that was never shipped, and the
  symptom -- a dashboard missing from the library -- gives no hint where to look.
  """

  alias ServiceRadarWebNG.Dashboards.Definition

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
  Loads and validates every shipped definition.

  Returns the valid definitions and the errors separately so a caller can create
  what loaded while still surfacing what did not.
  """
  @spec load_all(String.t() | nil) :: %{definitions: [Definition.t()], errors: [String.t()]}
  def load_all(dir \\ nil) do
    dir = dir || definition_dir()

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.sort()
        |> Enum.map(&load_one(Path.join(dir, &1)))
        |> split_results()

      {:error, :enoent} ->
        # No directory is a legitimate state for a build that ships none.
        %{definitions: [], errors: []}

      {:error, reason} ->
        %{definitions: [], errors: ["#{dir}: cannot list definitions (#{inspect(reason)})"]}
    end
  end

  @doc "Loads and validates a single definition file."
  @spec load_one(String.t()) :: {:ok, Definition.t()} | {:error, String.t()}
  def load_one(path) do
    source = Path.basename(path)

    with {:ok, body} <- read_file(path, source),
         {:ok, decoded} <- decode(body, source) do
      Definition.validate(decoded, source)
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
