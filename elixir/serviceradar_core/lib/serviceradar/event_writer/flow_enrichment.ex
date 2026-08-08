defmodule ServiceRadar.EventWriter.FlowEnrichment do
  @moduledoc """
  Ingestion-time enrichment for OCSF flow rows.

  This module is intentionally deterministic and side-effect light:
  - protocol/tcp/service/direction are pure transforms
  - hosting-provider lookups use the in-memory `provider` prefix-tag trie
    (`ProviderSource`); GiST SQL is only a boot/empty-trie fallback
  - OUI lookups read from CNPG snapshot tables
  """

  alias Ecto.Adapters.SQL
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.PrefixTags.Store, as: PrefixTagStore
  alias ServiceRadar.PrefixTags.ThreatIntelSource
  alias ServiceRadar.ReferenceData.ServicePorts
  alias ServiceRadar.Repo
  alias ServiceRadar.Types.Cidr

  require Logger

  @tcp_flag_bits [
    {128, "CWR"},
    {64, "ECE"},
    {32, "URG"},
    {16, "ACK"},
    {8, "PSH"},
    {4, "RST"},
    {2, "SYN"},
    {1, "FIN"}
  ]

  @provider_lookup_sql """
  SELECT c.provider
  FROM platform.netflow_provider_cidrs c
  WHERE c.snapshot_id = $2
    AND ($1)::inet <<= c.cidr
  ORDER BY masklen(c.cidr) DESC
  LIMIT 1
  """

  @active_snapshot_sql """
  SELECT id
  FROM platform.netflow_provider_dataset_snapshots
  WHERE is_active = TRUE
  LIMIT 1
  """

  @oui_lookup_sql """
  SELECT p.organization
  FROM platform.netflow_oui_prefixes p
  JOIN platform.netflow_oui_dataset_snapshots s ON s.id = p.snapshot_id
  WHERE s.is_active = TRUE
    AND p.oui_prefix_int = $1
  LIMIT 1
  """

  @provider_cache_key {__MODULE__, :provider_lookup_cache}
  @provider_lookup_fun_key {__MODULE__, :provider_lookup_fun}
  @active_snapshot_key {__MODULE__, :provider_active_snapshot_id}
  @prefix_tag_cache_key {__MODULE__, :prefix_tag_lookup_cache}

  @type enrichment_input :: %{
          optional(:protocol_num) => integer() | String.t() | nil,
          optional(:tcp_flags) => integer() | String.t() | nil,
          optional(:dst_port) => integer() | String.t() | nil,
          optional(:bytes_in) => integer() | String.t() | nil,
          optional(:bytes_out) => integer() | String.t() | nil,
          optional(:src_ip) => String.t() | nil,
          optional(:dst_ip) => String.t() | nil,
          optional(:src_mac) => String.t() | nil,
          optional(:dst_mac) => String.t() | nil
        }

  @type enrichment_output :: map()

  @doc false
  @spec with_provider_cache((-> result), keyword()) :: result when result: term()
  def with_provider_cache(fun, opts \\ []) when is_function(fun, 0) do
    previous_cache = Process.get(@provider_cache_key, :__serviceradar_unset__)
    previous_lookup_fun = Process.get(@provider_lookup_fun_key, :__serviceradar_unset__)
    previous_snapshot = Process.get(@active_snapshot_key, :__serviceradar_unset__)
    previous_prefix_tag = Process.get(@prefix_tag_cache_key, :__serviceradar_unset__)

    Process.put(@provider_cache_key, %{})
    # Memoize prefix-tag LPM lookups for the batch (src/dst IPs often repeat).
    Process.put(@prefix_tag_cache_key, %{})

    case Keyword.fetch(opts, :provider_lookup) do
      {:ok, lookup_fun} when is_function(lookup_fun, 1) ->
        Process.put(@provider_lookup_fun_key, lookup_fun)

      :error ->
        # Lazy: do not hit CNPG unless the SQL fallback path is actually used
        # (provider trie ready is the steady-state path).
        Process.put(@active_snapshot_key, :lazy)
    end

    try do
      fun.()
    after
      restore_process_value(@provider_cache_key, previous_cache)
      restore_process_value(@provider_lookup_fun_key, previous_lookup_fun)
      restore_process_value(@active_snapshot_key, previous_snapshot)
      restore_process_value(@prefix_tag_cache_key, previous_prefix_tag)
    end
  end

  defp fetch_active_snapshot_id do
    case SQL.query(Repo, @active_snapshot_sql, []) do
      {:ok, %{rows: [[snapshot_id]]}} -> snapshot_id
      _ -> nil
    end
  rescue
    e ->
      Logger.debug("FlowEnrichment active snapshot lookup failed", error: Exception.message(e))
      nil
  end

  @spec enrich(enrichment_input()) :: enrichment_output()
  def enrich(attrs) when is_map(attrs) do
    protocol_num = parse_int(Map.get(attrs, :protocol_num))
    tcp_flags = parse_int(Map.get(attrs, :tcp_flags))
    dst_port = parse_int(Map.get(attrs, :dst_port))
    bytes_in = parse_int(Map.get(attrs, :bytes_in))
    bytes_out = parse_int(Map.get(attrs, :bytes_out))

    protocol_name = OCSF.protocol_name(protocol_num)

    tcp_flag_labels = decode_tcp_flags(tcp_flags)

    src_ip = trim_or_nil(Map.get(attrs, :src_ip))
    dst_ip = trim_or_nil(Map.get(attrs, :dst_ip))

    # One multi-source LPM walk per IP covers hosting-provider + prefix tags.
    src_ip_enrichment = ip_enrichment(src_ip)
    dst_ip_enrichment = ip_enrichment(dst_ip)

    src_mac = normalize_mac(Map.get(attrs, :src_mac))
    dst_mac = normalize_mac(Map.get(attrs, :dst_mac))

    src_vendor = oui_vendor_for_mac(src_mac)
    dst_vendor = oui_vendor_for_mac(dst_mac)
    dst_service = service_lookup(protocol_num, dst_port)

    base = %{
      protocol_name: protocol_name,
      protocol_source: if(is_integer(protocol_num), do: "iana", else: "unknown"),
      tcp_flags: tcp_flags,
      tcp_flags_labels: tcp_flag_labels,
      tcp_flags_source: if(is_integer(tcp_flags), do: "iana", else: "unknown"),
      dst_service_label: label_from_service(dst_service),
      dst_service_source: source_from_service(dst_service),
      direction_label: direction_label(bytes_in, bytes_out),
      direction_source: "heuristic",
      src_hosting_provider: src_ip_enrichment.provider,
      src_hosting_provider_source:
        source_for_lookup(src_ip_enrichment.provider, src_ip_enrichment.provider_source),
      dst_hosting_provider: dst_ip_enrichment.provider,
      dst_hosting_provider_source:
        source_for_lookup(dst_ip_enrichment.provider, dst_ip_enrichment.provider_source),
      src_mac: src_mac,
      dst_mac: dst_mac,
      src_mac_vendor: src_vendor,
      src_mac_vendor_source: source_for_lookup(src_vendor, "ieee_oui"),
      dst_mac_vendor: dst_vendor,
      dst_mac_vendor_source: source_for_lookup(dst_vendor, "ieee_oui")
    }

    if prefix_tag_enrichment_enabled?() do
      Map.merge(base, %{
        src_prefix_tags: src_ip_enrichment.tags,
        src_prefix_tags_source: src_ip_enrichment.tags_source,
        dst_prefix_tags: dst_ip_enrichment.tags,
        dst_prefix_tags_source: dst_ip_enrichment.tags_source
      })
    else
      base
    end
  end

  defp source_for_lookup(nil, _), do: "unknown"
  defp source_for_lookup(_val, source), do: source

  @doc """
  Whether prefix-tag enrichment is enabled.

  Controlled by Application env `:prefix_tag_enrichment_enabled` (default false).
  Keep off until `prefix_tag` migrations are applied everywhere EventWriter
  inserts; enabling with a pre-migration schema fails inserts. Fail-open when
  enabled: lookup errors / empty tries leave rows untagged.
  """
  @spec prefix_tag_enrichment_enabled?() :: boolean()
  def prefix_tag_enrichment_enabled? do
    Application.get_env(:serviceradar_core, :prefix_tag_enrichment_enabled, false) == true
  end

  @doc false
  @spec prefix_tags_for_ip(String.t() | nil) ::
          %{tags: [String.t()] | nil, source: String.t() | nil}
  def prefix_tags_for_ip(nil), do: %{tags: nil, source: nil}

  def prefix_tags_for_ip(ip) when is_binary(ip) do
    e = ip_enrichment(ip)
    %{tags: e.tags, source: e.tags_source}
  end

  # Combined LPM + geo + provider extraction for one IP (batch-memoized).
  defp ip_enrichment(nil) do
    %{
      tags: nil,
      tags_source: nil,
      provider: nil,
      provider_source: "cloud_provider_db"
    }
  end

  defp ip_enrichment(ip) when is_binary(ip) do
    case Process.get(@prefix_tag_cache_key) do
      %{} = cache ->
        case Map.fetch(cache, ip) do
          {:ok, cached} ->
            cached

          :error ->
            result = do_ip_enrichment(ip)
            Process.put(@prefix_tag_cache_key, Map.put(cache, ip, result))
            result
        end

      _ ->
        do_ip_enrichment(ip)
    end
  end

  defp do_ip_enrichment(ip) when is_binary(ip) do
    tags_enabled? = prefix_tag_enrichment_enabled?()
    provider_trie? = provider_trie_enabled?()

    # When tag enrichment is off, only walk the provider trie (not every source).
    # When provider-trie rollback is off, exclude provider from the aggregate
    # chain so stale provider:* tags cannot leak into prefix_tags columns.
    chain =
      try do
        cond do
          tags_enabled? and provider_trie? ->
            PrefixTagStore.lookup(ip)

          tags_enabled? ->
            ip
            |> PrefixTagStore.lookup()
            |> Enum.reject(&(Map.get(&1, :source) == "provider"))

          provider_trie? ->
            PrefixTagStore.lookup(ip, "provider")

          true ->
            []
        end
      rescue
        e ->
          Logger.debug("FlowEnrichment prefix tag lookup failed",
            ip: ip,
            error: Exception.message(e)
          )

          []
      end

    {provider, provider_source} = provider_from_chain_or_sql(chain, ip)

    if tags_enabled? do
      {trie_tags, trie_sources} = flatten_tag_chain(chain)
      geo_tags = geo_tags_for_ip(ip)
      tags = Enum.uniq(trie_tags ++ geo_tags)
      tags_source = chain_sources_label(trie_sources, geo_tags)

      %{
        tags: if(tags == [], do: nil, else: tags),
        tags_source: tags_source,
        provider: provider,
        provider_source: provider_source
      }
    else
      %{
        tags: nil,
        tags_source: nil,
        provider: provider,
        provider_source: provider_source
      }
    end
  end

  # Comma-joined source ids that contributed at least one persisted tag.
  defp chain_sources_label(sources, geo_tags) when is_list(sources) do
    sources =
      sources
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    sources =
      if geo_tags != [] and "geo" not in sources do
        sources ++ ["geo"]
      else
        sources
      end

    case sources do
      [] -> nil
      list -> Enum.join(list, ",")
    end
  end

  defp provider_from_chain_or_sql(chain, ip) do
    # Operational rollback: when the provider trie flag is off, never consume
    # trie hits — always take SQL / injected lookup.
    if provider_trie_enabled?() do
      case provider_name_from_chain(chain) do
        name when is_binary(name) and name != "" ->
          {name, "provider_trie"}

        _ ->
          if provider_trie_ready?() do
            # Loaded (including empty): miss is authoritative (no SQL).
            {nil, "cloud_provider_db"}
          else
            {sql_provider_for_ip(ip), "cloud_provider_db"}
          end
      end
    else
      {sql_provider_for_ip(ip), "cloud_provider_db"}
    end
  end

  # Hosting-provider columns only accept matches from the authoritative
  # `provider` source — manual/netbox tags may use `provider:` syntax without
  # overriding cloud-provider attribution.
  defp provider_name_from_chain(chain) when is_list(chain) do
    Enum.find_value(chain, fn
      %{source: "provider", tags: tags} when is_list(tags) ->
        Enum.find_value(tags, fn
          "provider:" <> name when name != "" -> name
          _ -> nil
        end)

      _ ->
        nil
    end)
  end

  @doc """
  Whether geo-derived tags (`geo:country:`, `geo:asn:`) are merged into the
  prefix-tag columns. Uses the resident Geolix MMDB; never imports MMDB into
  the trie. Default false.
  """
  @spec geo_tag_derivation_enabled?() :: boolean()
  def geo_tag_derivation_enabled? do
    Application.get_env(:serviceradar_core, :geo_tag_derivation_enabled, false) == true
  end

  @doc false
  @spec geo_tags_for_ip(String.t() | nil) :: [String.t()]
  def geo_tags_for_ip(nil), do: []

  def geo_tags_for_ip(ip) when is_binary(ip) do
    if geo_tag_derivation_enabled?() do
      case ServiceRadar.Observability.GeoIP.lookup(ip) do
        {:ok, geo} when is_map(geo) ->
          []
          |> maybe_geo_tag("geo:country:", Map.get(geo, :country_iso2))
          |> maybe_geo_tag("geo:asn:", Map.get(geo, :asn))
          |> Enum.reverse()

        _ ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  end

  defp maybe_geo_tag(acc, _prefix, nil), do: acc
  defp maybe_geo_tag(acc, _prefix, ""), do: acc

  defp maybe_geo_tag(acc, prefix, value) when is_integer(value) do
    [prefix <> Integer.to_string(value) | acc]
  end

  defp maybe_geo_tag(acc, prefix, value) when is_binary(value) do
    v = value |> String.trim() |> String.downcase()
    if v == "", do: acc, else: [prefix <> v | acc]
  end

  defp maybe_geo_tag(acc, _, _), do: acc

  defp flatten_tag_chain(chain) when is_list(chain) do
    now = DateTime.utc_now()

    contributions =
      Enum.map(chain, fn match ->
        tags =
          case match do
            %{source: "ti"} = m ->
              # Derive TI display tags from still-active members so expired feed
              # provenance/severity never lands on newly enriched flows.
              tags_from_active_ti_match(m, now)

            %{tags: tags} when is_list(tags) ->
              if ThreatIntelSource.match_expired?(match, now), do: [], else: tags

            _ ->
              []
          end

        source = if is_map(match), do: Map.get(match, :source)
        {source, tags}
      end)

    tags = contributions |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq()

    sources =
      contributions
      |> Enum.filter(fn {_source, tags} -> tags != [] end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()

    {tags, sources}
  end

  defp tags_from_active_ti_match(match, now) do
    case ThreatIntelSource.active_indicators(match, now) do
      [_ | _] = inds ->
        inds
        |> Enum.flat_map(&List.wrap(&1[:tags] || &1["tags"]))
        |> rebuild_ti_display_tags()

      [] ->
        if ThreatIntelSource.match_expired?(match, now) do
          []
        else
          # Singleton aggregates omit :indicators; use aggregate fields.
          match[:tags]
          |> List.wrap()
          |> then(fn tags ->
            if tags == [] and is_integer(match[:severity]) and match[:severity] > 0 do
              feed =
                case match[:feed_sources] do
                  [s | _] -> "ti:#{ServiceRadar.PrefixTags.Slug.slugify(s, empty: "unknown")}"
                  _ -> nil
                end

              Enum.reject([feed, "ti:severity:#{match[:severity]}"], &is_nil/1)
            else
              tags
            end
          end)
        end
    end
  end

  defp rebuild_ti_display_tags(tags) do
    max_sev = ThreatIntelSource.max_severity_from_tags(tags)

    rest =
      tags
      |> Enum.reject(fn
        "ti:severity:" <> _ -> true
        _ -> false
      end)
      |> Enum.uniq()
      |> Enum.take(if(max_sev > 0, do: 7, else: 8))

    if max_sev > 0, do: rest ++ ["ti:severity:#{max_sev}"], else: rest
  end

  @spec decode_tcp_flags(integer() | nil) :: [String.t()]
  def decode_tcp_flags(nil), do: []

  def decode_tcp_flags(flags) when is_integer(flags) and flags >= 0 do
    @tcp_flag_bits
    |> Enum.reduce([], fn {bit, name}, acc ->
      if Bitwise.band(flags, bit) == 0, do: acc, else: [name | acc]
    end)
    |> Enum.reverse()
  end

  def decode_tcp_flags(_), do: []

  @spec service_label(integer() | nil, integer() | nil) :: String.t() | nil
  def service_label(protocol_num, dst_port)
      when is_integer(protocol_num) and is_integer(dst_port) and dst_port > 0 do
    ServicePorts.label(protocol_num, dst_port)
  end

  def service_label(_, _), do: nil

  defp service_lookup(protocol_num, dst_port)
       when is_integer(protocol_num) and is_integer(dst_port) and dst_port > 0 do
    ServicePorts.lookup(protocol_num, dst_port)
  end

  defp service_lookup(_, _), do: nil

  defp label_from_service(%{label: label}), do: label
  defp label_from_service(_), do: nil

  defp source_from_service(%{source: source}), do: source
  defp source_from_service(_), do: "unknown"

  @spec direction_label(integer() | nil, integer() | nil) :: String.t()
  def direction_label(bytes_in, bytes_out)

  def direction_label(bytes_in, bytes_out)
      when is_integer(bytes_in) and bytes_in > 0 and is_integer(bytes_out) and bytes_out > 0,
      do: "bidirectional"

  def direction_label(bytes_in, bytes_out)
      when is_integer(bytes_in) and bytes_in > 0 and (is_nil(bytes_out) or bytes_out == 0),
      do: "ingress"

  def direction_label(bytes_in, bytes_out)
      when is_integer(bytes_out) and bytes_out > 0 and (is_nil(bytes_in) or bytes_in == 0),
      do: "egress"

  def direction_label(_, _), do: "unknown"

  @doc """
  Whether hosting-provider lookups should use the in-memory prefix-tag engine.

  When true (default), uses the `provider` trie. Falls back to per-batch GiST SQL
  only while the provider trie is empty (not yet loaded) or when the flag is
  disabled for tests. Cross-batch ETS caching was removed — the trie is the
  durable LPM cache.
  """
  @spec provider_trie_enabled?() :: boolean()
  def provider_trie_enabled? do
    Application.get_env(:serviceradar_core, :prefix_tag_provider_trie_enabled, true) == true
  end

  @spec provider_for_ip(String.t() | nil) :: String.t() | nil
  def provider_for_ip(nil), do: nil

  def provider_for_ip(ip) when is_binary(ip) do
    normalized = trim_or_nil(ip)

    if is_nil(normalized) do
      nil
    else
      ip_enrichment(normalized).provider
    end
  end

  defp provider_trie_ready? do
    # Loaded (even empty) is authoritative. Never-installed falls back to SQL.
    # Requiring total_prefixes > 0 treated an empty successful load as "booting"
    # and hammered SQL on every batch.
    PrefixTagStore.loaded?("provider")
  end

  defp sql_provider_for_ip(ip) when is_binary(ip) do
    case Cidr.dump_to_native(ip, []) do
      {:ok, %Postgrex.INET{} = inet} -> cached_provider_for_inet(inet)
      _ -> nil
    end
  end

  defp cached_provider_for_inet(%Postgrex.INET{} = inet) do
    key = provider_cache_key(inet)

    case Process.get(@provider_cache_key) do
      %{} = cache ->
        if Map.has_key?(cache, key) do
          Map.fetch!(cache, key)
        else
          provider = lookup_provider_for_inet(inet)
          Process.put(@provider_cache_key, Map.put(cache, key, provider))
          provider
        end

      _ ->
        lookup_provider_for_inet(inet)
    end
  end

  defp lookup_provider_for_inet(%Postgrex.INET{} = inet) do
    case Process.get(@provider_lookup_fun_key, :__serviceradar_unset__) do
      lookup_fun when is_function(lookup_fun, 1) ->
        # Test/injection path: honor the injected fun so existing tests that
        # assert exact DB call counts keep working.
        lookup_fun.(inet)

      :__serviceradar_unset__ ->
        # Per-batch Process-dict cache is L1 (with_provider_cache/2). SQL path is
        # only for empty-trie boot / flag-off; production uses ProviderSource.
        query_provider_for_inet(inet)
    end
  end

  defp query_provider_for_inet(%Postgrex.INET{} = inet) do
    case resolve_active_snapshot_id() do
      nil ->
        nil

      snapshot_id ->
        query_provider_for_inet(inet, snapshot_id)
    end
  end

  defp resolve_active_snapshot_id do
    case Process.get(@active_snapshot_key) do
      :lazy ->
        id = fetch_active_snapshot_id()
        Process.put(@active_snapshot_key, id)
        id

      :__serviceradar_unset__ ->
        nil

      other ->
        other
    end
  end

  defp query_provider_for_inet(%Postgrex.INET{} = inet, snapshot_id) do
    with {:ok, %{rows: [[provider]]}} <-
           SQL.query(Repo, @provider_lookup_sql, [inet, snapshot_id]),
         true <- is_binary(provider) and provider != "" do
      provider
    else
      _ -> nil
    end
  rescue
    e ->
      Logger.debug("FlowEnrichment provider lookup failed",
        ip: provider_cache_key(inet),
        error: Exception.message(e)
      )

      nil
  end

  defp provider_cache_key(%Postgrex.INET{address: address, netmask: netmask}) do
    "#{address |> :inet.ntoa() |> to_string()}/#{netmask}"
  end

  defp restore_process_value(key, :__serviceradar_unset__), do: Process.delete(key)
  defp restore_process_value(key, value), do: Process.put(key, value)

  @spec oui_vendor_for_mac(String.t() | nil) :: String.t() | nil
  def oui_vendor_for_mac(nil), do: nil

  def oui_vendor_for_mac(mac) when is_binary(mac) do
    with {:ok, prefix} <- oui_prefix_int(mac),
         {:ok, %{rows: [[org]]}} <- SQL.query(Repo, @oui_lookup_sql, [prefix]),
         true <- is_binary(org) and org != "" do
      org
    else
      _ -> nil
    end
  rescue
    e ->
      Logger.debug("FlowEnrichment OUI lookup failed", mac: mac, error: Exception.message(e))
      nil
  end

  @spec normalize_mac(String.t() | nil) :: String.t() | nil
  def normalize_mac(nil), do: nil

  def normalize_mac(mac) when is_binary(mac) do
    compact =
      mac
      |> String.split("/", parts: 2)
      |> List.first()
      |> String.trim()
      |> String.upcase()
      |> String.replace(~r/[^0-9A-F]/u, "")

    if String.length(compact) == 12, do: compact
  end

  def normalize_mac(_), do: nil

  @spec oui_prefix_int(String.t()) :: {:ok, integer()} | {:error, :invalid_mac}
  def oui_prefix_int(mac_hex) when is_binary(mac_hex) do
    case String.slice(mac_hex, 0, 6) do
      <<a::binary-size(6)>> ->
        case Integer.parse(a, 16) do
          {prefix, ""} -> {:ok, prefix}
          _ -> {:error, :invalid_mac}
        end

      _ ->
        {:error, :invalid_mac}
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(v) when is_integer(v), do: v

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

  defp trim_or_nil(nil), do: nil

  defp trim_or_nil(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_or_nil(_), do: nil
end
