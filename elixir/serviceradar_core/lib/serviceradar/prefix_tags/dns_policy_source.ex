defmodule ServiceRadar.PrefixTags.DnsPolicySource do
  @moduledoc """
  Materializes RPZ-triggered client IPs into the `dns-policy` prefix-tag trie.

  Reads recent PowerDNS DNS Activity rows from `platform.ocsf_events` (class_uid
  4003) that carry a firewall_rule (RPZ hit). Tags are advisory
  (`dns-policy:<policy>`, `dns-policy:hit`). Clients that trigger RPZ policies
  become /32 or /128 prefixes for subsequent flow enrichment.

  Lookback and row caps are configurable; expired lookback windows drop hosts
  on the next refresh (same advisory cadence model as the ti: source).
  """

  @behaviour ServiceRadar.PrefixTags.ExternalSources

  alias Ecto.Adapters.SQL
  alias ServiceRadar.PrefixTags.ExternalSources
  alias ServiceRadar.PrefixTags.Loader
  alias ServiceRadar.PrefixTags.Slug
  alias ServiceRadar.PrefixTags.Store
  alias ServiceRadar.Repo

  require Logger

  @source "dns-policy"
  @default_lookback_hours 24
  @default_max_hosts 50_000

  # OCSF DNS Activity class_uid 4003; firewall_rule is set by the PowerDNS add-on
  # for RPZ policy hits.
  @load_rpz_clients_sql """
  WITH matching AS MATERIALIZED (
    SELECT
      e.src_endpoint #>> '{ip}' AS client_ip,
      e.raw_data::jsonb #>> '{firewall_rule,name}' AS policy_name,
      e.time AS observed_at
    FROM platform.ocsf_events e
    WHERE e.class_uid = 4003
      AND e.time > now() - ($1::text || ' hours')::interval
      AND e.raw_data::jsonb #>> '{firewall_rule,name}' IS NOT NULL
      AND e.raw_data::jsonb #>> '{firewall_rule,name}' <> ''
      AND e.src_endpoint #>> '{ip}' IS NOT NULL
      AND e.src_endpoint #>> '{ip}' <> ''
  ),
  active_clients AS (
    SELECT client_ip, policy_name, max(observed_at) AS latest_hit_at
    FROM matching
    GROUP BY client_ip, policy_name
    ORDER BY latest_hit_at DESC, client_ip, policy_name
    LIMIT $2
  ),
  freshness AS (
    SELECT max(observed_at) AS snapshot_at
    FROM matching
  )
  SELECT a.client_ip, a.policy_name, f.snapshot_at
  FROM freshness f
  LEFT JOIN active_clients a ON TRUE
  ORDER BY a.latest_hit_at DESC NULLS LAST, a.client_ip, a.policy_name
  """

  @doc "Canonical Store source name."
  @impl true
  @spec source_name() :: String.t()
  def source_name, do: @source

  @doc """
  Load recent RPZ-triggering client IPs into the dns-policy trie.

  Options:
  - `:broadcast?` (default `true`) — notify peer nodes. Loaders that invoke
    this on invalidation must pass `broadcast?: false` to avoid a PubSub loop.
  """
  @impl true
  @spec reload(keyword()) ::
          {:ok, ExternalSources.reload_result()} | {:error, term()}
  def reload(opts \\ []) do
    broadcast? = Keyword.get(opts, :broadcast?, true)
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    lookback = Keyword.get(config, :lookback_hours, @default_lookback_hours)
    max_hosts = Keyword.get(config, :max_hosts, @default_max_hosts)

    case SQL.query(Repo, @load_rpz_clients_sql, [to_string(lookback), max_hosts]) do
      {:ok, result} ->
        %{rows: rows, snapshot_at: snapshot_at} = parse_query_result(result)

        if rows == [] do
          Store.clear(@source)
        else
          _ = Store.put_rows(@source, rows)
        end

        if broadcast?, do: Loader.broadcast_invalidation(%{source: @source})
        Logger.info("PrefixTags.DnsPolicySource loaded dns-policy trie", rows: length(rows))
        {:ok, ExternalSources.reload_result(length(rows), snapshot_at)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  @doc false
  def map_client_row(client_ip, policy_name) when is_binary(client_ip) do
    prefix = host_prefix(client_ip)
    policy_slug = Slug.slugify(policy_name || "unknown", empty: "unknown")

    tags = Enum.uniq(["dns-policy:hit", "dns-policy:#{policy_slug}"])

    %{
      prefix: prefix,
      tags: tags,
      source: @source
    }
  end

  @doc false
  @spec parse_query_result(map()) :: %{rows: [map()], snapshot_at: DateTime.t() | nil}
  def parse_query_result(%{rows: rows}) when is_list(rows) do
    snapshot_at =
      Enum.find_value(rows, fn
        [_ip, _policy, value] -> ExternalSources.normalize_datetime(value)
        _ -> nil
      end)

    parsed =
      rows
      |> Enum.flat_map(fn
        [ip, policy, _snapshot_at] when is_binary(ip) and ip != "" ->
          [map_client_row(ip, policy)]

        _ ->
          []
      end)
      |> Enum.group_by(& &1.prefix)
      |> Enum.map(fn {prefix, group} ->
        tags =
          group
          |> Enum.flat_map(& &1.tags)
          |> Enum.uniq()
          |> Enum.take(16)

        %{prefix: prefix, tags: tags, source: @source}
      end)

    %{rows: parsed, snapshot_at: snapshot_at}
  end

  defp host_prefix(ip) do
    cond do
      String.contains?(ip, "/") -> ip
      String.contains?(ip, ":") -> "#{ip}/128"
      true -> "#{ip}/32"
    end
  end
end
