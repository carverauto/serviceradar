defmodule ServiceRadar.Identity.Homepage do
  @moduledoc """
  Decides which saved homepage wins after sign-in.

  The user's own choice wins. Otherwise the homepage of the group they joined
  most recently wins. Membership `inserted_at` is that assignment time: an
  identity-provider refresh of a membership that already exists does not move
  it, and two groups assigned at the same time use the group name in ascending
  order. A missing or unauthorized choice falls through. The platform home is
  last.

  Kinds are an allowlist. `platform` and `dashboards` store no target. `authored`
  and `package` store a dashboard id or package route slug, never a URL.
  """

  @kinds [:platform, :dashboards, :authored, :package]
  @open_kinds [:platform, :dashboards]
  @targeted_kinds [:authored, :package]
  @target_pattern ~r/^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$/

  @type choice :: %{
          kind: :platform | :dashboards | :authored | :package,
          target: String.t() | nil
        }

  @doc """
  Returns the SQL boolean expression for the homepage columns.

  The migration and the Ash check constraint both use this so they cannot drift.
  """
  @spec preference_check_sql() :: String.t()
  def preference_check_sql do
    """
    (homepage_kind IS NULL AND homepage_target IS NULL)
    OR (homepage_kind IN ('platform', 'dashboards') AND homepage_target IS NULL)
    OR (
      homepage_kind IN ('authored', 'package')
      AND homepage_target ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$'
    )
    """
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  @spec resolve(map(), [map()], (choice() -> boolean())) ::
          {:ok, choice()} | {:fallback, choice(), :unavailable}
  def resolve(user, groups, authorized? \\ fn _choice -> true end)
      when is_map(user) and is_list(groups) and is_function(authorized?, 1) do
    candidates = [user_candidate(user) | ordered_group_candidates(groups)]
    pick(Enum.reject(candidates, &is_nil/1), authorized?, _skipped? = false)
  end

  @spec valid_preference?(term(), term()) :: boolean()
  def valid_preference?(kind, target) do
    kind = normalize_kind(kind)
    target = normalize_target(target)

    cond do
      kind == :unset and target == nil -> true
      kind in @open_kinds and target == nil -> true
      kind in @targeted_kinds and valid_target?(target) -> true
      true -> false
    end
  end

  @spec valid_target?(term()) :: boolean()
  def valid_target?(target) when is_binary(target), do: target =~ @target_pattern
  def valid_target?(_target), do: false

  defp ordered_group_candidates(groups) do
    groups
    |> Enum.map(&group_candidate/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn candidate -> {recency(candidate.assigned_at), candidate.name} end)
  end

  defp user_candidate(user) do
    case normalize_kind(fetch(user, :homepage_kind)) do
      :unset -> nil
      :invalid -> %{kind: :invalid, target: nil}
      kind -> %{kind: kind, target: normalize_target(fetch(user, :homepage_target))}
    end
  end

  defp group_candidate(group) do
    case normalize_kind(fetch(group, :homepage_kind)) do
      :unset ->
        nil

      kind ->
        %{
          kind: kind,
          target: normalize_target(fetch(group, :homepage_target)),
          assigned_at: fetch(group, :assigned_at),
          name: group_name(fetch(group, :name))
        }
    end
  end

  defp pick([], _authorized?, true), do: {:fallback, platform(), :unavailable}
  defp pick([], _authorized?, false), do: {:ok, platform()}

  defp pick([candidate | rest], authorized?, skipped?) do
    choice = %{kind: candidate.kind, target: candidate.target}

    if acceptable?(choice, authorized?) do
      if skipped?, do: {:fallback, choice, :unavailable}, else: {:ok, choice}
    else
      pick(rest, authorized?, true)
    end
  end

  defp acceptable?(%{kind: kind, target: nil}, _authorized?) when kind in @open_kinds, do: true

  defp acceptable?(%{kind: kind, target: target}, authorized?) when kind in @targeted_kinds do
    valid_target?(target) and authorized?.(%{kind: kind, target: target}) == true
  end

  defp acceptable?(_choice, _authorized?), do: false

  defp platform, do: %{kind: :platform, target: nil}

  defp normalize_kind(nil), do: :unset
  defp normalize_kind(""), do: :unset
  defp normalize_kind(kind) when kind in @kinds, do: kind

  defp normalize_kind(kind) when is_binary(kind) do
    case kind do
      "platform" -> :platform
      "dashboards" -> :dashboards
      "authored" -> :authored
      "package" -> :package
      _ -> :invalid
    end
  end

  defp normalize_kind(_kind), do: :invalid

  defp normalize_target(nil), do: nil

  defp normalize_target(target) when is_binary(target) do
    case String.trim(target) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_target(_target), do: nil

  defp recency(%DateTime{} = at), do: -DateTime.to_unix(at, :microsecond)

  defp recency(%NaiveDateTime{} = at) do
    at |> DateTime.from_naive!("Etc/UTC") |> recency()
  end

  defp recency(_at), do: 0

  defp group_name(name) when is_binary(name), do: name
  defp group_name(_name), do: ""

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp fetch(_map, _key), do: nil
end
