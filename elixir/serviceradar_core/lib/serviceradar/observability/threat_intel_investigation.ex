defmodule ServiceRadar.Observability.ThreatIntelInvestigation do
  @moduledoc """
  Project-owned read model for current IP/CIDR threat-intel matches.

  Cache rows are endpoint state. Individual indicators are resolved in one
  CIDR-containment query, never per-row.
  """

  alias ServiceRadar.Observability.IpThreatIntelCache
  alias ServiceRadar.Observability.ThreatIntelIndicator

  require Ash.Query

  @page_size 100

  @spec list_current_matches(term(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_current_matches(scope, opts \\ []) do
    now = DateTime.utc_now()
    limit = opts |> Keyword.get(:limit, @page_size) |> min(@page_size) |> max(1)
    source = opts[:source]

    query =
      IpThreatIntelCache
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(matched == true and expires_at > ^now)
      |> maybe_filter_source(source)
      |> Ash.Query.sort(looked_up_at: :desc, ip: :asc)
      |> Ash.Query.limit(limit)

    case Ash.read(query, scope: scope) do
      {:ok, rows} -> {:ok, Enum.map(rows, &cache_row/1)}
      {:error, reason} -> {:error, reason}
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

      case Ash.read(query, scope: scope) do
        {:ok, rows} -> {:ok, Enum.map(rows, &indicator_row/1)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp parse_ip(ip) when is_binary(ip) do
    trimmed = String.trim(ip)

    case :inet.parse_address(String.to_charlist(trimmed)) do
      {:ok, _addr} -> {:ok, trimmed}
      {:error, _reason} -> {:error, :invalid_ip}
    end
  end

  defp parse_ip(_ip), do: {:error, :invalid_ip}

  defp maybe_filter_source(query, source) when is_binary(source) and source != "" do
    Ash.Query.filter(query, fragment("? = ANY(sources)", ^source))
  end

  defp maybe_filter_source(query, _), do: query

  defp cache_row(row) do
    %{
      observed_ip: row.ip,
      evaluated_at: row.looked_up_at,
      cache_expires_at: row.expires_at,
      indicator_match_count: row.match_count,
      max_severity: row.max_severity,
      sources: List.wrap(row.sources),
      match_kind: "current"
    }
  end

  defp indicator_row(row) do
    %{
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
