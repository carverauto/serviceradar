defmodule ServiceRadarAgentGateway.CertIssuer do
  @moduledoc """
  Issues mTLS certificates for edge components using the gateway CA.

  Certificates use the CN format:
    <component_id>.<partition_id>.serviceradar
  """

  require Logger

  @default_cert_dir "/etc/serviceradar/certs"
  @default_validity_days 365
  @max_validity_days 825
  @identity_token_regex ~r/\A[A-Za-z0-9_-]+\z/
  @dns_name_regex ~r/\A(?=.{1,253}\z)[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\z/

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

  def issue_agent_bundle(_, _, _, _), do: {:error, :invalid_identity}

  @doc false
  def default_validity_days, do: @default_validity_days

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
    validity_days = Keyword.get(opts, :validity_days, @default_validity_days)

    cond do
      not is_integer(validity_days) ->
        {:error, :invalid_validity_days}

      validity_days <= 0 ->
        {:error, :invalid_validity_days}

      validity_days > @max_validity_days and Keyword.get(opts, :allow_long_ttl?, false) != true ->
        {:error, :validity_days_exceeds_limit}

      validity_days > @default_validity_days and not long_ttl_approved?(opts) ->
        {:error, :long_ttl_approval_required}

      true ->
        if validity_days > @default_validity_days do
          Logger.warning("[CertIssuer] Issuing long-lived agent certificate: validity_days=#{validity_days}")
        end

        {:ok, validity_days}
    end
  end

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
    if File.exists?(path), do: :ok, else: File.write(path, "01\n")
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
    event = %{
      action: :agent_certificate_issue,
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

  defp audit_severity(validity_days) when validity_days > @default_validity_days, do: :medium
  defp audit_severity(_validity_days), do: :informational

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
