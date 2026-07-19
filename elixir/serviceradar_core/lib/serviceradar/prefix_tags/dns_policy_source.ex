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

  alias Ecto.Adapters.SQL
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
  SELECT DISTINCT
    e.ocsf_payload #>> '{src_endpoint,ip}' AS client_ip,
    e.ocsf_payload #>> '{firewall_rule,name}' AS policy_name
  FROM platform.ocsf_events e
  WHERE e.class_uid = 4003
    AND e.time > now() - ($1::text || ' hours')::interval
    AND e.ocsf_payload #>> '{firewall_rule,name}' IS NOT NULL
    AND e.ocsf_payload #>> '{firewall_rule,name}' <> ''
    AND e.ocsf_payload #>> '{src_endpoint,ip}' IS NOT NULL
    AND e.ocsf_payload #>> '{src_endpoint,ip}' <> ''
  LIMIT $2
  """

  @doc "Canonical Store source name."
  @spec source_name() :: String.t()
  def source_name, do: @source

  @doc """
  Load recent RPZ-triggering client IPs into the dns-policy trie.

  Options:
  - `:broadcast?` (default `true`) — notify peer nodes. Loaders that invoke
    this on invalidation must pass `broadcast?: false` to avoid a PubSub loop.
  """
  @spec reload(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def reload(opts \\ []) do
    broadcast? = Keyword.get(opts, :broadcast?, true)
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    lookback = Keyword.get(config, :lookback_hours, @default_lookback_hours)
    max_hosts = Keyword.get(config, :max_hosts, @default_max_hosts)

    case fetch_rows(lookback, max_hosts) do
      {:ok, rows} ->
        if rows == [] do
          Store.clear(@source)
        else
          _ = Store.put_rows(@source, rows)
        end

        if broadcast?, do: Loader.broadcast_invalidation(%{source: @source})
        Logger.info("PrefixTags.DnsPolicySource loaded dns-policy trie", rows: length(rows))
        {:ok, length(rows)}

      {:error, reason} ->
        {:error, reason}
    end
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

  defp fetch_rows(lookback_hours, max_hosts) do
    case SQL.query(Repo, @load_rpz_clients_sql, [to_string(lookback_hours), max_hosts]) do
      {:ok, %{rows: rows}} ->
        parsed =
          rows
          |> Enum.map(fn
            [ip, policy] when is_binary(ip) and ip != "" ->
              map_client_row(ip, policy)

            _ ->
              nil
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.group_by(& &1.prefix)
          |> Enum.map(fn {prefix, group} ->
            tags =
              group
              |> Enum.flat_map(& &1.tags)
              |> Enum.uniq()
              |> Enum.take(16)

            %{prefix: prefix, tags: tags, source: @source}
          end)

        {:ok, parsed}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp host_prefix(ip) do
    cond do
      String.contains?(ip, "/") -> ip
      String.contains?(ip, ":") -> "#{ip}/128"
      true -> "#{ip}/32"
    end
  end
end
