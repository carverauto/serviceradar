defmodule ServiceRadar.Inventory.AdvisoryFeeds.VersionRange do
  @moduledoc """
  NVD CPE version-range evaluation.

  NVD `cpeMatch` entries carry up to four bounds:

    * `versionStartIncluding` (>=)
    * `versionStartExcluding`  (>)
    * `versionEndIncluding`    (<=)
    * `versionEndExcluding`    (<)

  This module normalizes those into discrete `version_start` /
  `version_start_inclusive` / `version_end` / `version_end_inclusive` columns and
  evaluates whether an installed version falls inside the window.

  Version comparison is a dotted-numeric comparison with a lexical fallback for
  pre-release / non-numeric tails (e.g. `1.2.0-rc1`). It is intentionally simple
  and dependency-free: real CPE/semver corner cases are out of scope for this
  slice, but the common `>= a < b` windows NVD emits are handled correctly.

  Pure module — no DB, no IO. Fully unit-testable.
  """

  @type bounds :: %{
          version_start: String.t() | nil,
          version_start_inclusive: boolean() | nil,
          version_end: String.t() | nil,
          version_end_inclusive: boolean() | nil
        }

  @doc """
  Normalize an NVD `cpeMatch`-shaped map into discrete bounds.

  Accepts string keys (raw NVD JSON) and is tolerant of a missing/`""` bound.
  """
  @spec from_cpe_match(map()) ::
          {:ok, bounds()}
          | {:error, :ambiguous_version_start | :ambiguous_version_end}
          | {:error, {:invalid_version_bound, String.t()}}
  def from_cpe_match(match) when is_map(match) do
    with :ok <- validate_bound_types(match),
         :ok <- validate_exclusive_bound_forms(match) do
      {start_value, start_inclusive} =
        cond do
          present?(match["versionStartIncluding"]) -> {match["versionStartIncluding"], true}
          present?(match["versionStartExcluding"]) -> {match["versionStartExcluding"], false}
          true -> {nil, nil}
        end

      {end_value, end_inclusive} =
        cond do
          present?(match["versionEndIncluding"]) -> {match["versionEndIncluding"], true}
          present?(match["versionEndExcluding"]) -> {match["versionEndExcluding"], false}
          true -> {nil, nil}
        end

      {:ok,
       %{
         version_start: normalize_bound(start_value),
         version_start_inclusive: start_inclusive,
         version_end: normalize_bound(end_value),
         version_end_inclusive: end_inclusive
       }}
    end
  end

  defp validate_bound_types(match) do
    Enum.find_value(
      ~w(versionStartIncluding versionStartExcluding versionEndIncluding versionEndExcluding),
      :ok,
      fn key ->
        case Map.fetch(match, key) do
          :error -> false
          {:ok, value} when is_binary(value) -> false
          {:ok, _value} -> {:error, {:invalid_version_bound, key}}
        end
      end
    )
  end

  defp validate_exclusive_bound_forms(match) do
    cond do
      Map.has_key?(match, "versionStartIncluding") and
          Map.has_key?(match, "versionStartExcluding") ->
        {:error, :ambiguous_version_start}

      Map.has_key?(match, "versionEndIncluding") and
          Map.has_key?(match, "versionEndExcluding") ->
        {:error, :ambiguous_version_end}

      true ->
        :ok
    end
  end

  @doc """
  Does `installed_version` fall within `bounds`?

  An unbounded side imposes no constraint. A `nil`/blank installed version cannot
  be evaluated against a bound, so it only matches a fully-unbounded window.
  """
  @spec satisfies?(String.t() | nil, bounds()) :: boolean()
  def satisfies?(installed_version, %{} = bounds) do
    start_v = bounds[:version_start]
    end_v = bounds[:version_end]

    cond do
      is_nil(start_v) and is_nil(end_v) ->
        true

      blank?(installed_version) ->
        # Cannot evaluate a bound without a version.
        false

      true ->
        lower_ok?(installed_version, start_v, bounds[:version_start_inclusive]) and
          upper_ok?(installed_version, end_v, bounds[:version_end_inclusive])
    end
  end

  @doc """
  Compare two version strings. Returns `:lt`, `:eq`, or `:gt`.

  Compares dotted segments numerically when both are integers, lexically
  otherwise. Missing trailing segments are treated as `0`.
  """
  @spec compare(String.t(), String.t()) :: :lt | :eq | :gt
  def compare(a, b) when is_binary(a) and is_binary(b) do
    do_compare(segments(a), segments(b))
  end

  defp lower_ok?(_installed, nil, _inclusive), do: true

  defp lower_ok?(installed, start_v, inclusive) do
    case compare(installed, start_v) do
      :gt -> true
      :eq -> inclusive == true
      :lt -> false
    end
  end

  defp upper_ok?(_installed, nil, _inclusive), do: true

  defp upper_ok?(installed, end_v, inclusive) do
    case compare(installed, end_v) do
      :lt -> true
      :eq -> inclusive == true
      :gt -> false
    end
  end

  defp do_compare([], []), do: :eq

  defp do_compare([a | rest_a], [b | rest_b]) do
    case compare_segment(a, b) do
      :eq -> do_compare(rest_a, rest_b)
      result -> result
    end
  end

  defp do_compare([a | rest_a], []) do
    case compare_segment(a, "0") do
      :eq -> do_compare(rest_a, [])
      result -> result
    end
  end

  defp do_compare([], [b | rest_b]) do
    case compare_segment("0", b) do
      :eq -> do_compare([], rest_b)
      result -> result
    end
  end

  defp compare_segment(a, b) do
    case {Integer.parse(a), Integer.parse(b)} do
      {{ia, ""}, {ib, ""}} ->
        cond_compare(ia, ib)

      _ ->
        cond_compare(a, b)
    end
  end

  defp cond_compare(a, b) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  # Split on ".", "-", "_", "+" into comparable segments.
  defp segments(version) do
    version
    |> String.trim()
    |> String.downcase()
    |> String.split(~r/[.\-_+]/, trim: true)
  end

  defp normalize_bound(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      "*" -> nil
      "-" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_bound(_), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) not in ["", "*", "-"]
  defp present?(_), do: false

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
