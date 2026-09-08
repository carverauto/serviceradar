defmodule ServiceRadar.Plugins.IdentityUtils do
  @moduledoc false

  @spec item_identity(map()) :: String.t()
  def item_identity(item) when is_map(item) do
    cond do
      is_binary(item["uid"]) and item["uid"] != "" -> "uid:" <> item["uid"]
      is_binary(item["id"]) and item["id"] != "" -> "id:" <> item["id"]
      true -> Jason.encode!(item)
    end
  end

  @spec chunk_hash([term()], (term() -> term())) :: String.t()
  def chunk_hash(items, sort_key_fun) when is_list(items) and is_function(sort_key_fun, 1) do
    hash =
      items
      |> Enum.sort_by(sort_key_fun)
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))

    Base.encode16(hash, case: :lower)
  end
end
