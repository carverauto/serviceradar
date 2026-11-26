defmodule ServiceRadar.SRQLQuery do
  @moduledoc false

  @spec ensure_target(String.t(), String.t() | atom()) :: String.t()
  def ensure_target(query, default_target) when is_binary(query) do
    default_target = normalize_target_name(default_target)
    trimmed = String.trim(query)

    cond do
      trimmed == "" ->
        "in:#{default_target}"

      String.starts_with?(trimmed, "in:") ->
        trimmed

      true ->
        "in:#{default_target} " <> trimmed
    end
  end

  @doc """
  Orders a whole-selection walk by `uid` so SRQL pages it with keyset cursors.

  A device or agent query whose effective order is `uid` alone is read one
  index range scan per page, with no OFFSET and no cursor ceiling. The key is
  appended, so an operator-supplied sort stays the primary order (and that
  query keeps offset paging). Other entities are returned unchanged.
  """
  @spec page_by_uid(String.t()) :: String.t()
  def page_by_uid(query) when is_binary(query) do
    case Regex.run(~r/^\s*in:(\S+)/, query) do
      [_, entity] when entity in ["devices", "agents"] ->
        String.trim_trailing(query) <> " sort:uid:asc"

      _ ->
        query
    end
  end

  defp normalize_target_name(target) when is_atom(target), do: Atom.to_string(target)
  defp normalize_target_name(target) when is_binary(target), do: target
end
