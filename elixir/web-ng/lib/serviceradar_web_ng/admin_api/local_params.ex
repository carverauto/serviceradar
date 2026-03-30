defmodule ServiceRadarWebNG.AdminApi.LocalParams do
  @moduledoc false

  @default_list_limit 100
  @max_list_limit 1_000

  def normalize_limit(value) do
    value
    |> parse_int()
    |> case do
      int when is_integer(int) and int > 0 -> min(int, @max_list_limit)
      _ -> @default_list_limit
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_int(_), do: nil
end
