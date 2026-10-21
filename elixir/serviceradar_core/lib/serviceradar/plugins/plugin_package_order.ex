defmodule ServiceRadar.Plugins.PluginPackageOrder do
  @moduledoc """
  Orders versions of one plugin: semantic version first, then import, approval
  and insertion time.

  "The latest approved package" of a plugin means the greatest package under
  this order, wherever it is resolved, so every caller shares it.
  """

  alias ServiceRadar.Plugins.ValueUtils

  @doc "The greatest package under this order, or `nil` for an empty list."
  @spec latest([map()]) :: map() | nil
  def latest([]), do: nil
  def latest(packages) when is_list(packages), do: Enum.max_by(packages, &sort_key/1)

  defp sort_key(package) do
    {
      semver_sort_key(ValueUtils.string_value(package, [:version, "version"])),
      timestamp_sort_key(ValueUtils.raw_value(package, [:imported_at, "imported_at"])),
      timestamp_sort_key(ValueUtils.raw_value(package, [:approved_at, "approved_at"])),
      timestamp_sort_key(ValueUtils.raw_value(package, [:inserted_at, "inserted_at"]))
    }
  end

  defp semver_sort_key(version) when is_binary(version) do
    case Regex.run(~r/^v?(\d+)\.(\d+)\.(\d+)/, version) do
      [_match, major, minor, patch] ->
        {String.to_integer(major), String.to_integer(minor), String.to_integer(patch), version}

      _ ->
        {-1, -1, -1, version}
    end
  end

  defp semver_sort_key(_version), do: {-1, -1, -1, ""}

  defp timestamp_sort_key(%DateTime{} = timestamp), do: DateTime.to_unix(timestamp, :microsecond)

  defp timestamp_sort_key(%NaiveDateTime{} = timestamp),
    do: NaiveDateTime.to_gregorian_seconds(timestamp)

  defp timestamp_sort_key(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> timestamp_sort_key(datetime)
      _ -> 0
    end
  end

  defp timestamp_sort_key(_timestamp), do: 0
end
