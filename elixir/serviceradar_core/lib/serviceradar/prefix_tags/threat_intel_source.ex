defmodule ServiceRadar.PrefixTags.ThreatIntelSource do
  @moduledoc """
  Materializes active threat-intel CIDR indicators into the `ti` prefix-tag trie.

  Reads from `platform.threat_intel_indicators` (populated by OTX/feed workers).
  Only non-expired indicators are included. Tags are advisory point-in-time
  evidence (`ti:<source>`); authoritative matching stays on the threat-intel
  match pipeline.

  Does **not** retro-tag historical flows — only subsequent enrichment lookups
  see the refreshed trie.
  """

  alias Ecto.Adapters.SQL
  alias ServiceRadar.PrefixTags.Loader
  alias ServiceRadar.PrefixTags.Store
  alias ServiceRadar.Repo

  require Logger

  @source "ti"
  @max_tags_per_prefix 8

  @load_active_sql """
  SELECT
    host(indicator) || '/' || masklen(indicator) AS prefix,
    source,
    label
  FROM platform.threat_intel_indicators
  WHERE (expires_at IS NULL OR expires_at > now())
  """

  @doc "Canonical Store source name."
  @spec source_name() :: String.t()
  def source_name, do: @source

  @doc """
  Load active indicators into the `ti` trie.

  Options:
  - `:broadcast?` (default `true`) — notify peer nodes. Loaders that invoke
    this on invalidation must pass `broadcast?: false` to avoid a PubSub loop.
  """
  @spec reload(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def reload(opts \\ []) do
    broadcast? = Keyword.get(opts, :broadcast?, true)

    case fetch_rows() do
      {:ok, rows} ->
        if rows == [] do
          Store.clear(@source)
        else
          _ = Store.put_rows(@source, rows)
        end

        if broadcast?, do: Loader.broadcast_invalidation(%{source: @source})
        Logger.info("PrefixTags.ThreatIntelSource loaded ti trie", rows: length(rows))
        {:ok, length(rows)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def map_indicator_row(prefix, source, label) when is_binary(prefix) do
    source_slug = slugify(source || "unknown")
    tags = ["ti:#{source_slug}"]

    tags =
      if is_binary(label) and String.trim(label) != "" do
        (tags ++ ["ti:label:#{slugify(label)}"]) |> Enum.uniq() |> Enum.take(@max_tags_per_prefix)
      else
        tags
      end

    %{
      prefix: prefix,
      tags: tags,
      source: @source
    }
  end

  defp fetch_rows do
    case SQL.query(Repo, @load_active_sql, []) do
      {:ok, %{rows: rows}} ->
        parsed =
          rows
          |> Enum.map(fn
            [prefix, source, label] when is_binary(prefix) ->
              map_indicator_row(prefix, source, label)

            _ ->
              nil
          end)
          |> Enum.reject(&is_nil/1)
          # Collapse duplicate prefixes: merge tags
          |> Enum.group_by(& &1.prefix)
          |> Enum.map(fn {prefix, group} ->
            tags =
              group
              |> Enum.flat_map(& &1.tags)
              |> Enum.uniq()
              |> Enum.take(@max_tags_per_prefix)

            %{prefix: prefix, tags: tags, source: @source}
          end)

        {:ok, parsed}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp slugify(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "unknown"
      s -> s
    end
  end
end
