defmodule ServiceRadar.PrefixTags.Slug do
  @moduledoc """
  Shared slug normalizer for prefix-tag namespaces (NetBox, TI, DNS-policy).
  """

  @doc """
  Lowercase, non-alphanumeric → `-`, trim edges.

  Options:
  - `:empty` — value when the result would be empty (default `nil`)
  """
  @spec slugify(term(), keyword()) :: String.t() | nil
  def slugify(value, opts \\ [])

  def slugify(value, opts) when is_binary(value) do
    empty = Keyword.get(opts, :empty, nil)

    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> empty
      s -> s
    end
  end

  def slugify(_, opts), do: Keyword.get(opts, :empty, nil)
end
