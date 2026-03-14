defmodule ServiceRadar.SRQLAst do
  @moduledoc false

  @spec parse(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def parse(query, opts \\ []) when is_binary(query) do
    with {:ok, ast_json} <- parse_fn(opts).(query),
         {:ok, ast} <- Jason.decode(ast_json) do
      {:ok, ast}
    else
      {:error, %Jason.DecodeError{} = reason} -> {:error, {:json_decode_error, reason}}
      {:error, reason} -> {:error, {:parse_error, reason}}
    end
  end

  @spec validate(String.t(), keyword()) :: :ok | {:error, term()}
  def validate(query, opts \\ []) when is_binary(query) do
    case parse_fn(opts).(query) do
      {:ok, _ast_json} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  @spec entity(String.t(), String.t()) :: String.t()
  def entity(query, default \\ "devices") when is_binary(query) and is_binary(default) do
    case Regex.run(~r/^in:(\S+)/, query) do
      [_, entity] -> String.downcase(entity)
      _ -> default
    end
  end

  defp parse_fn(opts), do: Keyword.get(opts, :parse_fn, &ServiceRadarSRQL.Native.parse_ast/1)
end
