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
  alias ServiceRadar.PrefixTags.Slug
  alias ServiceRadar.PrefixTags.Store
  alias ServiceRadar.Repo

  require Logger

  @source "ti"
  @max_tags_per_prefix 8

  @load_active_sql """
  SELECT
    host(indicator) || '/' || masklen(indicator) AS prefix,
    source,
    label,
    severity
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
  def map_indicator_row(prefix, source, label, severity \\ nil)

  def map_indicator_row(prefix, source, label, severity) when is_binary(prefix) do
    source_slug = Slug.slugify(source || "unknown", empty: "unknown")
    tags = ["ti:#{source_slug}"]
    sev = normalize_severity(severity)

    tags =
      if is_binary(label) and String.trim(label) != "" do
        case Slug.slugify(label) do
          nil -> tags
          label_slug -> ["ti:label:#{label_slug}" | tags]
        end
      else
        tags
      end

    # Keep one advisory severity tag for SRQL; structured field is authoritative
    # for CTI matching (max_severity_from_match/1).
    tags =
      case sev do
        nil -> tags
        n -> ["ti:severity:#{n}" | tags]
      end

    %{
      prefix: prefix,
      tags: tags |> Enum.reverse() |> Enum.uniq() |> Enum.take(@max_tags_per_prefix),
      source: @source,
      severity: sev
    }
  end

  @doc """
  Highest severity from a Store match chain (prefers first-class `:severity`,
  falls back to `ti:severity:N` tags).
  """
  @spec max_severity_from_match([map()]) :: non_neg_integer()
  def max_severity_from_match(chain) when is_list(chain) do
    Enum.reduce(chain, 0, fn match, acc ->
      case match do
        %{severity: n} when is_integer(n) and n > acc -> n
        %{tags: tags} when is_list(tags) -> max(acc, max_severity_from_tags(tags))
        _ -> acc
      end
    end)
  end

  def max_severity_from_match(_), do: 0

  @doc """
  Extract the highest `ti:severity:N` value from a list of tags (0 if none).

  Prefer `max_severity_from_match/1` when a full match chain is available.
  """
  @spec max_severity_from_tags([String.t()]) :: non_neg_integer()
  def max_severity_from_tags(tags) when is_list(tags) do
    Enum.reduce(tags, 0, fn
      "ti:severity:" <> rest, acc ->
        case Integer.parse(rest) do
          {n, ""} when n > acc -> n
          _ -> acc
        end

      _, acc ->
        acc
    end)
  end

  def max_severity_from_tags(_), do: 0

  @doc "Feed source slugs from ti: tags (excludes label/severity meta-tags)."
  @spec sources_from_tags([String.t()]) :: [String.t()]
  def sources_from_tags(tags) when is_list(tags) do
    tags
    |> Enum.flat_map(fn
      "ti:label:" <> _ -> []
      "ti:severity:" <> _ -> []
      "ti:" <> source when source != "" -> [source]
      _ -> []
    end)
    |> Enum.uniq()
  end

  def sources_from_tags(_), do: []

  defp fetch_rows do
    case SQL.query(Repo, @load_active_sql, []) do
      {:ok, %{rows: rows}} ->
        parsed =
          rows
          |> Enum.map(fn
            [prefix, source, label, severity] when is_binary(prefix) ->
              map_indicator_row(prefix, source, label, severity)

            [prefix, source, label] when is_binary(prefix) ->
              map_indicator_row(prefix, source, label, nil)

            _ ->
              nil
          end)
          |> Enum.reject(&is_nil/1)
          # Collapse duplicate prefixes: merge tags, keep highest severity
          |> Enum.group_by(& &1.prefix)
          |> Enum.map(fn {prefix, group} ->
            tags =
              group
              |> Enum.flat_map(& &1.tags)
              |> collapse_severity_tags()
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

  defp collapse_severity_tags(tags) do
    max_sev = max_severity_from_tags(tags)

    rest =
      Enum.reject(tags, fn
        "ti:severity:" <> _ -> true
        _ -> false
      end)

    if max_sev > 0, do: rest ++ ["ti:severity:#{max_sev}"], else: rest
  end

  defp normalize_severity(n) when is_integer(n) and n > 0, do: n
  defp normalize_severity(n) when is_float(n) and n > 0, do: trunc(n)

  defp normalize_severity(n) when is_binary(n) do
    case Integer.parse(String.trim(n)) do
      {v, ""} when v > 0 -> v
      _ -> nil
    end
  end

  defp normalize_severity(_), do: nil
end
