defmodule ServiceRadarAgentGateway.ComponentIdentityResolver do
  @moduledoc """
  Extracts component identity from mTLS client certificates.

  Each deployment has its own agent-gateway instance. This module extracts
  component identity (component_id, partition_id, component_type) from certificates
  without any additional deployment metadata.

  ## Certificate CN Format

  Edge component certificates use the format:
  `<component_id>.<partition_id>.serviceradar`

  We extract `component_id` and `partition_id` from the CN.

  ## SPIFFE ID Format

  `resolve_from_cert/1` extracts the component type from the SPIFFE URI SAN:
  `spiffe://serviceradar.local/<component_type>/<partition_id>/<component_id>`

  `resolve_edge_identity/3` does not require one: it admits a certificate in an expected edge
  role, derives installation trust from the deployment CA, and only conflict-checks a SPIFFE id
  that is present (see its documentation).
  """

  alias ServiceRadar.Edge.PublicationIdentity
  alias ServiceRadarAgentGateway.AgentCertificateRevocation
  alias ServiceRadarAgentGateway.Config

  require Logger

  @spiffe_trust_domain "serviceradar.local"

  @type component_identity :: %{
          component_id: String.t(),
          partition_id: String.t(),
          component_type: atom() | nil,
          certificate_fingerprint: String.t(),
          serial_number: integer()
        }

  @type edge_identity :: %{
          component_id: String.t(),
          partition_id: String.t(),
          component_type: atom(),
          certificate_fingerprint: String.t(),
          serial_number: integer(),
          installation_trust_id: String.t(),
          gateway_id: String.t(),
          spiffe_id: String.t() | nil
        }

  @doc """
  The canonical deployment-CA/certificate-subject EDGE identity for a client certificate
  (unify-sweep-results-proto task 3.2), admitted in the edge role `expected_type`.

  Unlike `resolve_from_cert/1`, SPIFFE is NOT required. Identity comes from two things every
  deployment-issued edge certificate has:

    * INSTALLATION TRUST -- the leaf must validate directly against one of this installation's
      deployment CA certificates (`:edge_deployment_ca_file`, defaulting to the edge listener's
      `root.pem`). `installation_trust_id` is the lowercase hex SHA-256 of that CA's DER
      `SubjectPublicKeyInfo`, the same issuer-key identity the connectivity spec derives trust
      from. The TLS handshake already verified the chain; repeating the check here binds the
      identity to the deployment CA rather than to whatever the listener happened to trust.
    * SUBJECT -- the CN `<component_id>.<partition_id>.serviceradar`. The component id is the
      authenticated agent principal and MUST satisfy the frozen principal encoding
      (`PublicationIdentity.valid_authenticated_principal?/1`), because it becomes the edge slot's
      `authenticated_agent_id`. The partition id is the partition authority; the gateway itself
      serves every partition and records its own `gateway_id`.

  A SPIFFE URI SAN is optional compatibility metadata. When present it MUST agree exactly --
  `spiffe://serviceradar.local/<expected_type>/<partition_id>/<component_id>` -- or the identity is
  refused as `{:identity_conflict, :spiffe}`: a certificate whose SPIFFE role is some other
  component type (or that carries more than one SPIFFE id) is an authenticated principal in the
  wrong role, not an agent.

  NETWORK SCOPE authority is derived from the principal this resolves. The certificate subject
  names no scope, so the gateway's local trust snapshot binds each authenticated `component_id` to
  the network scopes it is assigned
  (`ServiceRadarAgentGateway.EdgeRecordTrust.with_network_scopes/2`), and
  `ServiceRadarAgentGateway.EdgeRecordAuthorization` admits a record only into a scope that binding
  lists and its control-plane-signed production grant also names for this exact principal.

  Errors: `{:identity_conflict, reason}` for a certificate that is valid but names a different
  role; any other `{:error, atom}` means the certificate does not authenticate an edge principal
  of this installation (including `:revoked_certificate`).
  """
  @spec resolve_edge_identity(binary(), atom(), keyword()) ::
          {:ok, edge_identity()} | {:error, atom() | {:identity_conflict, atom()}}
  def resolve_edge_identity(cert_der, expected_type, opts \\ [])

  def resolve_edge_identity(cert_der, expected_type, opts) when is_binary(cert_der) and is_atom(expected_type) do
    with {:ok, otp_cert} <- decode_cert(cert_der),
         {:ok, anchors} <- trust_anchors(opts),
         {:ok, installation_trust_id} <- installation_trust(cert_der, anchors),
         {:ok, cn} <- extract_cn(otp_cert),
         {:ok, parsed} <- parse_cn(cn),
         :ok <- edge_principal(parsed),
         {:ok, spiffe_id} <- consistent_spiffe(otp_cert, expected_type, parsed) do
      reject_revoked(%{
        component_id: parsed.component_id,
        partition_id: parsed.partition_id,
        component_type: expected_type,
        certificate_fingerprint: certificate_fingerprint(cert_der),
        serial_number: extract_serial_number(otp_cert),
        installation_trust_id: installation_trust_id,
        gateway_id: Keyword.get_lazy(opts, :gateway_id, &gateway_id/0),
        spiffe_id: spiffe_id
      })
    end
  end

  def resolve_edge_identity(_cert_der, _expected_type, _opts), do: {:error, :invalid_certificate}

  defp trust_anchors(opts) do
    case Keyword.fetch(opts, :trust_anchors) do
      {:ok, anchors} when is_list(anchors) -> {:ok, anchors}
      :error -> read_trust_anchors(deployment_ca_file())
    end
  end

  defp deployment_ca_file do
    Application.get_env(:serviceradar_agent_gateway, :edge_deployment_ca_file) ||
      Path.join(ServiceRadarAgentGateway.Application.edge_cert_dir(), "root.pem")
  end

  defp read_trust_anchors(path) do
    case File.read(path) do
      {:ok, pem} ->
        anchors = for {:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem), do: der
        if anchors == [], do: {:error, :installation_trust_unavailable}, else: {:ok, anchors}

      {:error, reason} ->
        Logger.warning("Edge deployment CA #{path} unreadable: #{inspect(reason)}")
        {:error, :installation_trust_unavailable}
    end
  end

  # The leaf must chain DIRECTLY to a deployment CA. The first anchor that validates names the
  # installation trust.
  defp installation_trust(cert_der, anchors) do
    Enum.find_value(anchors, {:error, :untrusted_installation}, fn anchor_der ->
      case :public_key.pkix_path_validation(anchor_der, [cert_der], []) do
        {:ok, _} -> {:ok, spki_sha256(anchor_der)}
        {:error, _} -> nil
      end
    end)
  rescue
    _ -> {:error, :untrusted_installation}
  end

  defp spki_sha256(cert_der) do
    {:Certificate, tbs, _, _} = :public_key.pkix_decode_cert(cert_der, :plain)
    spki = elem(tbs, 7)

    :SubjectPublicKeyInfo
    |> :public_key.der_encode(spki)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp edge_principal(%{component_id: component_id, partition_id: partition_id}) do
    cond do
      not PublicationIdentity.valid_authenticated_principal?(component_id) -> {:error, :invalid_principal}
      not PublicationIdentity.valid_authenticated_principal?(partition_id) -> {:error, :invalid_partition}
      true -> :ok
    end
  end

  defp consistent_spiffe(otp_cert, expected_type, parsed) do
    expected = "spiffe://#{@spiffe_trust_domain}/#{expected_type}/#{parsed.partition_id}/#{parsed.component_id}"

    case otp_cert |> san_values() |> spiffe_uris() do
      [] -> {:ok, nil}
      [^expected] -> {:ok, expected}
      _conflicting -> {:error, {:identity_conflict, :spiffe}}
    end
  end

  defp san_values({:OTPCertificate, tbs_cert, _, _}) do
    case elem(tbs_cert, 10) do
      extensions when is_list(extensions) ->
        Enum.find_value(extensions, [], fn
          {:Extension, {2, 5, 29, 17}, _, values} when is_list(values) -> values
          _ -> nil
        end)

      _ ->
        []
    end
  end

  # Every URI SAN whose scheme is spiffe, compared case-insensitively on the scheme only: a
  # second-cased `SPIFFE://` id must still count as a SPIFFE claim rather than slip past the check.
  defp spiffe_uris(san_values) do
    for {:uniformResourceIdentifier, uri} <- san_values,
        uri = to_string(uri),
        uri |> String.downcase() |> String.starts_with?("spiffe:"),
        do: uri
  end

  defp gateway_id do
    Config.get(:gateway_id, nil) || Atom.to_string(node())
  end

  @doc """
  Resolves component identity from a DER-encoded client certificate.

  Returns component_id, partition_id, and optionally component_type.
  Does NOT return or use any deployment metadata.
  """
  @spec resolve_from_cert(binary()) :: {:ok, component_identity()} | {:error, atom()}
  def resolve_from_cert(cert_der) when is_binary(cert_der) do
    with {:ok, otp_cert} <- decode_cert(cert_der),
         {:ok, cn} <- extract_cn(otp_cert),
         {:ok, parsed} <- parse_cn(cn) do
      component_type = extract_component_type(otp_cert)

      identity = %{
        component_id: parsed.component_id,
        partition_id: parsed.partition_id,
        component_type: component_type,
        certificate_fingerprint: certificate_fingerprint(cert_der),
        serial_number: extract_serial_number(otp_cert)
      }

      reject_revoked(identity)
    end
  end

  # Decode DER certificate to OTP certificate record
  defp decode_cert(cert_der) do
    case :public_key.pkix_decode_cert(cert_der, :otp) do
      {:OTPCertificate, _, _, _} = cert -> {:ok, cert}
      _ -> {:error, :invalid_certificate}
    end
  end

  # Extract CN from certificate subject
  defp extract_cn({:OTPCertificate, tbs_cert, _, _}) do
    subject = elem(tbs_cert, 6)

    case subject do
      {:rdnSequence, rdns} ->
        cn =
          rdns
          |> List.flatten()
          |> Enum.find_value(fn
            {:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, cn}} -> cn
            {:AttributeTypeAndValue, {2, 5, 4, 3}, {:printableString, cn}} -> List.to_string(cn)
            _ -> nil
          end)

        if cn, do: {:ok, cn}, else: {:error, :no_cn}

      _ ->
        {:error, :invalid_subject}
    end
  end

  # Parse CN format: <component_id>.<partition_id>.serviceradar
  defp parse_cn(cn) do
    case String.split(cn, ".") do
      [component_id, partition_id, "serviceradar"] ->
        {:ok, %{component_id: component_id, partition_id: partition_id}}

      [component_id, partition_id, "serviceradar" | _rest] ->
        # Handle cases like "serviceradar.local" suffix
        {:ok, %{component_id: component_id, partition_id: partition_id}}

      _ ->
        Logger.warning("Invalid certificate CN format: #{cn}")
        {:error, :invalid_cn_format}
    end
  end

  # Extract component_type from SPIFFE URI in certificate extensions
  # Format: spiffe://serviceradar.local/<component_type>/<partition_id>/<component_id>
  defp extract_component_type({:OTPCertificate, tbs_cert, _, _}) do
    extensions =
      case elem(tbs_cert, 10) do
        :asn1_NOVALUE -> []
        nil -> []
        value -> value
      end

    if is_list(extensions) do
      san_extension =
        Enum.find(extensions, fn
          {:Extension, {2, 5, 29, 17}, _, _} -> true
          _ -> false
        end)

      case san_extension do
        {:Extension, _, _, san_values} ->
          extract_component_type_from_san(san_values)

        _ ->
          nil
      end
    else
      Logger.warning("Unexpected certificate extensions value: #{inspect(extensions)}")
      return_nil()
    end
  end

  defp return_nil, do: nil

  defp extract_component_type_from_san(san_values) when is_list(san_values) do
    Enum.find_value(san_values, fn
      {:uniformResourceIdentifier, uri} ->
        parse_spiffe_component_type(to_string(uri))

      _ ->
        nil
    end)
  end

  defp extract_component_type_from_san(_), do: nil

  # Parse SPIFFE URI to extract component type
  # Format: spiffe://serviceradar.local/<component_type>/...
  defp parse_spiffe_component_type(uri) do
    case URI.parse(uri) do
      %URI{scheme: "spiffe", path: "/" <> path} ->
        # String.split/2 always returns at least one element, so First is the leading path
        # segment or "" -- and "" falls through component_type_atom/1's catch-all, which is
        # what the old `when component_type != ""` guard did.
        path
        |> String.split("/")
        |> List.first()
        |> component_type_atom()

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  defp component_type_atom("agent"), do: :agent
  defp component_type_atom("addon"), do: :addon
  defp component_type_atom(_), do: nil

  defp certificate_fingerprint(cert_der) do
    :sha256
    |> :crypto.hash(cert_der)
    |> Base.encode16(case: :lower)
  end

  defp extract_serial_number({:OTPCertificate, tbs_cert, _, _}) do
    elem(tbs_cert, 2)
  end

  defp reject_revoked(identity) do
    if AgentCertificateRevocation.revoked?(identity) do
      Logger.warning(
        "Revoked agent certificate rejected: component_id=#{identity.component_id} reason=#{inspect(AgentCertificateRevocation.revoked_reason(identity))}"
      )

      {:error, :revoked_certificate}
    else
      {:ok, identity}
    end
  end
end
