defmodule ServiceRadar.Observability.ThreatIntelInvestigation do
  @moduledoc """
  Project-owned read model for current IP/CIDR threat-intel matches.

  Cache rows are endpoint state. Individual indicators are resolved in one
  CIDR-containment query, never per-row.
  """

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Observability.IpThreatIntelCache
  alias ServiceRadar.Observability.ThreatIntelIndicator
  alias ServiceRadar.Observability.ThreatIntelInvestigation.Keyset
  alias ServiceRadar.Repo

  require Ash.Query

  @page_size 100
  # A flow page is at most a few hundred rows; both endpoints of each row fit here.
  @max_endpoint_lookup 500

  @doc """
  One keyset page of current matched endpoints.

  Options: `:source`, `:ip` (exact observed address), `:min_severity`,
  `:stale` (include expired cache rows), `:sort` (`"recent"`, the default,
  orders by evaluation time; `"severity"` by maximum severity), `:limit`, and
  `:cursor` (the `next_cursor` of the previous page). Invalid input is an
  explicit error, never an empty page.
  """
  @spec list_current_matches(term(), keyword()) ::
          {:ok, %{rows: [map()], next_cursor: String.t() | nil}} | {:error, term()}
  def list_current_matches(scope, opts \\ []) do
    now = DateTime.utc_now()
    limit = Keyset.limit(opts[:limit])
    sort = match_sort(opts[:sort])

    with {:ok, ip} <- optional_ip(opts[:ip]),
         {:ok, min_severity} <- optional_integer(opts[:min_severity], :invalid_severity),
         {:ok, after_key} <- Keyset.decode(opts[:cursor], match_cursor_kinds(sort)) do
      query =
        IpThreatIntelCache
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(matched == true)
        |> maybe_filter_fresh(opts[:stale] == true, now)
        |> maybe_filter_source(opts[:source])
        |> maybe_filter_observed_ip(ip)
        |> maybe_filter_min_severity(min_severity)
        |> match_keyset_after(sort, after_key)
        |> sort_matches(sort)
        |> Ash.Query.limit(limit + 1)

      case Ash.read(query, scope: scope) do
        {:ok, rows} ->
          page = Keyset.page(rows, limit, &match_key(&1, sort))
          {:ok, %{page | rows: Enum.map(page.rows, &cache_row(&1, now))}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec indicators_for_ip(term(), term()) :: {:ok, [map()]} | {:error, term()}
  def indicators_for_ip(scope, ip) do
    with {:ok, ip} <- parse_ip(ip) do
      now = DateTime.utc_now()

      query =
        ThreatIntelIndicator
        |> Ash.Query.for_read(:containing_ip, %{ip: ip})
        |> Ash.Query.filter(is_nil(expires_at) or expires_at > ^now)
        |> Ash.Query.sort(severity: :desc, last_seen_at: :desc)
        |> Ash.Query.limit(@page_size)

      with {:ok, rows} <- Ash.read(query, scope: scope),
           {:ok, contexts} <- source_contexts(Enum.map(rows, & &1.id)) do
        {:ok, Enum.map(rows, &indicator_row(&1, Map.get(contexts, &1.id)))}
      end
    end
  end

  @doc """
  Returns the live current-match summary for each matched address in `ips`.

  This is the bounded batch lookup behind threat badges on flow pages: one
  primary-key read of `ip_threat_intel_cache` for the page's distinct
  endpoints, never one query per row. Unmatched, expired, and invalid addresses
  are absent from the map. More than #{@max_endpoint_lookup} distinct addresses
  is a caller error, not a silent truncation.
  """
  @spec endpoint_summaries(term(), [term()]) ::
          {:ok, %{String.t() => map()}} | {:error, term()}
  def endpoint_summaries(scope, ips) when is_list(ips) do
    case endpoint_lookup_ips(ips) do
      [] ->
        {:ok, %{}}

      lookup when length(lookup) > @max_endpoint_lookup ->
        {:error, {:too_many_endpoints, length(lookup), @max_endpoint_lookup}}

      lookup ->
        now = DateTime.utc_now()

        query =
          IpThreatIntelCache
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(matched == true and ip in ^lookup and expires_at > ^now)

        case Ash.read(query, scope: scope) do
          {:ok, rows} -> {:ok, Map.new(rows, &{&1.ip, endpoint_summary(&1)})}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Folds the source and destination endpoint summaries of one flow into a single
  flow-level summary, or `nil` when neither endpoint is a current match.

  A flow stays one row however many indicators contain its endpoints:
  `match_count` adds the two endpoints' indicator-match counts and `sources`
  is the distinct union.
  """
  @spec flow_summary(%{String.t() => map()}, term(), term()) :: map() | nil
  def flow_summary(summaries, src_ip, dst_ip) when is_map(summaries) do
    source = endpoint_for(summaries, src_ip)
    destination = if dst_ip == src_ip, do: nil, else: endpoint_for(summaries, dst_ip)

    case Enum.reject([source, destination], &is_nil/1) do
      [] ->
        nil

      sides ->
        %{
          match_count: sides |> Enum.map(& &1.match_count) |> Enum.sum(),
          max_severity:
            sides
            |> Enum.map(& &1.max_severity)
            |> Enum.reject(&is_nil/1)
            |> Enum.max(fn -> nil end),
          sources: sides |> Enum.flat_map(& &1.sources) |> Enum.uniq() |> Enum.sort(),
          source: source,
          destination: destination
        }
    end
  end

  defp endpoint_for(summaries, ip) when is_binary(ip), do: Map.get(summaries, String.trim(ip))
  defp endpoint_for(_summaries, _ip), do: nil

  defp endpoint_lookup_ips(ips) do
    ips
    |> Enum.flat_map(fn ip ->
      case parse_ip(ip) do
        {:ok, parsed} -> [parsed]
        {:error, _} -> []
      end
    end)
    |> Enum.uniq()
  end

  defp endpoint_summary(row) do
    %{
      ip: row.ip,
      match_count: row.match_count || 0,
      max_severity: row.max_severity,
      sources: row.sources |> List.wrap() |> Enum.reject(&(&1 in [nil, ""])),
      evaluated_at: row.looked_up_at,
      cache_expires_at: row.expires_at
    }
  end

  # Provider context for each indicator whose (source, indicator) maps to exactly
  # one imported source object. One query for the whole detail list; an
  # indicator with zero or several candidate objects gets no context rather
  # than a guess.
  defp source_contexts([]), do: {:ok, %{}}

  defp source_contexts(indicator_ids) do
    sql = """
    SELECT i.id::text, MIN(o.object_id), MIN(o.object_type), MIN(o.metadata->>'label'), COUNT(*)
    FROM platform.threat_intel_indicators i
    JOIN platform.threat_intel_source_objects o
      ON o.source = i.source
     AND o.metadata->>'indicator' IN (host(i.indicator), i.indicator::text)
    WHERE i.id = ANY($1::text[]::uuid[])
    GROUP BY i.id
    HAVING COUNT(*) = 1
    """

    case SQL.query(Repo, sql, [indicator_ids]) do
      {:ok, %Postgrex.Result{rows: rows}} ->
        {:ok,
         Map.new(rows, fn [id, object_id, object_type, label, _count] ->
           {id,
            %{source_object_id: object_id, source_object_type: object_type, source_label: label}}
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp match_sort(sort) when sort in ["severity", :severity], do: :severity
  defp match_sort(_sort), do: :recent

  defp match_cursor_kinds(:recent), do: [:datetime, :string]
  defp match_cursor_kinds(:severity), do: [:integer, :string]

  defp match_key(row, :recent), do: [row.looked_up_at, row.ip]
  defp match_key(row, :severity), do: [row.max_severity, row.ip]

  defp sort_matches(query, :recent), do: Ash.Query.sort(query, looked_up_at: :desc, ip: :asc)

  defp sort_matches(query, :severity),
    do: Ash.Query.sort(query, max_severity: :desc_nils_last, ip: :asc)

  defp match_keyset_after(query, _sort, nil), do: query

  defp match_keyset_after(query, :recent, [at, ip]) do
    Ash.Query.filter(query, looked_up_at < ^at or (looked_up_at == ^at and ip > ^ip))
  end

  defp match_keyset_after(query, :severity, [nil, ip]) do
    Ash.Query.filter(query, is_nil(max_severity) and ip > ^ip)
  end

  defp match_keyset_after(query, :severity, [severity, ip]) do
    Ash.Query.filter(
      query,
      is_nil(max_severity) or max_severity < ^severity or (max_severity == ^severity and ip > ^ip)
    )
  end

  defp maybe_filter_observed_ip(query, nil), do: query
  defp maybe_filter_observed_ip(query, ip), do: Ash.Query.filter(query, ip == ^ip)

  defp maybe_filter_min_severity(query, nil), do: query

  defp maybe_filter_min_severity(query, severity),
    do: Ash.Query.filter(query, max_severity >= ^severity)

  defp optional_ip(value) when value in [nil, ""], do: {:ok, nil}
  defp optional_ip(value), do: parse_ip(value)

  defp optional_integer(value, _error) when value in [nil, ""], do: {:ok, nil}
  defp optional_integer(value, _error) when is_integer(value), do: {:ok, value}

  defp optional_integer(value, error) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, error}
    end
  end

  defp optional_integer(_value, error), do: {:error, error}

  defp parse_ip(ip) when is_binary(ip) do
    trimmed = String.trim(ip)

    case :inet.parse_address(String.to_charlist(trimmed)) do
      {:ok, _addr} -> {:ok, trimmed}
      {:error, _reason} -> {:error, :invalid_ip}
    end
  end

  defp parse_ip(_ip), do: {:error, :invalid_ip}

  defp maybe_filter_fresh(query, true, _now), do: query

  defp maybe_filter_fresh(query, false, now) do
    Ash.Query.filter(query, expires_at > ^now)
  end

  defp maybe_filter_source(query, source) when is_binary(source) and source != "" do
    Ash.Query.filter(query, fragment("? = ANY(sources)", ^source))
  end

  defp maybe_filter_source(query, _), do: query

  defp cache_row(row, now) do
    %{
      observed_ip: row.ip,
      evaluated_at: row.looked_up_at,
      cache_expires_at: row.expires_at,
      indicator_match_count: row.match_count,
      max_severity: row.max_severity,
      sources: List.wrap(row.sources),
      match_kind: "current",
      stale: stale?(row.expires_at, now)
    }
  end

  defp stale?(%DateTime{} = expires_at, %DateTime{} = now) do
    DateTime.compare(expires_at, now) != :gt
  end

  defp stale?(_, _), do: false

  defp indicator_row(row, context) do
    %{
      source_context: context,
      indicator_id: row.id,
      indicator: to_string(row.indicator),
      indicator_type: row.indicator_type,
      source: row.source,
      label: row.label,
      severity: row.severity,
      confidence: row.confidence,
      indicator_first_seen_at: row.first_seen_at,
      indicator_last_seen_at: row.last_seen_at,
      indicator_expires_at: row.expires_at
    }
  end
end
