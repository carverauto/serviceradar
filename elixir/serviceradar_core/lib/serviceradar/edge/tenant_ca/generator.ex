defmodule ServiceRadar.Edge.TenantCA.Generator do
  @moduledoc """
  X.509 certificate generation for per-tenant CAs and edge components.

  Uses Erlang's `:public_key` module for certificate operations.
  All certificates are signed by the platform root CA or tenant intermediate CA.

  ## Certificate Types

  1. **Tenant Intermediate CA**: Long-lived (10 years), signs edge component certs
  2. **Edge Component Cert**: Short-lived (1 year), used by pollers/agents/checkers

  ## Certificate CN Format

  - Tenant CA: `tenant-<slug>.ca.serviceradar`
  - Edge Component: `<component-id>.<partition-id>.<tenant-slug>.serviceradar`

  ## Configuration

  Configure the root CA in your application:

      config :serviceradar_core, :root_ca,
        cert_file: "/etc/serviceradar/certs/root.pem",
        key_file: "/etc/serviceradar/certs/root-key.pem"
  """

  require Logger

  @type pem :: String.t()
  @type ca_data :: %{
          certificate_pem: pem(),
          private_key_pem: pem(),
          spki_sha256: String.t(),
          serial_number: String.t(),
          not_before: DateTime.t(),
          not_after: DateTime.t(),
          subject_cn: String.t()
        }

  @type component_cert_data :: %{
          certificate_pem: pem(),
          private_key_pem: pem(),
          ca_chain_pem: pem(),
          serial_number: String.t(),
          not_before: DateTime.t(),
          not_after: DateTime.t(),
          subject_cn: String.t(),
          spiffe_id: String.t()
        }

  # OIDs
  @oid_basic_constraints {2, 5, 29, 19}
  @oid_key_usage {2, 5, 29, 15}
  @oid_ext_key_usage {2, 5, 29, 37}
  @oid_subject_alt_name {2, 5, 29, 17}
  @oid_subject_key_id {2, 5, 29, 14}

  # Extended Key Usage OIDs
  @oid_server_auth {1, 3, 6, 1, 5, 5, 7, 3, 1}
  @oid_client_auth {1, 3, 6, 1, 5, 5, 7, 3, 2}

  @doc """
  Generates a new intermediate CA for a tenant.

  The CA is signed by the platform root CA and can be used to sign
  edge component certificates for this tenant only.

  ## Options

  - `validity_years` - CA validity in years (default: 10)

  ## Returns

  `{:ok, ca_data}` or `{:error, reason}`
  """
  @spec generate_tenant_ca(String.t(), integer()) :: {:ok, ca_data()} | {:error, term()}
  def generate_tenant_ca(tenant_id, validity_years \\ 10) do
    with {:ok, tenant} <- load_tenant(tenant_id),
         {:ok, {root_cert, root_key}} <- load_root_ca(),
         {:ok, ca_key} <- generate_key(),
         {:ok, serial} <- generate_serial(),
         {:ok, {not_before, not_after}} <- validity_period(validity_years) do
      subject_cn = "tenant-#{tenant.slug}.ca.serviceradar"
      spki_sha256 = spki_sha256(ca_key)

      subject = build_subject(subject_cn)
      issuer = extract_subject(root_cert)

      # Build CA certificate
      tbs_cert = build_ca_tbs_certificate(
        serial,
        issuer,
        subject,
        not_before,
        not_after,
        ca_key
      )

      # Sign with root CA
      {:ok, cert_der} = sign_certificate(tbs_cert, root_key)

      # Encode to PEM
      cert_pem = encode_pem(:Certificate, cert_der)
      key_pem = encode_private_key_pem(ca_key)

      {:ok,
       %{
         certificate_pem: cert_pem,
         private_key_pem: key_pem,
         spki_sha256: spki_sha256,
         serial_number: serial_to_hex(serial),
         not_before: not_before,
         not_after: not_after,
         subject_cn: subject_cn
       }}
    end
  end

  @doc """
  Computes the SHA-256 SPKI hash from a PEM-encoded certificate.
  """
  @spec spki_sha256_from_cert_pem(pem()) :: {:ok, String.t()} | {:error, term()}
  def spki_sha256_from_cert_pem(pem) when is_binary(pem) do
    with {:ok, cert_der} <- decode_pem_cert(pem) do
      spki_sha256_from_cert_der(cert_der)
    else
      _ -> {:error, :invalid_certificate}
    end
  end

  @doc """
  Computes the SHA-256 SPKI hash from a DER-encoded certificate.
  """
  @spec spki_sha256_from_cert_der(binary()) :: {:ok, String.t()} | {:error, term()}
  def spki_sha256_from_cert_der(cert_der) when is_binary(cert_der) do
    case :public_key.pkix_decode_cert(cert_der, :otp) do
      {:OTPCertificate, tbs_cert, _, _} ->
        public_key_info = elem(tbs_cert, 7)
        spki_der = :public_key.der_encode(:OTPSubjectPublicKeyInfo, public_key_info)
        {:ok, :crypto.hash(:sha256, spki_der) |> Base.encode16(case: :lower)}

      _ ->
        {:error, :invalid_certificate}
    end
  end

  @doc """
  Generates an edge component certificate signed by the tenant's CA.

  ## Parameters

  - `tenant_ca` - The TenantCA record (with decrypted private key)
  - `component_id` - Unique identifier for the component
  - `component_type` - :poller, :agent, :checker, or :sync
  - `partition_id` - Network partition identifier
  - `opts` - Additional options

  ## Options

  - `validity_days` - Certificate validity in days (default: 365)
  - `dns_names` - Additional DNS SANs

  ## Returns

  `{:ok, component_cert_data}` or `{:error, reason}`
  """
  @spec generate_component_cert(
          map(),
          String.t(),
          atom(),
          String.t(),
          keyword()
        ) :: {:ok, component_cert_data()} | {:error, term()}
  def generate_component_cert(tenant_ca, component_id, component_type, partition_id, opts \\ []) do
    validity_days = Keyword.get(opts, :validity_days, 365)
    extra_dns = Keyword.get(opts, :dns_names, [])

    with {:ok, tenant} <- load_tenant(tenant_ca.tenant_id),
         {:ok, ca_cert} <- decode_pem_cert(tenant_ca.certificate_pem),
         {:ok, ca_key} <- decode_pem_key(tenant_ca.private_key_pem),
         {:ok, component_key} <- generate_key(),
         {:ok, serial} <- generate_serial(),
         {:ok, {not_before, not_after}} <- validity_period_days(validity_days) do
      # Build CN and SPIFFE ID
      subject_cn = "#{component_id}.#{partition_id}.#{tenant.slug}.serviceradar"
      spiffe_id = "spiffe://serviceradar.local/#{component_type}/#{tenant.slug}/#{partition_id}/#{component_id}"

      subject = build_subject(subject_cn)
      issuer = extract_subject(ca_cert)

      # DNS names for the component
      dns_names = [
        subject_cn,
        "#{component_id}.serviceradar",
        "localhost"
      ] ++ extra_dns

      # Build component certificate
      tbs_cert = build_component_tbs_certificate(
        serial,
        issuer,
        subject,
        not_before,
        not_after,
        component_key,
        dns_names,
        spiffe_id
      )

      # Sign with tenant CA
      {:ok, cert_der} = sign_certificate(tbs_cert, ca_key)

      # Encode to PEM
      cert_pem = encode_pem(:Certificate, cert_der)
      key_pem = encode_private_key_pem(component_key)

      # Build CA chain (component cert + tenant CA)
      ca_chain_pem = cert_pem <> "\n" <> tenant_ca.certificate_pem

      {:ok,
       %{
         certificate_pem: cert_pem,
         private_key_pem: key_pem,
         ca_chain_pem: ca_chain_pem,
         serial_number: serial_to_hex(serial),
         not_before: not_before,
         not_after: not_after,
         subject_cn: subject_cn,
         spiffe_id: spiffe_id
       }}
    end
  end

  @doc """
  Extracts tenant information from a certificate CN.

  ## Examples

      iex> extract_tenant_from_cn("poller-001.partition-1.acme-corp.serviceradar")
      {:ok, %{component_id: "poller-001", partition_id: "partition-1", tenant_slug: "acme-corp"}}

      iex> extract_tenant_from_cn("invalid-cn")
      {:error, :invalid_cn_format}
  """
  @spec extract_tenant_from_cn(String.t()) :: {:ok, map()} | {:error, :invalid_cn_format}
  def extract_tenant_from_cn(cn) do
    case String.split(cn, ".") do
      [component_id, partition_id, tenant_slug, "serviceradar"] ->
        {:ok,
         %{
           component_id: component_id,
           partition_id: partition_id,
           tenant_slug: tenant_slug
         }}

      _ ->
        {:error, :invalid_cn_format}
    end
  end

  @doc """
  Extracts the CN from a DER-encoded certificate.
  """
  @spec extract_cn_from_cert(binary()) :: {:ok, String.t()} | {:error, term()}
  def extract_cn_from_cert(cert_der) when is_binary(cert_der) do
    case :public_key.pkix_decode_cert(cert_der, :otp) do
      {:OTPCertificate, tbs_cert, _, _} ->
        extract_cn_from_tbs(tbs_cert)

      _ ->
        {:error, :invalid_certificate}
    end
  end

  # Private functions

  defp load_tenant(tenant_id) do
    case Ash.get(ServiceRadar.Identity.Tenant, tenant_id, authorize?: false) do
      {:ok, tenant} -> {:ok, tenant}
      {:error, _} -> {:error, :tenant_not_found}
    end
  end

  defp load_root_ca do
    config = Application.get_env(:serviceradar_core, :root_ca, [])
    cert_file = Keyword.get(config, :cert_file, "/etc/serviceradar/certs/root.pem")
    key_file = Keyword.get(config, :key_file, "/etc/serviceradar/certs/root-key.pem")

    with {:ok, cert_pem} <- File.read(cert_file),
         {:ok, key_pem} <- File.read(key_file),
         {:ok, cert} <- decode_pem_cert(cert_pem),
         {:ok, key} <- decode_pem_key(key_pem) do
      {:ok, {cert, key}}
    else
      {:error, :enoent} -> {:error, :root_ca_not_found}
      error -> error
    end
  end

  defp generate_key do
    # Generate RSA 2048-bit key
    key = :public_key.generate_key({:rsa, 2048, 65537})
    {:ok, key}
  rescue
    e -> {:error, {:key_generation_failed, e}}
  end

  defp generate_serial do
    # Generate a random 128-bit serial number
    bytes = :crypto.strong_rand_bytes(16)
    serial = :binary.decode_unsigned(bytes)
    {:ok, serial}
  end

  defp validity_period(years) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    not_before = DateTime.add(now, -60, :second)  # Allow 1 minute clock skew
    not_after = DateTime.add(now, years * 365 * 24 * 60 * 60, :second)
    {:ok, {not_before, not_after}}
  end

  defp validity_period_days(days) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    not_before = DateTime.add(now, -60, :second)
    not_after = DateTime.add(now, days * 24 * 60 * 60, :second)
    {:ok, {not_before, not_after}}
  end

  defp build_subject(cn) do
    {:rdnSequence,
     [
       [{:AttributeTypeAndValue, {2, 5, 4, 6}, {:printableString, ~c"US"}}],
       [{:AttributeTypeAndValue, {2, 5, 4, 8}, {:utf8String, "California"}}],
       [{:AttributeTypeAndValue, {2, 5, 4, 10}, {:utf8String, "ServiceRadar"}}],
       [{:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, cn}}]
     ]}
  end

  defp extract_subject({:OTPCertificate, tbs_cert, _, _}) do
    elem(tbs_cert, 6)
  end

  defp extract_subject(cert_der) when is_binary(cert_der) do
    case :public_key.pkix_decode_cert(cert_der, :otp) do
      {:OTPCertificate, tbs_cert, _, _} -> elem(tbs_cert, 6)
      _ -> nil
    end
  end

  defp extract_cn_from_tbs(tbs_cert) do
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

        if cn, do: {:ok, cn}, else: {:error, :cn_not_found}

      _ ->
        {:error, :invalid_subject}
    end
  end

  defp build_ca_tbs_certificate(serial, issuer, subject, not_before, not_after, public_key) do
    public_key_info = extract_public_key_info(public_key)

    extensions = [
      # Basic Constraints: CA=true
      {:Extension, @oid_basic_constraints, true, {:BasicConstraints, true, 0}},
      # Key Usage: keyCertSign, cRLSign
      {:Extension, @oid_key_usage, true, [:keyCertSign, :cRLSign]},
      # Subject Key Identifier
      {:Extension, @oid_subject_key_id, false, compute_key_id(public_key)}
    ]

    {:OTPTBSCertificate,
     :v3,
     serial,
     signature_algorithm(),
     issuer,
     validity(not_before, not_after),
     subject,
     public_key_info,
     :asn1_NOVALUE,
     :asn1_NOVALUE,
     extensions}
  end

  defp build_component_tbs_certificate(
         serial,
         issuer,
         subject,
         not_before,
         not_after,
         public_key,
         dns_names,
         spiffe_id
       ) do
    public_key_info = extract_public_key_info(public_key)

    # Build SAN extension with DNS names and SPIFFE URI
    san_values =
      Enum.map(dns_names, fn dns -> {:dNSName, String.to_charlist(dns)} end) ++
        [{:uniformResourceIdentifier, String.to_charlist(spiffe_id)}]

    extensions = [
      # Basic Constraints: CA=false
      {:Extension, @oid_basic_constraints, true, {:BasicConstraints, false, :asn1_NOVALUE}},
      # Key Usage: digitalSignature, keyEncipherment
      {:Extension, @oid_key_usage, true, [:digitalSignature, :keyEncipherment]},
      # Extended Key Usage: serverAuth, clientAuth
      {:Extension, @oid_ext_key_usage, false, [@oid_server_auth, @oid_client_auth]},
      # Subject Alternative Name
      {:Extension, @oid_subject_alt_name, false, san_values},
      # Subject Key Identifier
      {:Extension, @oid_subject_key_id, false, compute_key_id(public_key)}
    ]

    {:OTPTBSCertificate,
     :v3,
     serial,
     signature_algorithm(),
     issuer,
     validity(not_before, not_after),
     subject,
     public_key_info,
     :asn1_NOVALUE,
     :asn1_NOVALUE,
     extensions}
  end

  defp signature_algorithm do
    {:SignatureAlgorithm, {1, 2, 840, 113549, 1, 1, 11}, :NULL}
  end

  defp validity(not_before, not_after) do
    {:Validity,
     datetime_to_asn1(not_before),
     datetime_to_asn1(not_after)}
  end

  defp datetime_to_asn1(%DateTime{} = dt) do
    # Use generalTime for dates >= 2050, utcTime otherwise
    if dt.year >= 2050 do
      str = Calendar.strftime(dt, "%Y%m%d%H%M%SZ")
      {:generalTime, String.to_charlist(str)}
    else
      str = Calendar.strftime(dt, "%y%m%d%H%M%SZ")
      {:utcTime, String.to_charlist(str)}
    end
  end

  defp extract_public_key_info({:RSAPrivateKey, _, modulus, public_exp, _, _, _, _, _, _, _}) do
    public_key = {:RSAPublicKey, modulus, public_exp}
    public_key_der = :public_key.der_encode(:RSAPublicKey, public_key)

    {:OTPSubjectPublicKeyInfo,
     {:PublicKeyAlgorithm, {1, 2, 840, 113549, 1, 1, 1}, :NULL},
     public_key_der}
  end

  defp compute_key_id({:RSAPrivateKey, _, modulus, public_exp, _, _, _, _, _, _, _}) do
    public_key = {:RSAPublicKey, modulus, public_exp}
    public_key_der = :public_key.der_encode(:RSAPublicKey, public_key)
    :crypto.hash(:sha, public_key_der)
  end

  defp spki_sha256({:RSAPrivateKey, _, _, _, _, _, _, _, _, _, _} = private_key) do
    public_key_info = extract_public_key_info(private_key)
    spki_der = :public_key.der_encode(:OTPSubjectPublicKeyInfo, public_key_info)
    :crypto.hash(:sha256, spki_der) |> Base.encode16(case: :lower)
  end

  defp sign_certificate(tbs_cert, private_key) do
    # Encode TBS certificate to DER
    tbs_der = :public_key.der_encode(:OTPTBSCertificate, tbs_cert)

    # Sign with SHA-256 RSA
    signature = :public_key.sign(tbs_der, :sha256, private_key)

    # Build complete certificate
    cert = {:OTPCertificate, tbs_cert, signature_algorithm(), signature}
    cert_der = :public_key.der_encode(:OTPCertificate, cert)

    {:ok, cert_der}
  rescue
    e -> {:error, {:signing_failed, e}}
  end

  defp decode_pem_cert(pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, _}] ->
        {:ok, der}

      [] ->
        {:error, :no_certificate_in_pem}

      _ ->
        {:error, :invalid_pem}
    end
  end

  defp decode_pem_key(pem) do
    case :public_key.pem_decode(pem) do
      [{type, der, :not_encrypted}] when type in [:RSAPrivateKey, :PrivateKeyInfo] ->
        key = :public_key.der_decode(type, der)
        {:ok, key}

      [{_type, _der, _encryption}] ->
        {:error, :encrypted_key_not_supported}

      [] ->
        {:error, :no_key_in_pem}

      _ ->
        {:error, :invalid_pem}
    end
  end

  defp encode_pem(type, der) do
    :public_key.pem_encode([{type, der, :not_encrypted}])
  end

  defp encode_private_key_pem({:RSAPrivateKey, _, _, _, _, _, _, _, _, _, _} = key) do
    der = :public_key.der_encode(:RSAPrivateKey, key)
    :public_key.pem_encode([{:RSAPrivateKey, der, :not_encrypted}])
  end

  defp serial_to_hex(serial) when is_integer(serial) do
    serial
    |> Integer.to_string(16)
    |> String.downcase()
  end
end
