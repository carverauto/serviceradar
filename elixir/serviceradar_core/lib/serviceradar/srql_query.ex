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

  defp normalize_target_name(target) when is_atom(target), do: Atom.to_string(target)
  defp normalize_target_name(target) when is_binary(target), do: target
end
