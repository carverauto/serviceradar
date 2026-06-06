defmodule ServiceRadar.ReferenceData.ServicePorts do
  @moduledoc """
  IANA service-name registry lookup for TCP/UDP port labels.

  The bundled `services.txt` file is the shared upstream source for flow,
  workload, and UI enrichment. Friendly display overrides preserve existing
  ServiceRadar labels for common ports while the registry provides broad
  fallback coverage.
  """

  @services_path Path.expand("../../../priv/reference_data/services.txt", __DIR__)
  @external_resource @services_path

  @display_overrides %{
    {6, 20} => "FTP Data",
    {6, 21} => "FTP",
    {6, 22} => "SSH",
    {6, 23} => "Telnet",
    {6, 25} => "SMTP",
    {6, 53} => "DNS",
    {6, 80} => "HTTP",
    {6, 110} => "POP3",
    {6, 123} => "NTP",
    {6, 143} => "IMAP",
    {6, 161} => "SNMP",
    {6, 162} => "SNMP Trap",
    {6, 389} => "LDAP",
    {6, 443} => "HTTPS",
    {6, 445} => "SMB",
    {6, 465} => "SMTPS",
    {6, 514} => "Syslog",
    {6, 587} => "Submission",
    {6, 636} => "LDAPS",
    {6, 993} => "IMAPS",
    {6, 995} => "POP3S",
    {6, 1433} => "MSSQL",
    {6, 1521} => "Oracle",
    {6, 2049} => "NFS",
    {6, 2379} => "etcd",
    {6, 2380} => "etcd Peer",
    {6, 3000} => "Grafana",
    {6, 3306} => "MySQL",
    {6, 3389} => "RDP",
    {6, 4222} => "NATS",
    {6, 5432} => "PostgreSQL",
    {6, 5672} => "AMQP",
    {6, 6379} => "Redis",
    {6, 6343} => "sFlow",
    {6, 6443} => "Kubernetes API",
    {6, 8080} => "HTTP Alt",
    {6, 8443} => "HTTPS Alt",
    {6, 9092} => "Kafka",
    {6, 9093} => "Kafka TLS",
    {6, 9200} => "Elasticsearch",
    {6, 9418} => "Git",
    {6, 11_211} => "Memcached",
    {6, 27_017} => "MongoDB",
    {6, 50_051} => "gRPC",
    {17, 53} => "DNS",
    {17, 67} => "DHCP Server",
    {17, 68} => "DHCP Client",
    {17, 69} => "TFTP",
    {17, 123} => "NTP",
    {17, 161} => "SNMP",
    {17, 162} => "SNMP Trap",
    {17, 500} => "IKE",
    {17, 514} => "Syslog",
    {17, 631} => "IPP",
    {17, 1194} => "OpenVPN",
    {17, 2055} => "NetFlow",
    {17, 3478} => "STUN",
    {17, 4739} => "IPFIX",
    {17, 6343} => "sFlow"
  }

  @protocol_numbers %{"tcp" => 6, "udp" => 17}
  fallback_label = fn name ->
    name
    |> String.replace("-", " ")
    |> String.replace("_", " ")
    |> String.upcase()
  end

  @service_entries (for line <- String.split(File.read!(@services_path), "\n"),
                        reduce: %{6 => %{}, 17 => %{}} do
                      entries ->
                        line =
                          line
                          |> String.split("#", parts: 2)
                          |> List.first()
                          |> String.trim()

                        case String.split(line) do
                          [name, port_protocol | _aliases] ->
                            with [port_text, protocol_text] <-
                                   String.split(port_protocol, "/", parts: 2),
                                 {port, ""} <- Integer.parse(port_text),
                                 true <- port > 0 and port <= 65_535,
                                 protocol_num when is_integer(protocol_num) <-
                                   Map.get(@protocol_numbers, protocol_text) do
                              override = Map.get(@display_overrides, {protocol_num, port})

                              entry = %{
                                protocol_num: protocol_num,
                                protocol: protocol_text,
                                port: port,
                                name: name,
                                label: override || fallback_label.(name),
                                source: "iana",
                                label_source: if(override, do: "serviceradar", else: "iana")
                              }

                              update_in(entries, [protocol_num], &Map.put_new(&1, port, entry))
                            else
                              _ -> entries
                            end

                          _ ->
                            entries
                        end
                    end)

  @type lookup_result :: %{
          protocol_num: integer(),
          protocol: String.t(),
          port: integer(),
          name: String.t(),
          label: String.t(),
          source: String.t(),
          label_source: String.t()
        }

  @type protocol_ref :: integer() | String.t() | atom() | nil

  @doc """
  Looks up a registered service by IANA protocol number/name and port.

  Returns structured metadata so flow ingestion, workload identity, and UI code
  can share the same registry without parsing display labels.
  """
  @spec lookup(protocol_ref(), integer() | nil) :: lookup_result() | nil
  def lookup(protocol, port) when is_integer(port) and port > 0 and port <= 65_535 do
    with protocol_num when is_integer(protocol_num) <- normalize_protocol(protocol) do
      @service_entries
      |> Map.get(protocol_num, %{})
      |> Map.get(port)
    end
  end

  def lookup(_, _), do: nil

  @doc """
  Looks up a registered service when the protocol is unknown.

  TCP wins over UDP for ambiguous ports because most UI-only call sites use this
  as a best-effort label for tables where protocol is not available.
  """
  @spec lookup(integer() | nil) :: lookup_result() | nil
  def lookup(port) when is_integer(port) and port > 0 and port <= 65_535 do
    lookup(6, port) || lookup(17, port)
  end

  def lookup(_), do: nil

  @spec label(protocol_ref(), integer() | nil) :: String.t() | nil
  def label(protocol, port), do: protocol |> lookup(port) |> label_from_lookup()

  @spec label(integer() | nil) :: String.t() | nil
  def label(port), do: port |> lookup() |> label_from_lookup()

  @spec registered?(protocol_ref(), integer() | nil) :: boolean()
  def registered?(protocol, port), do: not is_nil(lookup(protocol, port))

  defp normalize_protocol(protocol) when protocol in [6, 17], do: protocol

  defp normalize_protocol(protocol) when is_binary(protocol) do
    protocol
    |> String.trim()
    |> String.downcase()
    |> case do
      "6" -> 6
      "tcp" -> 6
      "17" -> 17
      "udp" -> 17
      _ -> nil
    end
  end

  defp normalize_protocol(protocol) when is_atom(protocol) do
    protocol
    |> Atom.to_string()
    |> normalize_protocol()
  end

  defp normalize_protocol(_), do: nil

  defp label_from_lookup(%{label: label}), do: label
  defp label_from_lookup(_), do: nil
end
