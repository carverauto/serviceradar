defmodule ServiceRadarAgentGateway.CertIssuer do
  @moduledoc """
  Issues mTLS certificates for edge components using the gateway CA.

  Certificates use the CN format:
    <component_id>.<partition_id>.serviceradar
  """

  alias ServiceRadar.Edge.CertificateLifetimePolicy

  require Logger

  @default_cert_dir "/etc/serviceradar/certs"
  @min_validity_days CertificateLifetimePolicy.min_validity_days()
  @max_validity_days CertificateLifetimePolicy.max_validity_days()
  @identity_token_regex ~r/\A[A-Za-z0-9_-]+\z/
  @dns_name_regex ~r/\A(?=.{1,253}\z)[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\z/
  @oid_cn {2, 5, 4, 3}
  @oid_rsa_encryption {1, 2, 840, 113_549, 1, 1, 1}
  @oid_ec_public_key {1, 2, 840, 10_045, 2, 1}
  @oid_ed25519 {1, 3, 101, 112}
  @oid_secp256r1 {1, 2, 840, 10_045, 3, 1, 7}
  @oid_secp384r1 {1, 3, 132, 0, 34}
  @oid_secp521r1 {1, 3, 132, 0, 35}
  @allowed_ec_curves [@oid_secp256r1, @oid_secp384r1, @oid_secp521r1]
  @oid_extension_request {1, 2, 840, 113_549, 1, 9, 14}
  @oid_subject_alt_name {2, 5, 29, 17}
  @min_rsa_modulus_bits 2048

  @spec issue_agent_bundle(String.t(), String.t(), atom() | String.t(), keyword()) ::
          {:ok, map()} | {:error, atom() | term()}
  def issue_agent_bundle(component_id, partition_id, component_type \\ :agent, opts \\ [])

  def issue_agent_bundle(component_id, partition_id, component_type, opts)
      when is_binary(component_id) and is_binary(partition_id) do
    component_type = normalize_component_type(component_type)

    with :ok <- validate_component_type(component_type),
         :ok <- validate_identity_tokens(component_id, partition_id),
         {:ok, extra_sans} <- extra_sans(component_type, partition_id, opts),
         :ok <- authorize_identity(component_id, partition_id, opts),
         {:ok, validity_days} <- validate_validity_days(opts),
         {:ok, ca_cert, ca_key} <- load_ca_paths(opts) do
      generate_bundle(
        component_id,
        partition_id,
        component_type,
        ca_cert,
        ca_key,
        validity_days,
        Keyword.put(opts, :extra_sans, extra_sans)
      )
    end
  end

  def issue_agent_bundle(_, _, _, _), do: {:error, :invalid_identity}

  @doc """
  Issues a renewed leaf certificate from a verified PKCS#10 DER-encoded CSR.

  Verifies the CSR signature over `CertificationRequestInfo` to prove possession
  of the private key, enforces minimum key strength (RSA >= 2048, ECDSA
  P-256/P-384/P-521, or Ed25519), and validates that any Subject CN or SANs in
  the CSR match the authenticated peer's identity (`component_id`,
  `partition_id`, `component_type`). The resulting certificate's Subject CN and
  SANs are constructed strictly from the server-derived identity.
  """
  @spec issue_from_csr(binary(), String.t(), String.t(), atom() | String.t(), keyword()) ::
          {:ok, map()} | {:error, atom() | term()}
  def issue_from_csr(csr_der, component_id, partition_id, component_type \\ :agent, opts \\ [])

  def issue_from_csr(csr_der, component_id, partition_id, component_type, opts)
      when is_binary(csr_der) and byte_size(csr_der) > 0 and is_binary(component_id) and is_binary(partition_id) do
    component_type = normalize_component_type(component_type)

    with :ok <- validate_component_type(component_type),
         :ok <- validate_identity_tokens(component_id, partition_id),
         {:ok, extra_sans} <- extra_sans(component_type, partition_id, opts),
         :ok <- authorize_identity(component_id, partition_id, opts),
         {:ok, validity_days} <- validate_validity_days(opts),
         :ok <- verify_csr(csr_der, component_id, partition_id, component_type, extra_sans),
         {:ok, ca_cert, ca_key} <- load_ca_paths(opts) do
      sign_csr_certificate(
        csr_der,
        component_id,
        partition_id,
        component_type,
        ca_cert,
        ca_key,
        validity_days,
        Keyword.put(opts, :extra_sans, extra_sans)
      )
    end
  end

  def issue_from_csr(_csr_input, component_id, partition_id, _component_type, _opts)
      when is_binary(component_id) and is_binary(partition_id) do
    {:error, :invalid_csr}
  end

  def issue_from_csr(_, _, _, _, _), do: {:error, :invalid_identity}

  @doc """
  The URI SAN every edge-site NATS leaf client certificate in `partition_id`
  carries. The hub's leafnode listener maps exactly this URI to the platform
  account, so only leaf certificates issued here can bind as leaves.
  """
  @spec nats_leaf_role_uri(String.t()) :: String.t()
  def nats_leaf_role_uri(partition_id), do: "spiffe://serviceradar.local/nats-leaf/#{partition_id}"

  defp extra_sans(:nats_leaf, partition_id, _opts), do: {:ok, ["URI:" <> nats_leaf_role_uri(partition_id)]}

  defp extra_sans(:nats_leaf_server, _partition_id, opts) do
    hosts = ["localhost", "127.0.0.1" | List.wrap(Keyword.get(opts, :server_hosts, []))]

    hosts
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn host, {:ok, acc} ->
      case server_host_san(host) do
        {:ok, san} -> {:cont, {:ok, [san | acc]}}
        :error -> {:halt, {:error, :invalid_server_host}}
      end
    end)
    |> case do
      {:ok, sans} -> {:ok, Enum.reverse(sans)}
      error -> error
    end
  end

  defp extra_sans(_component_type, _partition_id, _opts), do: {:ok, []}

  defp server_host_san(host) when is_binary(host) do
    cond do
      match?({:ok, _}, :inet.parse_strict_address(String.to_charlist(host))) -> {:ok, "IP:" <> host}
      Regex.match?(@dns_name_regex, host) -> {:ok, "DNS:" <> host}
      true -> :error
    end
  end

  defp server_host_san(_host), do: :error

  @doc false
  def default_validity_days, do: CertificateLifetimePolicy.default_validity_days()

  @doc false
  def min_validity_days, do: @min_validity_days

  @doc false
  def max_validity_days, do: @max_validity_days

  defp normalize_component_type(type) when is_atom(type), do: type

  defp normalize_component_type(type) when is_binary(type) do
    value = String.trim(type)

    if value == "" do
      :agent
    else
      try do
        String.to_existing_atom(value)
      rescue
        ArgumentError -> :agent
      end
    end
  end

  defp validate_component_type(type) when type in [:agent, :addon, :nats_leaf, :nats_leaf_server], do: :ok
  defp validate_component_type(_), do: {:error, :unsupported_component_type}

  defp validate_identity_tokens(component_id, partition_id) do
    with :ok <- validate_identity_token(component_id, :invalid_component_id) do
      validate_identity_token(partition_id, :invalid_partition_id)
    end
  end

  defp validate_identity_token(value, error) do
    trimmed = String.trim(value)

    if value == trimmed and byte_size(value) in 1..128 and Regex.match?(@identity_token_regex, value) do
      :ok
    else
      {:error, error}
    end
  end

  defp authorize_identity(component_id, partition_id, opts) do
    with :ok <- authorize_component(component_id, opts) do
      authorize_partition(partition_id, opts)
    end
  end

  defp authorize_component(component_id, opts) do
    authorized_component_id =
      opts
      |> Keyword.get(:authorized_component_id)
      |> normalize_identity_id()

    cond do
      is_nil(authorized_component_id) -> :ok
      authorized_component_id == component_id -> :ok
      true -> {:error, :component_not_authorized}
    end
  end

  defp authorize_partition(partition_id, opts) do
    authorized_partition_id =
      opts
      |> Keyword.get(:authorized_partition_id)
      |> normalize_identity_id()

    cond do
      is_nil(authorized_partition_id) -> :ok
      authorized_partition_id == partition_id -> :ok
      true -> {:error, :partition_not_authorized}
    end
  end

  defp normalize_identity_id(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_identity_id(nil), do: nil
  defp normalize_identity_id(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_identity_id()
  defp normalize_identity_id(_value), do: nil

  defp validate_validity_days(opts) do
    default_days = CertificateLifetimePolicy.default_validity_days()

    validity_days =
      Keyword.get(opts, :validity_days) ||
        Keyword.get(opts, :cert_validity_days, default_days)

    with :ok <- check_validity_bounds(validity_days, opts),
         :ok <- check_long_ttl_approval(validity_days, default_days, opts) do
      if validity_days > default_days do
        Logger.warning("[CertIssuer] Issuing long-lived agent certificate: validity_days=#{validity_days}")
      end

      {:ok, validity_days}
    end
  end

  defp check_validity_bounds(validity_days, _opts) when not is_integer(validity_days) or validity_days <= 0 do
    {:error, :invalid_validity_days}
  end

  defp check_validity_bounds(validity_days, opts) when validity_days < @min_validity_days do
    if Keyword.get(opts, :allow_short_test_lifetime, false) == true do
      :ok
    else
      {:error, {:invalid_certificate_validity_days, validity_days}}
    end
  end

  defp check_validity_bounds(validity_days, _opts) when validity_days > @max_validity_days do
    {:error, :validity_days_exceeds_limit}
  end

  defp check_validity_bounds(_validity_days, _opts), do: :ok

  defp check_long_ttl_approval(validity_days, default_days, opts) when validity_days > default_days do
    if long_ttl_approved?(opts) do
      :ok
    else
      {:error, :long_ttl_approval_required}
    end
  end

  defp check_long_ttl_approval(_validity_days, _default_days, _opts), do: :ok

  defp load_ca_paths(opts) do
    cert_dir = Keyword.get(opts, :cert_dir, System.get_env("GATEWAY_CERT_DIR", @default_cert_dir))

    ca_cert =
      Keyword.get(opts, :ca_cert_file, System.get_env("GATEWAY_CA_CERT_FILE")) ||
        Path.join(cert_dir, "root.pem")

    ca_key =
      Keyword.get(opts, :ca_key_file, System.get_env("GATEWAY_CA_KEY_FILE")) ||
        Path.join(cert_dir, "root-key.pem")

    cond do
      not File.exists?(ca_cert) -> {:error, :ca_not_available}
      not File.exists?(ca_key) -> {:error, :ca_not_available}
      true -> {:ok, ca_cert, ca_key}
    end
  end

  defp long_ttl_approved?(opts) do
    opts
    |> Keyword.get(:long_ttl_approved_by)
    |> admin_or_system_actor?()
  end

  defp admin_or_system_actor?(%{role: role}) when role in [:admin, :system, "admin", "system"], do: true
  defp admin_or_system_actor?(%{"role" => role}) when role in [:admin, :system, "admin", "system"], do: true
  defp admin_or_system_actor?(_actor), do: false

  defp generate_bundle(component_id, partition_id, component_type, ca_cert, ca_key, validity_days, opts) do
    cn = "#{component_id}.#{partition_id}.serviceradar"
    temp_parent_dir = Keyword.get(opts, :temp_parent_dir, System.tmp_dir!())
    temp_dir = create_secure_temp_dir!(temp_parent_dir)

    key_path = Path.join(temp_dir, "component-key.pem")
    csr_path = Path.join(temp_dir, "component.csr")
    cert_path = Path.join(temp_dir, "component.pem")
    ext_path = Path.join(temp_dir, "component.ext")
    serial_path = Path.join(temp_dir, "ca.srl")

    try do
      with :ok <- run_openssl(["genrsa", "-out", key_path, "4096"]),
           :ok <-
             run_openssl([
               "req",
               "-new",
               "-key",
               key_path,
               "-out",
               csr_path,
               "-subj",
               "/CN=#{cn}"
             ]),
           :ok <-
             write_extfile(ext_path, component_type, partition_id, component_id, cn, Keyword.get(opts, :extra_sans, [])),
           :ok <- ensure_serial(serial_path),
           :ok <-
             run_openssl([
               "x509",
               "-req",
               "-in",
               csr_path,
               "-CA",
               ca_cert,
               "-CAkey",
               ca_key,
               "-CAserial",
               serial_path,
               "-out",
               cert_path,
               "-extfile",
               ext_path,
               "-extensions",
               "v3_req",
               "-days",
               Integer.to_string(validity_days),
               "-sha256"
             ]) do
        cert_pem = File.read!(cert_path)
        key_pem = File.read!(key_path)
        ca_chain_pem = File.read!(ca_cert)

        spiffe_id = build_spiffe_id(component_type, partition_id, component_id)
        certificate_fingerprint = certificate_fingerprint(cert_pem)
        predecessor_revocation = revoke_predecessor_certificate(opts)

        emit_issuance_audit(
          opts,
          component_id: component_id,
          component_type: component_type,
          requested_partition_id: partition_id,
          granted_partition_id: partition_id,
          authorized_component_id: normalize_identity_id(Keyword.get(opts, :authorized_component_id)),
          authorized_partition_id: normalize_identity_id(Keyword.get(opts, :authorized_partition_id)),
          validity_days: validity_days,
          long_ttl_approved_by: actor_identifier(Keyword.get(opts, :long_ttl_approved_by)),
          predecessor_certificate_fingerprint: predecessor_revocation.fingerprint,
          predecessor_certificate_serial_number: predecessor_revocation.serial_number,
          predecessor_certificate_revoked: predecessor_revocation.revoked?,
          certificate_fingerprint: certificate_fingerprint,
          cn: cn,
          spiffe_id: spiffe_id
        )

        bundle_pem = build_bundle(cert_pem, key_pem, ca_chain_pem)

        {:ok,
         %{
           bundle_pem: bundle_pem,
           certificate_pem: cert_pem,
           private_key_pem: key_pem,
           ca_chain_pem: ca_chain_pem,
           spiffe_id: spiffe_id,
           cn: cn,
           validity_days: validity_days,
           certificate_fingerprint: certificate_fingerprint
         }}
      end
    rescue
      error ->
        {:error, {:certificate_issue_failed, error}}
    after
      File.rm_rf(temp_dir)
    end
  end

  @doc false
  def create_secure_temp_dir!(parent_dir \\ System.tmp_dir!()) do
    File.mkdir_p!(parent_dir)

    1..16
    |> Enum.reduce_while(nil, fn _, _acc ->
      dir =
        Path.join(
          parent_dir,
          "serviceradar-cert-" <>
            (16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
        )

      case File.mkdir(dir) do
        :ok ->
          :ok = File.chmod(dir, 0o700)
          {:halt, dir}

        {:error, :eexist} ->
          {:cont, nil}

        {:error, reason} ->
          raise "failed to create secure cert temp dir #{inspect(dir)}: #{inspect(reason)}"
      end
    end)
    |> case do
      nil -> raise "failed to allocate secure cert temp dir after repeated attempts"
      dir -> dir
    end
  end

  defp run_openssl(args) do
    {output, status} = System.cmd("openssl", args, stderr_to_stdout: true)

    if status == 0 do
      :ok
    else
      Logger.error("[CertIssuer] openssl failed: #{output}")
      {:error, :openssl_failed}
    end
  end

  defp ensure_serial(path) do
    if File.exists?(path) do
      :ok
    else
      <<_top::1, rest::bitstring-size(127)>> = :crypto.strong_rand_bytes(16)
      serial_hex = Base.encode16(<<0::1, 1::1, elem_bits(rest, 126)::bitstring>>, case: :lower)
      File.write(path, serial_hex <> "\n")
    end
  end

  defp elem_bits(<<bits::bitstring-size(126), _::bitstring>>, 126), do: bits

  defp verify_csr(csr_der, component_id, partition_id, component_type, extra_sans) do
    with {:ok, cert_req_info, sig_algo, signature} <- decode_csr(csr_der),
         {:CertificationRequestInfo, _version, subject, subject_pk_info, attributes} <- cert_req_info,
         {:ok, key_type, pub_key} <- extract_and_validate_csr_public_key(subject_pk_info),
         :ok <- verify_csr_signature(cert_req_info, sig_algo, signature, key_type, pub_key) do
      verify_csr_identity(subject, attributes, component_id, partition_id, component_type, extra_sans)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_csr}
    end
  end

  defp decode_csr(csr_der) do
    case :public_key.der_decode(:CertificationRequest, csr_der) do
      {:CertificationRequest, cert_req_info, sig_algo, signature} ->
        {:ok, cert_req_info, sig_algo, signature}

      _ ->
        {:error, :invalid_csr}
    end
  rescue
    _ -> {:error, :invalid_csr}
  catch
    _, _ -> {:error, :invalid_csr}
  end

  defp extract_and_validate_csr_public_key(
         {:CertificationRequestInfo_subjectPKInfo,
          {:CertificationRequestInfo_subjectPKInfo_algorithm, @oid_rsa_encryption, _params}, pk_der}
       )
       when is_binary(pk_der) do
    case :public_key.der_decode(:RSAPublicKey, pk_der) do
      {:RSAPublicKey, modulus, public_exponent} = rsa_pub
      when is_integer(modulus) and is_integer(public_exponent) ->
        if rsa_modulus_bits(modulus) >= @min_rsa_modulus_bits and public_exponent >= 3 and
             rem(public_exponent, 2) == 1 do
          {:ok, :rsa, rsa_pub}
        else
          {:error, :weak_public_key}
        end

      _ ->
        {:error, :invalid_csr}
    end
  rescue
    _ -> {:error, :invalid_csr}
  catch
    _, _ -> {:error, :invalid_csr}
  end

  defp extract_and_validate_csr_public_key(
         {:CertificationRequestInfo_subjectPKInfo,
          {:CertificationRequestInfo_subjectPKInfo_algorithm, @oid_ec_public_key, {:asn1_OPENTYPE, curve_der}}, pk_der}
       )
       when is_binary(curve_der) and is_binary(pk_der) do
    case :public_key.der_decode(:EcpkParameters, curve_der) do
      {:namedCurve, curve_oid} when curve_oid in @allowed_ec_curves and byte_size(pk_der) >= 33 ->
        {:ok, :ecdsa, {{:ECPoint, pk_der}, {:namedCurve, curve_oid}}}

      {:namedCurve, _unsupported_curve} ->
        {:error, :weak_public_key}

      _ ->
        {:error, :weak_public_key}
    end
  rescue
    _ -> {:error, :invalid_csr}
  catch
    _, _ -> {:error, :invalid_csr}
  end

  defp extract_and_validate_csr_public_key(
         {:CertificationRequestInfo_subjectPKInfo,
          {:CertificationRequestInfo_subjectPKInfo_algorithm, @oid_ed25519, _params}, pk_der}
       )
       when is_binary(pk_der) do
    if byte_size(pk_der) == 32 do
      {:ok, :eddsa, {:ed_pub, :ed25519, pk_der}}
    else
      {:error, :weak_public_key}
    end
  end

  defp extract_and_validate_csr_public_key({:CertificationRequestInfo_subjectPKInfo, _, _}) do
    {:error, :unsupported_public_key}
  end

  defp extract_and_validate_csr_public_key(_), do: {:error, :invalid_csr}

  defp rsa_modulus_bits(modulus) when is_integer(modulus) and modulus > 0 do
    bytes = :binary.encode_unsigned(modulus)
    <<first_byte, rest::binary>> = bytes
    leading_bits(first_byte, 0) + bit_size(rest)
  end

  defp rsa_modulus_bits(_), do: 0

  defp leading_bits(0, acc), do: acc
  defp leading_bits(byte, acc), do: leading_bits(Bitwise.bsr(byte, 1), acc + 1)

  defp verify_csr_signature(
         cert_req_info,
         {:CertificationRequest_signatureAlgorithm, sig_oid, _params},
         signature,
         key_type,
         pub_key
       ) do
    with {:ok, sig_bytes} <- normalize_signature_bytes(signature),
         {:ok, digest} <- resolve_csr_signature_digest(sig_oid, key_type) do
      info_der = :public_key.der_encode(:CertificationRequestInfo, cert_req_info)

      if :public_key.verify(info_der, digest, sig_bytes, pub_key) do
        :ok
      else
        {:error, :invalid_csr_signature}
      end
    end
  rescue
    _ -> {:error, :invalid_csr_signature}
  catch
    _, _ -> {:error, :invalid_csr_signature}
  end

  defp verify_csr_signature(_, _, _, _, _), do: {:error, :invalid_csr_signature}

  defp normalize_signature_bytes(sig) when is_binary(sig) and byte_size(sig) > 0, do: {:ok, sig}
  defp normalize_signature_bytes({0, sig}) when is_binary(sig) and byte_size(sig) > 0, do: {:ok, sig}
  defp normalize_signature_bytes(_), do: {:error, :invalid_csr_signature}

  defp resolve_csr_signature_digest(@oid_ed25519, :eddsa), do: {:ok, :none}

  defp resolve_csr_signature_digest(sig_oid, key_type) do
    case :public_key.pkix_sign_types(sig_oid) do
      {digest, ^key_type} when digest in [:sha256, :sha384, :sha512] ->
        {:ok, digest}

      _ ->
        {:error, :invalid_csr_signature}
    end
  rescue
    _ -> {:error, :invalid_csr_signature}
  end

  defp verify_csr_identity(subject, attributes, component_id, partition_id, component_type, extra_sans) do
    expected_cn = "#{component_id}.#{partition_id}.serviceradar"
    expected_spiffe = build_spiffe_id(component_type, partition_id, component_id)
    allowed_sans = MapSet.new(["URI:" <> expected_spiffe, "DNS:" <> expected_cn | extra_sans])

    with :ok <- verify_csr_subject(subject, expected_cn) do
      verify_csr_attributes(attributes, allowed_sans)
    end
  end

  defp verify_csr_subject({:rdnSequence, rdns}, expected_cn) when is_list(rdns) do
    cn_values =
      rdns
      |> List.flatten()
      |> Enum.flat_map(fn
        {:AttributeTypeAndValue, @oid_cn, raw_value} -> [decode_rdn_value(raw_value)]
        _ -> []
      end)

    cond do
      cn_values == [] ->
        :ok

      cn_values == [expected_cn] ->
        :ok

      true ->
        {:error, :csr_identity_mismatch}
    end
  end

  defp verify_csr_subject(_, _expected_cn), do: {:error, :invalid_csr}

  defp decode_rdn_value({tag, value})
       when tag in [:utf8String, :printableString, :ia5String, :teletexString, :universalString, :bmpString] do
    to_string(value)
  end

  defp decode_rdn_value(value) when is_binary(value) do
    case :public_key.der_decode(:DirectoryString, value) do
      {_tag, chars} -> to_string(chars)
      other -> to_string(other)
    end
  rescue
    _ -> value
  end

  defp decode_rdn_value(value) when is_list(value), do: to_string(value)
  defp decode_rdn_value(_), do: nil

  defp verify_csr_attributes(attributes, allowed_sans) when is_list(attributes) do
    Enum.reduce_while(attributes, :ok, fn
      {:Attribute, @oid_extension_request, values}, :ok when is_list(values) ->
        case verify_extension_request_values(values, allowed_sans) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      {:Attribute, _other_oid, _values}, :ok ->
        {:cont, :ok}

      _, _ ->
        {:halt, {:error, :invalid_csr}}
    end)
  end

  defp verify_csr_attributes(_, _allowed_sans), do: {:error, :invalid_csr}

  defp verify_extension_request_values(values, allowed_sans) do
    Enum.reduce_while(values, :ok, fn
      {:asn1_OPENTYPE, ext_req_der}, :ok when is_binary(ext_req_der) ->
        case decode_and_verify_extensions(ext_req_der, allowed_sans) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      ext_list, :ok when is_list(ext_list) ->
        case verify_decoded_extensions(ext_list, allowed_sans) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      _, _ ->
        {:halt, {:error, :invalid_csr}}
    end)
  end

  defp decode_and_verify_extensions(ext_req_der, allowed_sans) do
    exts = :public_key.der_decode(:ExtensionRequest, ext_req_der)
    verify_decoded_extensions(exts, allowed_sans)
  rescue
    _ -> {:error, :invalid_csr}
  catch
    _, _ -> {:error, :invalid_csr}
  end

  defp verify_decoded_extensions(exts, allowed_sans) when is_list(exts) do
    Enum.reduce_while(exts, :ok, fn
      {:Extension, @oid_subject_alt_name, _critical, san_val}, :ok ->
        case verify_csr_san_extension(san_val, allowed_sans) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      {:Extension, _other_oid, _critical, _val}, :ok ->
        {:cont, :ok}

      _, _ ->
        {:halt, {:error, :invalid_csr}}
    end)
  end

  defp verify_decoded_extensions(_, _allowed_sans), do: {:error, :invalid_csr}

  defp verify_csr_san_extension(san_val, allowed_sans) do
    sans =
      if is_binary(san_val) do
        :public_key.der_decode(:SubjectAltName, san_val)
      else
        san_val
      end

    if is_list(sans) and Enum.all?(sans, &allowed_csr_san_entry?(&1, allowed_sans)) do
      :ok
    else
      {:error, :csr_identity_mismatch}
    end
  rescue
    _ -> {:error, :invalid_csr}
  catch
    _, _ -> {:error, :invalid_csr}
  end

  defp allowed_csr_san_entry?({:uniformResourceIdentifier, uri}, allowed_sans) do
    MapSet.member?(allowed_sans, "URI:" <> to_string(uri))
  end

  defp allowed_csr_san_entry?({:dNSName, dns}, allowed_sans) do
    MapSet.member?(allowed_sans, "DNS:" <> to_string(dns))
  end

  defp allowed_csr_san_entry?({:iPAddress, ip_bytes}, allowed_sans) when is_binary(ip_bytes) do
    case format_ip_san_bytes(ip_bytes) do
      {:ok, ip_str} -> MapSet.member?(allowed_sans, "IP:" <> ip_str)
      :error -> false
    end
  end

  defp allowed_csr_san_entry?(_other, _allowed_sans), do: false

  defp format_ip_san_bytes(<<a, b, c, d>>), do: {:ok, "#{a}.#{b}.#{c}.#{d}"}

  defp format_ip_san_bytes(<<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>) do
    {:ok, {a, b, c, d, e, f, g, h} |> :inet.ntoa() |> to_string()}
  end

  defp format_ip_san_bytes(_), do: :error

  defp sign_csr_certificate(csr_der, component_id, partition_id, component_type, ca_cert, ca_key, validity_days, opts) do
    cn = "#{component_id}.#{partition_id}.serviceradar"
    temp_parent_dir = Keyword.get(opts, :temp_parent_dir, System.tmp_dir!())
    temp_dir = create_secure_temp_dir!(temp_parent_dir)

    csr_path = Path.join(temp_dir, "component.csr")
    cert_path = Path.join(temp_dir, "component.pem")
    ext_path = Path.join(temp_dir, "component.ext")
    serial_path = Path.join(temp_dir, "ca.srl")
    csr_pem = :public_key.pem_encode([{:CertificationRequest, csr_der, :not_encrypted}])

    try do
      with :ok <- File.write(csr_path, csr_pem),
           :ok <-
             write_extfile(ext_path, component_type, partition_id, component_id, cn, Keyword.get(opts, :extra_sans, [])),
           :ok <- ensure_serial(serial_path),
           :ok <- Keyword.get(opts, :before_sign, fn -> :ok end).(),
           :ok <-
             run_openssl([
               "x509",
               "-req",
               "-in",
               csr_path,
               "-CA",
               ca_cert,
               "-CAkey",
               ca_key,
               "-CAserial",
               serial_path,
               "-out",
               cert_path,
               "-subj",
               "/CN=#{cn}",
               "-extfile",
               ext_path,
               "-extensions",
               "v3_req",
               "-days",
               Integer.to_string(validity_days),
               "-sha256"
             ]),
           cert_pem = File.read!(cert_path),
           ca_chain_pem = File.read!(ca_cert),
           {:ok, cert_meta} <- extract_issued_cert_metadata(cert_pem) do
        spiffe_id = build_spiffe_id(component_type, partition_id, component_id)

        predecessor_info = %{
          fingerprint: normalize_fingerprint(Keyword.get(opts, :predecessor_certificate_fingerprint)),
          serial_number: normalize_serial_number(Keyword.get(opts, :predecessor_certificate_serial_number)),
          revoked?: false
        }

        emit_issuance_audit(
          Keyword.put_new(opts, :audit_action, :agent_certificate_renew),
          component_id: component_id,
          component_type: component_type,
          requested_partition_id: partition_id,
          granted_partition_id: partition_id,
          authorized_component_id: normalize_identity_id(Keyword.get(opts, :authorized_component_id)),
          authorized_partition_id: normalize_identity_id(Keyword.get(opts, :authorized_partition_id)),
          validity_days: validity_days,
          long_ttl_approved_by: actor_identifier(Keyword.get(opts, :long_ttl_approved_by)),
          predecessor_certificate_fingerprint: predecessor_info.fingerprint,
          predecessor_certificate_serial_number: predecessor_info.serial_number,
          predecessor_certificate_revoked: predecessor_info.revoked?,
          certificate_fingerprint: cert_meta.certificate_fingerprint,
          serial_number: cert_meta.serial_number,
          not_before_unix: cert_meta.not_before_unix,
          not_after_unix: cert_meta.not_after_unix,
          cn: cn,
          spiffe_id: spiffe_id
        )

        {:ok,
         %{
           certificate_pem: cert_pem,
           ca_chain_pem: ca_chain_pem,
           spiffe_id: spiffe_id,
           cn: cn,
           validity_days: validity_days,
           certificate_fingerprint: cert_meta.certificate_fingerprint,
           serial_number: cert_meta.serial_number,
           serial_number_int: cert_meta.serial_number_int,
           not_before: cert_meta.not_before,
           not_after: cert_meta.not_after,
           not_before_unix: cert_meta.not_before_unix,
           not_after_unix: cert_meta.not_after_unix
         }}
      end
    rescue
      error in GRPC.RPCError ->
        reraise error, __STACKTRACE__

      error ->
        {:error, {:certificate_issue_failed, error}}
    after
      File.rm_rf(temp_dir)
    end
  end

  defp extract_issued_cert_metadata(cert_pem) do
    with {:ok, cert_der} <- decode_first_cert_der(cert_pem),
         {:OTPCertificate, tbs, _, _} <- :public_key.pkix_decode_cert(cert_der, :otp),
         {:OTPTBSCertificate, _, serial_int, _, _, {:Validity, nb_raw, na_raw}, _, _, _, _, _}
         when is_integer(serial_int) <- tbs,
         {:ok, not_before} <- parse_asn1_time(nb_raw),
         {:ok, not_after} <- parse_asn1_time(na_raw) do
      {:ok,
       %{
         certificate_fingerprint: cert_der |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower),
         serial_number: serial_int |> Integer.to_string(16) |> String.downcase(),
         serial_number_int: serial_int,
         not_before: not_before,
         not_after: not_after,
         not_before_unix: DateTime.to_unix(not_before, :second),
         not_after_unix: DateTime.to_unix(not_after, :second)
       }}
    else
      _ -> {:error, :invalid_issued_certificate}
    end
  end

  defp decode_first_cert_der(cert_pem) do
    cert_pem
    |> :public_key.pem_decode()
    |> Enum.find_value(fn
      {:Certificate, der, _} when is_binary(der) -> {:ok, der}
      _ -> nil
    end) || {:error, :invalid_issued_certificate}
  end

  defp parse_asn1_time({:utcTime, time_chars}) do
    case to_string(time_chars) do
      <<yy::binary-size(2), mm::binary-size(2), dd::binary-size(2), hh::binary-size(2), min::binary-size(2),
        ss::binary-size(2), "Z">> ->
        year = String.to_integer(yy)
        full_year = if year >= 50, do: 1900 + year, else: 2000 + year
        build_utc_datetime(full_year, mm, dd, hh, min, ss)

      _ ->
        {:error, :invalid_certificate_validity}
    end
  end

  defp parse_asn1_time({:generalTime, time_chars}) do
    case to_string(time_chars) do
      <<yyyy::binary-size(4), mm::binary-size(2), dd::binary-size(2), hh::binary-size(2), min::binary-size(2),
        ss::binary-size(2), "Z">> ->
        build_utc_datetime(String.to_integer(yyyy), mm, dd, hh, min, ss)

      _ ->
        {:error, :invalid_certificate_validity}
    end
  end

  defp parse_asn1_time(_), do: {:error, :invalid_certificate_validity}

  defp build_utc_datetime(year, mm, dd, hh, min, ss) do
    with {:ok, date} <- Date.new(year, String.to_integer(mm), String.to_integer(dd)),
         {:ok, time} <- Time.new(String.to_integer(hh), String.to_integer(min), String.to_integer(ss)) do
      DateTime.new(date, time, "Etc/UTC")
    else
      _ -> {:error, :invalid_certificate_validity}
    end
  end

  defp build_bundle(cert_pem, key_pem, ca_chain_pem) do
    """
    # Component Certificate
    #{String.trim(cert_pem)}
    # Component Private Key
    #{String.trim(key_pem)}
    # CA Chain
    #{String.trim(ca_chain_pem)}
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp build_spiffe_id(component_type, partition_id, component_id) do
    "spiffe://serviceradar.local/#{component_type}/#{partition_id}/#{component_id}"
  end

  defp certificate_fingerprint(cert_pem) do
    cert_pem
    |> :public_key.pem_decode()
    |> Enum.find_value(fn
      {:Certificate, der, _} -> der
      _ -> nil
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp revoke_predecessor_certificate(opts) do
    revocation_module = Keyword.get(opts, :revocation_module, ServiceRadarAgentGateway.AgentCertificateRevocation)
    fingerprint = normalize_fingerprint(Keyword.get(opts, :predecessor_certificate_fingerprint))
    serial_number = normalize_serial_number(Keyword.get(opts, :predecessor_certificate_serial_number))
    reason = Keyword.get(opts, :predecessor_revocation_reason, "renewed")

    revoked? =
      Enum.any?([
        revoke_predecessor_fingerprint(revocation_module, fingerprint, reason),
        revoke_predecessor_serial_number(revocation_module, serial_number, reason)
      ])

    %{
      fingerprint: fingerprint,
      serial_number: serial_number,
      revoked?: revoked?
    }
  rescue
    error ->
      Logger.warning("[CertIssuer] Predecessor certificate revocation failed: #{inspect(error)}")
      %{fingerprint: nil, serial_number: nil, revoked?: false}
  end

  defp revoke_predecessor_fingerprint(_module, nil, _reason), do: false

  defp revoke_predecessor_fingerprint(module, fingerprint, reason) when is_atom(module) do
    module.revoke_fingerprint(fingerprint, reason: reason)
    true
  end

  defp revoke_predecessor_serial_number(_module, nil, _reason), do: false

  defp revoke_predecessor_serial_number(module, serial_number, reason) when is_atom(module) do
    module.revoke_serial_number(serial_number, reason: reason)
    true
  end

  defp normalize_fingerprint(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()

    cond do
      value == "" -> nil
      Regex.match?(~r/\A(?:sha256:)?[a-z0-9_+\/=:-]{16,256}\z/, value) -> value
      true -> nil
    end
  end

  defp normalize_fingerprint(_value), do: nil

  defp normalize_serial_number(value) when is_integer(value) and value > 0, do: value
  defp normalize_serial_number(_value), do: nil

  defp emit_issuance_audit(opts, details) do
    action = Keyword.get(opts, :audit_action, :agent_certificate_issue)

    event = %{
      action: action,
      resource_type: "agent_certificate",
      resource_id: Keyword.fetch!(details, :component_id),
      resource_name: Keyword.fetch!(details, :cn),
      actor: audit_actor(opts),
      details: Map.new(details),
      severity: audit_severity(Keyword.fetch!(details, :validity_days))
    }

    case Keyword.get(opts, :audit_writer, ServiceRadarAgentGateway.CertIssuanceAudit) do
      writer when is_function(writer, 1) -> writer.(event)
      nil -> :ok
      writer when is_atom(writer) -> writer.write(event)
    end
  rescue
    error ->
      Logger.warning("[CertIssuer] Certificate issuance audit failed: #{inspect(error)}")
      :ok
  end

  defp audit_actor(opts) do
    Keyword.get(opts, :audit_actor) || Keyword.get(opts, :actor) || %{id: "system", email: "system@serviceradar.local"}
  end

  defp actor_identifier(nil), do: nil
  defp actor_identifier(%{id: id}) when not is_nil(id), do: to_string(id)
  defp actor_identifier(%{"id" => id}) when not is_nil(id), do: to_string(id)
  defp actor_identifier(actor) when is_binary(actor), do: actor
  defp actor_identifier(_actor), do: nil

  defp audit_severity(validity_days) do
    if validity_days > CertificateLifetimePolicy.default_validity_days(), do: :medium, else: :informational
  end

  defp write_extfile(path, component_type, partition_id, component_id, cn, extra_sans) do
    spiffe_id = build_spiffe_id(component_type, partition_id, component_id)

    {extra_lines, _counters} =
      Enum.map_reduce(extra_sans, %{"URI" => 1, "DNS" => 1, "IP" => 0}, fn san, counters ->
        [kind, value] = String.split(san, ":", parts: 2)
        index = Map.fetch!(counters, kind) + 1
        {"#{kind}.#{index} = #{value}", Map.put(counters, kind, index)}
      end)

    contents = """
    [ v3_req ]
    subjectAltName = @alt_names

    [ alt_names ]
    URI.1 = #{spiffe_id}
    DNS.1 = #{cn}
    #{Enum.join(extra_lines, "\n")}
    """

    File.write(path, contents)
  end
end
