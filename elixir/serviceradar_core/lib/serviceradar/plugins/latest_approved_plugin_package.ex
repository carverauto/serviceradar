defmodule ServiceRadar.Plugins.LatestApprovedPluginPackage do
  @moduledoc """
  The one rule for "the latest approved package of a plugin".

  An owner that tracks the latest approved version (see
  `ServiceRadar.Plugins.PluginUpdatePolicy`), a credential rule materializing
  assignments, the integration catalog, and first-party auto-approval (which
  compares a new version's grant with this package's) all resolve a plugin to
  the same package:

  1. only approved packages with the same `plugin_id` are candidates (a revoked,
     denied or staged package is never approved);
  2. the highest semantic version wins, with a leading `v` ignored, a release
     ranked above its prereleases, and an unparseable version ranked below every
     valid one;
  3. ties fall to the most recent `approved_at`, then `imported_at`, then
     `inserted_at`, then the package id, so the choice is deterministic.

  Packages may be `PluginPackage` structs or plain maps with atom or string keys;
  a map without `version` falls back to its manifest's `"version"`.
  """

  alias ServiceRadar.Plugins.PluginPackage

  require Ash.Query

  @tiebreak_fields [:approved_at, :imported_at, :inserted_at]

  @doc """
  Reads the latest approved package for `plugin_id`.

  Requires the `:actor` option.
  """
  @spec resolve(String.t(), keyword()) ::
          {:ok, PluginPackage.t()}
          | {:error, {:plugin_package_not_found, String.t()}}
          | {:error, term()}
  def resolve(plugin_id, opts) do
    actor = Keyword.fetch!(opts, :actor)

    PluginPackage
    |> Ash.Query.for_read(:approved, %{}, actor: actor)
    |> Ash.Query.filter(plugin_id == ^plugin_id)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, [_ | _] = packages} -> {:ok, latest(packages)}
      {:ok, []} -> {:error, {:plugin_package_not_found, plugin_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The newest of `packages` by the rule in the module doc, or `nil` for an empty
  list.
  """
  @spec latest([map()]) :: map() | nil
  def latest([]), do: nil
  def latest(packages) when is_list(packages), do: packages |> newest_first() |> hd()

  @doc """
  Orders `packages` from newest to oldest by the rule in the module doc.
  """
  @spec newest_first([map()]) :: [map()]
  def newest_first(packages) when is_list(packages) do
    Enum.sort_by(packages, &sort_key/1, &newer_or_equal?/2)
  end

  defp sort_key(package) do
    {parse_version(version(package)), Enum.map(@tiebreak_fields, &timestamp(field(package, &1))),
     to_string(field(package, :id) || "")}
  end

  defp newer_or_equal?(
         {left_version, left_times, left_id},
         {right_version, right_times, right_id}
       ) do
    case compare_versions(left_version, right_version) do
      :gt -> true
      :lt -> false
      :eq -> {left_times, left_id} >= {right_times, right_id}
    end
  end

  defp version(package) do
    field(package, :version) || get_in(field(package, :manifest) || %{}, ["version"])
  end

  defp parse_version(version) when is_binary(version) do
    case version |> String.trim() |> String.trim_leading("v") |> Version.parse() do
      {:ok, parsed} -> {:valid, parsed}
      :error -> :invalid
    end
  end

  defp parse_version(_version), do: :invalid

  defp compare_versions({:valid, left}, {:valid, right}), do: Version.compare(left, right)
  defp compare_versions({:valid, _left}, :invalid), do: :gt
  defp compare_versions(:invalid, {:valid, _right}), do: :lt
  defp compare_versions(:invalid, :invalid), do: :eq

  defp timestamp(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)

  defp timestamp(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> timestamp()

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> timestamp(datetime)
      _ -> 0
    end
  end

  defp timestamp(_value), do: 0

  defp field(%{} = package, key),
    do: Map.get(package, key) || Map.get(package, Atom.to_string(key))
end
