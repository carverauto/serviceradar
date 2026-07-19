defmodule ServiceRadar.EventWriter.FlowEnrichment do
  @moduledoc """
  Ingestion-time enrichment for OCSF flow rows.

  This module is intentionally deterministic and side-effect light:
  - protocol/tcp/service/direction are pure transforms
  - provider/OUI lookups read from CNPG snapshot tables
  """

  alias Ecto.Adapters.SQL
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.PrefixTags.Store, as: PrefixTagStore
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

    Process.put(@provider_cache_key, %{})

    case Keyword.fetch(opts, :provider_lookup) do
      {:ok, lookup_fun} when is_function(lookup_fun, 1) ->
        Process.put(@provider_lookup_fun_key, lookup_fun)

      :error ->
        Process.put(@active_snapshot_key, fetch_active_snapshot_id())
    end

    try do
      fun.()
    after
      restore_process_value(@provider_cache_key, previous_cache)
      restore_process_value(@provider_lookup_fun_key, previous_lookup_fun)
      restore_process_value(@active_snapshot_key, previous_snapshot)
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

    src_provider = provider_for_ip(src_ip)
    dst_provider = provider_for_ip(dst_ip)

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
      src_hosting_provider: src_provider,
      src_hosting_provider_source: source_for_lookup(src_provider, "cloud_provider_db"),
      dst_hosting_provider: dst_provider,
      dst_hosting_provider_source: source_for_lookup(dst_provider, "cloud_provider_db"),
      src_mac: src_mac,
      dst_mac: dst_mac,
      src_mac_vendor: src_vendor,
      src_mac_vendor_source: source_for_lookup(src_vendor, "ieee_oui"),
      dst_mac_vendor: dst_vendor,
      dst_mac_vendor_source: source_for_lookup(dst_vendor, "ieee_oui")
    }

    Map.merge(base, prefix_tag_fields(src_ip, dst_ip))
  end

  defp source_for_lookup(nil, _), do: "unknown"
  defp source_for_lookup(_val, source), do: source

  @doc """
  Whether prefix-tag enrichment is enabled.

  Controlled by Application env `:prefix_tag_enrichment_enabled` (default false).
  Fail-open: lookup errors yield untagged fields and never raise to the caller.
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
    chain = PrefixTagStore.lookup(ip)
    tags = flatten_tag_chain(chain)
    source = chain_source(chain)

    if tags == [] do
      %{tags: nil, source: nil}
    else
      %{tags: tags, source: source}
    end
  rescue
    e ->
      Logger.debug("FlowEnrichment prefix tag lookup failed",
        ip: ip,
        error: Exception.message(e)
      )

      %{tags: nil, source: nil}
  end

  defp prefix_tag_fields(src_ip, dst_ip) do
    if prefix_tag_enrichment_enabled?() do
      src = prefix_tags_for_ip(src_ip)
      dst = prefix_tags_for_ip(dst_ip)

      %{
        src_prefix_tags: src.tags,
        src_prefix_tags_source: src.source,
        dst_prefix_tags: dst.tags,
        dst_prefix_tags_source: dst.source
      }
    else
      %{}
    end
  end

  defp flatten_tag_chain(chain) when is_list(chain) do
    chain
    |> Enum.flat_map(fn
      %{tags: tags} when is_list(tags) -> tags
      _ -> []
    end)
    |> Enum.reduce({[], MapSet.new()}, fn tag, {acc, seen} ->
      if MapSet.member?(seen, tag) do
        {acc, seen}
      else
        {acc ++ [tag], MapSet.put(seen, tag)}
      end
    end)
    |> elem(0)
  end

  defp chain_source([%{source: source} | _]) when is_binary(source) and source != "", do: source
  defp chain_source([_ | rest]), do: chain_source(rest)
  defp chain_source([]), do: nil

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

  @spec provider_for_ip(String.t() | nil) :: String.t() | nil
  def provider_for_ip(nil), do: nil

  def provider_for_ip(ip) when is_binary(ip) do
    with normalized_ip when is_binary(normalized_ip) <- trim_or_nil(ip),
         {:ok, %Postgrex.INET{} = inet} <- Cidr.dump_to_native(normalized_ip, []) do
      cached_provider_for_inet(inet)
    else
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
        # Test/injection path: bypass the cross-batch ETS cache, honor the injected fun
        # so existing tests that assert exact DB call counts keep working.
        lookup_fun.(inet)

      :__serviceradar_unset__ ->
        # L2: cross-batch ETS cache keyed by {active snapshot_id, "addr/mask"}. The
        # per-batch Process-dict cache (cached_provider_for_inet/1) is L1; this absorbs
        # the cross-batch repeats — the dominant source of the ~186,800 GiST round-trips
        # — including negative (non-cloud -> nil) results. query_provider_for_inet/1
        # already reads @active_snapshot_key and returns nil when it is unset.
        snapshot_id = Process.get(@active_snapshot_key)
        ip_key = provider_cache_key(inet)

        ServiceRadar.EventWriter.ProviderCidrCache.fetch(snapshot_id, ip_key, fn ->
          query_provider_for_inet(inet)
        end)
    end
  end

  defp query_provider_for_inet(%Postgrex.INET{} = inet) do
    case Process.get(@active_snapshot_key) do
      nil ->
        nil

      snapshot_id ->
        query_provider_for_inet(inet, snapshot_id)
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
