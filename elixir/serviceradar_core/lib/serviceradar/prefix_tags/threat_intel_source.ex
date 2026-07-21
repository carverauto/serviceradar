defmodule ServiceRadar.PrefixTags.ThreatIntelSource do
  @moduledoc """
  Materializes active threat-intel CIDR indicators into the `ti` prefix-tag trie.

  Reads from `platform.threat_intel_indicators` (populated by OTX/feed workers).
  Only non-expired indicators are included. Tags are advisory point-in-time
  evidence (`ti:<source>`); authoritative matching stays on the threat-intel
  match pipeline.

  Does **not** retro-tag historical flows — only subsequent enrichment lookups
  see the refreshed trie.

  Per-prefix aggregation keeps a structured `indicators` list so CTI matching
  can apply per-member expiry (SQL parity: permanent + finite members on the
  same CIDR). Display tags are capped; raw source provenance and severity live
  on structured fields and are not subject to the display budget.
  """

  @behaviour ServiceRadar.PrefixTags.ExternalSources

  alias Ecto.Adapters.SQL
  alias ServiceRadar.PrefixTags.ExternalSources
  alias ServiceRadar.PrefixTags.Loader
  alias ServiceRadar.PrefixTags.Slug
  alias ServiceRadar.PrefixTags.Store
  alias ServiceRadar.Repo

  require Logger

  @source "ti"
  @max_tags_per_prefix 8

  @load_active_sql """
  WITH active AS (
    SELECT
      host(indicator) || '/' || masklen(indicator) AS prefix,
      source,
      label,
      severity,
      expires_at
    FROM platform.threat_intel_indicators
    WHERE (expires_at IS NULL OR expires_at > now())
  ),
  freshness AS (
    SELECT max(updated_at) AS snapshot_at
    FROM platform.threat_intel_indicators
  )
  SELECT
    a.prefix,
    a.source,
    a.label,
    a.severity,
    a.expires_at,
    f.snapshot_at
  FROM freshness f
  LEFT JOIN active a ON TRUE
  ORDER BY a.prefix, a.source, a.label, a.severity, a.expires_at
  """

  @doc "Canonical Store source name."
  @impl true
  @spec source_name() :: String.t()
  def source_name, do: @source

  @doc """
  Load active indicators into the `ti` trie.

  Options:
  - `:broadcast?` (default `true`) — notify peer nodes. Loaders that invoke
    this on invalidation must pass `broadcast?: false` to avoid a PubSub loop.
  """
  @impl true
  @spec reload(keyword()) ::
          {:ok, ExternalSources.reload_result()} | {:error, term()}
  def reload(opts \\ []) do
    broadcast? = Keyword.get(opts, :broadcast?, true)

    case SQL.query(Repo, @load_active_sql, []) do
      {:ok, result} ->
        %{rows: rows, snapshot_at: snapshot_at} = parse_query_result(result)

        if rows == [] do
          Store.clear(@source)
        else
          _ = Store.put_rows(@source, rows)
        end

        if broadcast?, do: Loader.broadcast_invalidation(%{source: @source})
        Logger.info("PrefixTags.ThreatIntelSource loaded ti trie", rows: length(rows))
        {:ok, ExternalSources.reload_result(length(rows), snapshot_at)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  @doc false
  def map_indicator_row(prefix, source, label, severity \\ nil, expires_at \\ nil)

  def map_indicator_row(prefix, source, label, severity, expires_at) when is_binary(prefix) do
    source_raw = source_string(source)
    source_slug = slug_source(source_raw)
    sev = normalize_severity(severity)
    exp = normalize_expires_at(expires_at)

    tags = ["ti:#{source_slug}"]

    tags =
      if is_binary(label) and String.trim(label) != "" do
        case slugify_label(label) do
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

    display_tags = tags |> Enum.reverse() |> Enum.uniq() |> take_display_tags()

    # Singleton rows omit nested :indicators — aggregate fields already carry
    # full semantics and avoid ~400B/row of resident trie payload at scale.
    # merge_prefix_group/2 only attaches :indicators when a CIDR has 2+ members.
    %{
      prefix: prefix,
      tags: display_tags,
      source: @source,
      severity: sev,
      # One indicator row contributes 1 toward SQL-parity match_count.
      indicator_count: 1,
      expires_at: exp,
      # Raw provenance for CTI (not subject to the display-tag cap).
      feed_sources: [source_raw],
      # Transient: only used when grouping duplicates before put_rows.
      __member: %{
        source: source_raw,
        source_slug: source_slug,
        severity: sev,
        expires_at: exp,
        indicator_count: 1,
        tags: display_tags
      }
    }
  end

  @doc """
  Highest severity from a Store match chain (prefers first-class `:severity`,
  falls back to `ti:severity:N` tags). Honors per-indicator expiry when
  `indicators` metadata is present.
  """
  @spec max_severity_from_match([map()], DateTime.t() | nil) :: non_neg_integer()
  def max_severity_from_match(chain, now \\ nil)

  def max_severity_from_match(chain, now) when is_list(chain) do
    now = now || DateTime.utc_now()

    Enum.reduce(chain, 0, fn match, acc ->
      case active_indicators(match, now) do
        [_ | _] = inds ->
          sev =
            inds
            |> Enum.map(& &1[:severity])
            |> Enum.reject(&is_nil/1)
            |> Enum.max(fn -> 0 end)

          max(acc, sev)

        [] ->
          if match_expired?(match, now) do
            acc
          else
            case match do
              %{severity: n} when is_integer(n) and n > acc -> n
              %{tags: tags} when is_list(tags) -> max(acc, max_severity_from_tags(tags))
              _ -> acc
            end
          end
      end
    end)
  end

  def max_severity_from_match(_, _), do: 0

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

  @doc """
  Raw feed sources for an active (non-expired) match chain.

  Prefer structured `feed_sources` / `indicators` over display tags so the
  eight-tag cap cannot drop provenance.
  """
  @spec sources_from_match([map()], DateTime.t() | nil) :: [String.t()]
  def sources_from_match(chain, now \\ nil)

  def sources_from_match(chain, now) when is_list(chain) do
    now = now || DateTime.utc_now()

    chain
    |> Enum.flat_map(fn match ->
      case active_indicators(match, now) do
        [_ | _] = inds ->
          Enum.map(inds, fn ind ->
            ind[:source] || ind[:source_slug] || ""
          end)

        [] ->
          if match_expired?(match, now) do
            []
          else
            case match do
              %{feed_sources: srcs} when is_list(srcs) -> srcs
              %{tags: tags} when is_list(tags) -> sources_from_tags(tags)
              _ -> []
            end
          end
      end
    end)
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def sources_from_match(_, _), do: []

  @doc "SQL-parity match count from active indicators on a chain."
  @spec indicator_count_from_match([map()], DateTime.t() | nil) :: non_neg_integer()
  def indicator_count_from_match(chain, now \\ nil)

  def indicator_count_from_match(chain, now) when is_list(chain) do
    now = now || DateTime.utc_now()

    Enum.reduce(chain, 0, fn match, acc ->
      case active_indicators(match, now) do
        [_ | _] = inds ->
          sum =
            inds
            |> Enum.map(fn
              %{indicator_count: n} when is_integer(n) and n > 0 -> n
              _ -> 1
            end)
            |> Enum.sum()

          acc + sum

        [] ->
          if match_expired?(match, now) do
            acc
          else
            case match do
              %{indicator_count: n} when is_integer(n) and n > 0 -> acc + n
              _ -> acc + 1
            end
          end
      end
    end)
  end

  def indicator_count_from_match(_, _), do: 0

  @doc false
  @spec match_expired?(map(), DateTime.t()) :: boolean()
  def match_expired?(match, now) when is_map(match) do
    case normalize_expires_at(Map.get(match, :expires_at)) do
      %DateTime{} = exp -> DateTime.compare(exp, now) != :gt
      _ -> false
    end
  end

  def match_expired?(_, _), do: false

  @doc false
  @spec active_indicators(map(), DateTime.t()) :: [map()]
  def active_indicators(%{indicators: inds}, now) when is_list(inds) do
    Enum.filter(inds, fn ind ->
      case normalize_expires_at(ind[:expires_at] || ind["expires_at"]) do
        %DateTime{} = exp -> DateTime.after?(exp, now)
        _ -> true
      end
    end)
  end

  def active_indicators(_, _), do: []

  @doc false
  @spec parse_query_result(map()) :: %{rows: [map()], snapshot_at: DateTime.t() | nil}
  def parse_query_result(%{rows: rows}) when is_list(rows) do
    snapshot_at =
      Enum.find_value(rows, fn
        [_prefix, _source, _label, _severity, _expires_at, value] ->
          ExternalSources.normalize_datetime(value)

        _ ->
          nil
      end)

    parsed =
      rows
      |> Enum.flat_map(fn
        [prefix, source, label, severity, expires_at, _snapshot_at]
        when is_binary(prefix) ->
          [map_indicator_row(prefix, source, label, severity, expires_at)]

        _ ->
          []
      end)
      # Collapse duplicate prefixes for the display trie, but keep each
      # indicator's own expiry/severity/source for CTI parity.
      |> Enum.group_by(& &1.prefix)
      |> Enum.map(fn {prefix, group} -> merge_prefix_group(prefix, group) end)

    %{rows: parsed, snapshot_at: snapshot_at}
  end

  defp merge_prefix_group(prefix, group) when is_list(group) do
    members =
      Enum.map(group, fn row ->
        case row do
          %{__member: m} when is_map(m) -> m
          %{indicators: [m | _]} when is_map(m) -> m
          row -> row_as_indicator(row)
        end
      end)

    feed_sources =
      members
      |> Enum.map(&(&1[:source] || ""))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    raw_tags = Enum.flat_map(group, &List.wrap(&1.tags))
    display_tags = build_display_tags(raw_tags)
    expires_at = aggregate_expires_at(members)

    sev =
      members
      |> Enum.map(& &1[:severity])
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> nil end)

    count =
      members
      |> Enum.map(&(&1[:indicator_count] || 1))
      |> Enum.sum()

    base = %{
      prefix: prefix,
      tags: display_tags,
      source: @source,
      severity: sev,
      indicator_count: count,
      expires_at: expires_at,
      feed_sources: feed_sources
    }

    # Only multi-member groups need per-indicator expiry metadata in the trie.
    if length(members) > 1 do
      Map.put(base, :indicators, members)
    else
      base
    end
  end

  defp row_as_indicator(row) do
    %{
      source: List.first(List.wrap(row[:feed_sources])) || source_from_tags(row[:tags]),
      source_slug: nil,
      severity: row[:severity],
      expires_at: row[:expires_at],
      indicator_count: row[:indicator_count] || 1,
      tags: List.wrap(row[:tags])
    }
  end

  defp source_from_tags(tags) when is_list(tags) do
    case sources_from_tags(tags) do
      [s | _] -> s
      _ -> "unknown"
    end
  end

  defp source_from_tags(_), do: "unknown"

  # Never expire the whole prefix at the earliest member: if any indicator has
  # no expiry (permanent), coarse gate is nil. Otherwise use the *latest*
  # expiry so permanent-style late members survive intermediate ones.
  defp aggregate_expires_at(indicators) do
    expiries = Enum.map(indicators, &normalize_expires_at(&1[:expires_at]))

    if Enum.any?(expiries, &is_nil/1) do
      nil
    else
      case Enum.reject(expiries, &is_nil/1) do
        [] -> nil
        dts -> Enum.max(dts, DateTime)
      end
    end
  end

  defp build_display_tags(tags) do
    max_sev = max_severity_from_tags(tags)

    rest =
      tags
      |> Enum.reject(fn
        "ti:severity:" <> _ -> true
        _ -> false
      end)
      |> Enum.uniq()
      # Reserve one slot for the severity tag when present.
      |> Enum.take(if(max_sev > 0, do: @max_tags_per_prefix - 1, else: @max_tags_per_prefix))

    if max_sev > 0, do: rest ++ ["ti:severity:#{max_sev}"], else: rest
  end

  defp take_display_tags(tags) do
    build_display_tags(tags)
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

  # platform.threat_intel_indicators.expires_at is timestamp without time zone.
  # Raw SQL returns NaiveDateTime; normalize to UTC DateTime at the parse boundary.
  @doc false
  @spec normalize_expires_at(term()) :: DateTime.t() | nil
  def normalize_expires_at(%DateTime{} = dt), do: DateTime.shift_zone!(dt, "Etc/UTC")

  def normalize_expires_at(%NaiveDateTime{} = ndt) do
    DateTime.from_naive!(ndt, "Etc/UTC")
  end

  def normalize_expires_at(bin) when is_binary(bin) do
    case DateTime.from_iso8601(bin) do
      {:ok, dt, _} ->
        DateTime.shift_zone!(dt, "Etc/UTC")

      _ ->
        case NaiveDateTime.from_iso8601(bin) do
          {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
          _ -> nil
        end
    end
  rescue
    _ -> nil
  end

  def normalize_expires_at(_), do: nil

  defp source_string(nil), do: "unknown"
  defp source_string(s) when is_binary(s), do: String.trim(s)
  defp source_string(s), do: to_string(s)

  defp slug_source(source) do
    Slug.slugify(source, empty: "unknown")
  end

  defp slugify_label(label) do
    Slug.slugify(label)
  end
end
