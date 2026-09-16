defmodule ServiceRadarWebNG.Shell do
  @moduledoc """
  Shell escaping helpers for generated operator-facing commands and scripts.
  """

  @spec literal(String.t() | atom() | integer()) :: String.t()
  def literal(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  def literal(value) when is_atom(value), do: value |> Atom.to_string() |> literal()
  def literal(value) when is_integer(value), do: value |> Integer.to_string() |> literal()

  @doc """
  Quotes a value as a PowerShell single-quoted string: nothing inside it is
  expanded, and an embedded single quote is doubled.
  """
  @spec powershell_literal(String.t()) :: String.t()
  def powershell_literal(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "''") <> "'"
  end
end
