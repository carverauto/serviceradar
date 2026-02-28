defmodule ServiceRadar.EventWriter.FlowEnrichment do
  @moduledoc """
  Ingestion-time enrichment for OCSF flow rows.

  This module is intentionally deterministic and side-effect light:
  - protocol/tcp/service/direction are pure transforms
  - provider/OUI lookups read from CNPG snapshot tables
  """

  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Repo

  require Logger

  @tcp_service_labels %{
    20 => "FTP Data",
    21 => "FTP",
    22 => "SSH",
    23 => "Telnet",
    25 => "SMTP",
    53 => "DNS",
    80 => "HTTP",
    110 => "POP3",
    123 => "NTP",
    143 => "IMAP",
    161 => "SNMP",
    162 => "SNMP Trap",
    389 => "LDAP",
    443 => "HTTPS",
    445 => "SMB",
    465 => "SMTPS",
    514 => "Syslog",
    587 => "Submission",
    636 => "LDAPS",
    993 => "IMAPS",
    995 => "POP3S",
    1433 => "MSSQL",
    1521 => "Oracle",
    2049 => "NFS",
    2379 => "etcd",
    2380 => "etcd Peer",
    3000 => "Grafana",
    3306 => "MySQL",
    3389 => "RDP",
    4222 => "NATS",
    50051 => "gRPC",
    5432 => "PostgreSQL",
    5672 => "AMQP",
    6379 => "Redis",
    6443 => "Kubernetes API",
    8080 => "HTTP Alt",
    8443 => "HTTPS Alt",
    9092 => "Kafka",
    9093 => "Kafka TLS",
    9200 => "Elasticsearch",
    9418 => "Git",
    11211 => "Memcached",
    27017 => "MongoDB"
  }

  @udp_service_labels %{
    53 => "DNS",
    67 => "DHCP Server",
    68 => "DHCP Client",
    69 => "TFTP",
    123 => "NTP",
    161 => "SNMP",
    162 => "SNMP Trap",
    514 => "Syslog",
    631 => "IPP",
    1194 => "OpenVPN",
    2055 => "NetFlow",
    3478 => "STUN",
    4739 => "IPFIX",
    500 => "IKE",
    6343 => "sFlow"
  }

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
  JOIN platform.netflow_provider_dataset_snapshots s ON s.id = c.snapshot_id
  WHERE s.is_active = TRUE
    AND ($1)::inet <<= c.cidr
  ORDER BY masklen(c.cidr) DESC
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

    %{
      protocol_name: protocol_name,
      protocol_source: if(is_integer(protocol_num), do: "iana", else: "unknown"),
      tcp_flags: tcp_flags,
      tcp_flags_labels: tcp_flag_labels,
      tcp_flags_source: if(is_integer(tcp_flags), do: "iana", else: "unknown"),
      dst_service_label: service_label(protocol_num, dst_port),
      dst_service_source: if(is_integer(dst_port), do: "iana", else: "unknown"),
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
  end

  defp source_for_lookup(nil, _), do: "unknown"
  defp source_for_lookup(_val, source), do: source

  @spec decode_tcp_flags(integer() | nil) :: [String.t()]
  def decode_tcp_flags(nil), do: []

  def decode_tcp_flags(flags) when is_integer(flags) and flags >= 0 do
    Enum.reduce(@tcp_flag_bits, [], fn {bit, name}, acc ->
      if Bitwise.band(flags, bit) != 0, do: [name | acc], else: acc
    end)
    |> Enum.reverse()
  end

  def decode_tcp_flags(_), do: []

  @spec service_label(integer() | nil, integer() | nil) :: String.t() | nil
  def service_label(protocol_num, dst_port)
      when is_integer(protocol_num) and is_integer(dst_port) and dst_port > 0 do
    case protocol_num do
      6 -> Map.get(@tcp_service_labels, dst_port)
      17 -> Map.get(@udp_service_labels, dst_port)
      _ -> nil
    end
  end

  def service_label(_, _), do: nil

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
    with {:ok, %{rows: [[provider]]}} <- Ecto.Adapters.SQL.query(Repo, @provider_lookup_sql, [ip]),
         true <- is_binary(provider) and provider != "" do
      provider
    else
      _ -> nil
    end
  rescue
    e ->
      Logger.debug("FlowEnrichment provider lookup failed", ip: ip, error: Exception.message(e))
      nil
  end

  @spec oui_vendor_for_mac(String.t() | nil) :: String.t() | nil
  def oui_vendor_for_mac(nil), do: nil

  def oui_vendor_for_mac(mac) when is_binary(mac) do
    with {:ok, prefix} <- oui_prefix_int(mac),
         {:ok, %{rows: [[org]]}} <- Ecto.Adapters.SQL.query(Repo, @oui_lookup_sql, [prefix]),
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

    if String.length(compact) == 12, do: compact, else: nil
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
