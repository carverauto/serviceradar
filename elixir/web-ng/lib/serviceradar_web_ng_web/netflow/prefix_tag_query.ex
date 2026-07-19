defmodule ServiceRadarWebNGWeb.Netflow.PrefixTagQuery do
  @moduledoc """
  Shared SRQL query mutations for prefix-tag filters on NetFlow surfaces.
  """

  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.Filters

  @doc """
  Set or clear the primary `tag:` filter and clear `src_tag` / `dst_tag`
  so the sidebar tag control does not fight side-specific filters.
  """
  @spec apply_tag_filter(String.t(), String.t()) :: String.t()
  def apply_tag_filter(query, tag) when is_binary(query) do
    tag = tag |> to_string() |> String.trim()

    query
    |> Filters.upsert_query_filter("tag", tag)
    |> Filters.upsert_query_filter("src_tag", "")
    |> Filters.upsert_query_filter("dst_tag", "")
  end

  def apply_tag_filter(_query, tag), do: apply_tag_filter("in:flows", tag)

  @doc "Extract the first `tag:` value from an SRQL query string (or nil)."
  @spec tag_from_query(String.t() | nil) :: String.t() | nil
  def tag_from_query(nil), do: nil
  def tag_from_query(""), do: nil

  def tag_from_query(query) when is_binary(query) do
    # Match tag:value without pulling src_tag/dst_tag (word boundary before tag:).
    case Regex.run(~r/(?:^|\s)tag:(?:"([^"]+)"|(\S+))/, query) do
      [_, quoted, ""] when quoted != "" -> quoted
      [_, "", bare] when bare != "" -> bare
      [_, quoted, bare] when quoted != "" -> quoted
      [_, quoted, bare] when bare != "" -> bare
      _ -> nil
    end
  end

  def tag_from_query(_), do: nil
end
