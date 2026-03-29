defmodule ServiceRadarAgentGateway.CertIssuer do
  @moduledoc """
  Issues mTLS certificates for edge agents using the gateway CA.

  Certificates use the CN format:
    <component_id>.<partition_id>.serviceradar
  """

  require Logger

  @default_cert_dir "/etc/serviceradar/certs"
  @default_validity_days 365

  @spec issue_agent_bundle(String.t(), String.t(), atom() | String.t(), keyword()) ::
          {:ok, map()} | {:error, atom() | term()}
  def issue_agent_bundle(component_id, partition_id, component_type \\ :agent, opts \\ [])

  def issue_agent_bundle(component_id, partition_id, component_type, opts)
      when is_binary(component_id) and is_binary(partition_id) do
    component_type = normalize_component_type(component_type)

    with :ok <- validate_component_type(component_type),
         {:ok, ca_cert, ca_key} <- load_ca_paths(opts) do
      generate_bundle(component_id, partition_id, component_type, ca_cert, ca_key, opts)
    end
  end

  def issue_agent_bundle(_, _, _, _), do: {:error, :invalid_identity}

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

  defp validate_component_type(:agent), do: :ok
  defp validate_component_type(_), do: {:error, :unsupported_component_type}

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

  defp generate_bundle(component_id, partition_id, component_type, ca_cert, ca_key, opts) do
    cn = "#{component_id}.#{partition_id}.serviceradar"
    validity_days = Keyword.get(opts, :validity_days, @default_validity_days)
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
           :ok <- write_extfile(ext_path, component_type, partition_id, component_id, cn),
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

        bundle_pem = build_bundle(cert_pem, key_pem, ca_chain_pem)

        {:ok,
         %{
           bundle_pem: bundle_pem,
           certificate_pem: cert_pem,
           private_key_pem: key_pem,
           ca_chain_pem: ca_chain_pem,
           spiffe_id: build_spiffe_id(component_type, partition_id, component_id),
           cn: cn
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

    Enum.reduce_while(1..16, nil, fn _, _acc ->
      dir =
        Path.join(
          parent_dir,
          "serviceradar-cert-" <>
            (:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false))
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

  defp write_extfile(path, component_type, partition_id, component_id, cn) do
    spiffe_id = build_spiffe_id(component_type, partition_id, component_id)

    contents = """
    [ v3_req ]
    subjectAltName = @alt_names

    [ alt_names ]
    URI.1 = #{spiffe_id}
    DNS.1 = #{cn}
    """

    File.write(path, contents)
  end
end
