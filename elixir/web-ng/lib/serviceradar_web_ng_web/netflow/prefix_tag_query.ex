defmodule ServiceRadarWebNGWeb.Netflow.PrefixTagQuery do
  @moduledoc """
  Shared SRQL query mutations for prefix-tag filters on NetFlow surfaces.
  """

  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.Filters

  @max_tag_bytes 128
  @tag_char_re ~r/^[A-Za-z0-9:._@+\-\/]+$/

  @doc """
  Validate a free-typed tag for SRQL splicing (charset + length).

  Returns `{:ok, tag}` or `{:error, reason}`.
  """
  @spec validate_tag(term()) :: {:ok, String.t()} | {:error, :empty | :too_long | :invalid_chars}
  def validate_tag(nil), do: {:error, :empty}

  def validate_tag(raw) do
    tag = raw |> to_string() |> String.trim()

    cond do
      tag == "" -> {:error, :empty}
      byte_size(tag) > @max_tag_bytes -> {:error, :too_long}
      not Regex.match?(@tag_char_re, tag) -> {:error, :invalid_chars}
      true -> {:ok, tag}
    end
  end

  @doc """
  Set or clear the primary `tag:` filter and clear `src_tag` / `dst_tag`
  so the sidebar tag control does not fight side-specific filters.

  Invalid tags are rejected (query unchanged) — callers should surface errors.
  Empty string clears the filter.
  """
  @spec apply_tag_filter(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :empty | :too_long | :invalid_chars}
  def apply_tag_filter(query, tag) when is_binary(query) do
    tag = tag |> to_string() |> String.trim()

    if tag == "" do
      next =
        query
        |> Filters.upsert_query_filter("tag", "")
        |> Filters.upsert_query_filter("src_tag", "")
        |> Filters.upsert_query_filter("dst_tag", "")

      {:ok, next}
    else
      with {:ok, tag} <- validate_tag(tag) do
        next =
          query
          |> Filters.upsert_query_filter("tag", quote_if_needed(tag))
          |> Filters.upsert_query_filter("src_tag", "")
          |> Filters.upsert_query_filter("dst_tag", "")

        {:ok, next}
      end
    end
  end

  def apply_tag_filter(_query, tag), do: apply_tag_filter("in:flows", tag)

  @doc "Extract the first `tag:` value from an SRQL query string (or nil)."
  @spec tag_from_query(String.t() | nil) :: String.t() | nil
  def tag_from_query(nil), do: nil
  def tag_from_query(""), do: nil

  def tag_from_query(query) when is_binary(query) do
    # Regex.run drops trailing unmatched groups, so handle 2- and 3-element lists.
    case Regex.run(~r/(?:^|\s)tag:(?:"([^"]+)"|(\S+))/, query) do
      [_, quoted] when quoted != "" -> quoted
      [_, quoted, ""] when quoted != "" -> quoted
      [_, "", bare] when bare != "" -> bare
      [_, quoted, _bare] when quoted != "" -> quoted
      [_, _quoted, bare] when bare != "" -> bare
      _ -> nil
    end
  end

  def tag_from_query(_), do: nil

  defp quote_if_needed(tag) do
    if String.contains?(tag, " "), do: "\"#{tag}\"", else: tag
  end
end
