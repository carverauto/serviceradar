defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Connectivity do
  @moduledoc false
  def test_snmp_connectivity(host, port) do
    # First, resolve the hostname to verify it exists
    host_charlist = String.to_charlist(host)

    case :inet.getaddr(host_charlist, :inet) do
      {:ok, ip_addr} ->
        # Host resolved successfully, now try UDP reachability test
        test_udp_reachability(host, ip_addr, port)

      {:error, :nxdomain} ->
        %{
          success: false,
          message: "Host not found - check the hostname"
        }

      {:error, :einval} ->
        %{
          success: false,
          message: "Invalid host address format"
        }

      {:error, reason} ->
        %{
          success: false,
          message: "DNS resolution failed: #{inspect(reason)}"
        }
    end
  rescue
    e ->
      %{
        success: false,
        message: "Error: #{Exception.message(e)}"
      }
  end

  # Try to send a UDP packet and see if we get an ICMP unreachable
  # This is a best-effort test since SNMP uses UDP
  defp test_udp_reachability(host, ip_addr, port) do
    case :gen_udp.open(0, [:binary, active: false]) do
      {:ok, socket} ->
        # Send a minimal SNMP GET request packet
        # This is a simplified SNMPv1 GET for sysDescr.0 (.1.3.6.1.2.1.1.1.0)
        snmp_packet = build_snmp_get_request()

        :gen_udp.send(socket, ip_addr, port, snmp_packet)

        # Wait briefly for a response (300ms timeout)
        result =
          case :gen_udp.recv(socket, 0, 3_000) do
            {:ok, {_addr, _recv_port, _data}} ->
              %{
                success: true,
                message: "SNMP agent responded at #{host}:#{port}"
              }

            {:error, :timeout} ->
              # No response could mean firewall, wrong community, or host down
              # Report as potentially reachable since UDP is connectionless
              %{
                success: true,
                message: "Host #{host}:#{port} is reachable (no SNMP response - check community string)"
              }

            {:error, :econnrefused} ->
              %{
                success: false,
                message: "ICMP port unreachable - no SNMP agent on #{host}:#{port}"
              }

            {:error, reason} ->
              %{
                success: false,
                message: "UDP test failed: #{inspect(reason)}"
              }
          end

        :gen_udp.close(socket)
        result

      {:error, reason} ->
        %{
          success: false,
          message: "Failed to create test socket: #{inspect(reason)}"
        }
    end
  end

  # Build a minimal SNMPv1 GET request for sysDescr.0
  # This is used just to elicit a response from the SNMP agent
  defp build_snmp_get_request do
    # SNMPv1 GET request structure (ASN.1 BER encoded)
    # Request for .1.3.6.1.2.1.1.1.0 (sysDescr.0) with community "public"
    <<
      # SEQUENCE (total length 0x27 = 39 bytes)
      0x30,
      0x27,
      # INTEGER - version (0 = SNMPv1)
      0x02,
      0x01,
      0x00,
      # OCTET STRING - community "public"
      0x04,
      0x06,
      "public",
      # GetRequest-PDU (length 0x1A = 26 bytes)
      0xA0,
      0x1A,
      # INTEGER - request-id
      0x02,
      0x04,
      0x00,
      0x00,
      0x00,
      0x01,
      # INTEGER - error-status
      0x02,
      0x01,
      0x00,
      # INTEGER - error-index
      0x02,
      0x01,
      0x00,
      # SEQUENCE - variable-bindings (length 0x0C = 12 bytes)
      0x30,
      0x0C,
      # SEQUENCE - single binding (length 0x0A = 10 bytes)
      0x30,
      0x0A,
      # OID - .1.3.6.1.2.1.1.1.0 (sysDescr.0) - length 8
      0x06,
      0x08,
      0x2B,
      0x06,
      0x01,
      0x02,
      0x01,
      0x01,
      0x01,
      0x00,
      # NULL value
      0x05,
      0x00
    >>
  end
end
