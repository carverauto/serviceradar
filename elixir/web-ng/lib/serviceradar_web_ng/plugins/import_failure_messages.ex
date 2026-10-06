defmodule ServiceRadarWebNG.Plugins.ImportFailureMessages do
  @moduledoc """
  Maps first-party plugin import failures to specific, actionable messages.

  The batch summary and the single-plugin import previously flattened every
  non-atom error to "import was rejected", which hid the real cause: an
  egress proxy rejecting the registry connection reads exactly like a
  signature failure. The transport errors carry enough shape to say what
  failed and where; this module is the one place that vocabulary is
  translated, and it never includes secret material (token values, query
  strings) -- only the failure class and the host it applies to.
  """

  alias ServiceRadarWebNG.Plugins.FirstPartyReleaseClient

  @plugin_registry_host FirstPartyReleaseClient.oci_registry()

  @doc """
  Renders an import failure reason as operator-facing text.

  Unknown reasons fall back to `"import was rejected"`, the previous
  behavior, rather than leaking an inspected term.
  """
  @spec reason_to_text(term()) :: String.t()
  def reason_to_text(reason)

  # :httpc's CONNECT-tunnel rejection. A 407 is the egress proxy's ACL
  # refusing the destination, not the destination refusing us: the remedy is
  # allowing the host in the proxy policy, so say both halves.
  def reason_to_text({:could_not_establish_ssl_tunnel, {_proto, 407, _phrase}}) do
    "egress proxy rejected the connection to #{@plugin_registry_host} (HTTP 407) - " <>
      "allow the plugin registry host in the egress proxy ACL"
  end

  def reason_to_text({:could_not_establish_ssl_tunnel, {_proto, status, phrase}}) when is_integer(status) do
    "egress proxy rejected the CONNECT tunnel (HTTP #{status}#{proxy_phrase(phrase)})"
  end

  # Registry auth: 401/403 from the OCI token or manifest endpoints is a
  # credential problem, not a transport problem.
  def reason_to_text({:oci_token_http_error, status}) when status in [401, 403],
    do: "plugin registry rejected the credentials (HTTP #{status})"

  def reason_to_text({:oci_manifest_http_error, status}) when status in [401, 403],
    do: "plugin registry rejected the credentials (HTTP #{status})"

  def reason_to_text({:oci_token_http_error, status}), do: "plugin registry token endpoint returned HTTP #{status}"

  def reason_to_text({:oci_manifest_http_error, status}), do: "plugin registry returned HTTP #{status} for the manifest"

  def reason_to_text({:artifact_http_error, status}), do: "plugin artifact download returned HTTP #{status}"

  def reason_to_text(:untrusted_oci_registry), do: "plugin registry is not trusted for this source"

  # EgressClient normalizes :httpc connect failures to Req.TransportError with
  # the underlying reason atom; raw atoms arrive from httpc and Req paths.
  def reason_to_text(%Req.TransportError{reason: reason}), do: transport_reason(reason)

  def reason_to_text({:failed_connect, info}) when is_list(info) do
    # Match EgressClient's normalization: the trailing {family, options, reason}
    # tuple carries the connect reason.
    case List.last(info) do
      {_family, _options, reason} when is_atom(reason) -> transport_reason(reason)
      _ -> "import was rejected"
    end
  end

  def reason_to_text(reason) when is_atom(reason), do: transport_reason(reason)

  def reason_to_text(reason) when is_binary(reason), do: reason

  def reason_to_text(_reason), do: "import was rejected"

  defp transport_reason(:timeout), do: "connection to the plugin host timed out"
  defp transport_reason(:connect_timeout), do: "connection to the plugin host timed out"
  defp transport_reason(:econnrefused), do: "connection to the plugin host was refused"
  defp transport_reason(:nxdomain), do: "DNS lookup for the plugin host failed"

  defp transport_reason({:tls_alert, alert}) when is_atom(alert) or is_binary(alert),
    do: "TLS connection to the plugin host failed (#{alert})"

  defp transport_reason(:tls_alert), do: "TLS connection to the plugin host failed"
  defp transport_reason(:certificate_expired), do: "TLS certificate for the plugin host expired"
  defp transport_reason(:handshake_failure), do: "TLS handshake with the plugin host failed"

  defp transport_reason(reason) when is_atom(reason) do
    reason
    |> Atom.to_string()
    |> String.replace("_", " ")
  end

  defp transport_reason(_reason), do: "import was rejected"

  # The proxy's phrase is operator-controlled proxy text; keep it but bounded.
  defp proxy_phrase(phrase) when is_list(phrase) or is_binary(phrase), do: ": #{phrase}"

  defp proxy_phrase(_), do: ""
end
