defmodule ServiceRadar.Edge.TenantResolver do
  @moduledoc """
  Resolves tenant identity from client certificates.

  When edge components (pollers, agents, checkers) connect to core services,
  their tenant identity is extracted from the mTLS client certificate.

  ## Certificate CN Format

  Edge component certificates use the format:
  `<component_id>.<partition_id>.<tenant_slug>.serviceradar`

  ## SPIFFE ID Format

  Edge component certificates also include a SPIFFE URI SAN:
  `spiffe://serviceradar.local/<component_type>/<tenant_slug>/<partition_id>/<component_id>`

  ## Usage

  ```elixir
  # In a Plug/Phoenix endpoint
  def call(conn, _opts) do
    case TenantResolver.resolve_from_conn(conn) do
      {:ok, %{tenant_slug: slug, component_type: type}} ->
        conn
        |> assign(:tenant_slug, slug)
        |> assign(:component_type, type)

      {:error, error_reason} ->
        conn
        |> send_resp(401, "Unauthorized: \#{error_reason}")
        |> halt()
    end
  end
  ```

  ## Security

  This module provides cryptographic assurance of tenant identity:
  - Certificates are signed by the tenant's intermediate CA
  - The issuer CA SPKI hash is matched to stored tenant CA records
  - The tenant slug in the certificate CN must match the issuer CA's tenant
  - Attackers cannot forge or modify the tenant identity without a valid CA
  """

  require Logger

  @type tenant_info :: %{
          tenant_slug: String.t(),
          component_id: String.t(),
          partition_id: String.t(),
          component_type: atom() | nil,
          spiffe_id: String.t() | nil,
          tenant_id: String.t() | nil,
          tenant_ca_id: String.t() | nil,
          issuer_spki_sha256: String.t() | nil
        }

  @doc """
  Resolves tenant info from a Plug.Conn by extracting the client certificate.

  Returns the tenant slug, component ID, partition ID, and optionally
  the component type and SPIFFE ID.

  ## Options

    * `:issuer_cert_der` - DER-encoded issuer CA certificate (from validated TLS chain)
    * `:issuer_cert_pem` - PEM-encoded issuer CA certificate (from validated TLS chain)

  ## Returns

    * `{:ok, tenant_info}` - Successfully resolved tenant
    * `{:error, :no_client_cert}` - No client certificate presented
    * `{:error, :invalid_cn_format}` - Certificate CN doesn't match expected format
    * `{:error, :tenant_ca_not_found}` - Issuer CA not found in database
    * `{:error, :tenant_slug_mismatch}` - CN tenant does not match issuer CA tenant
    * `{:error, :issuer_cert_missing}` - Issuer cert or SPKI hash not provided
  """
  @spec resolve_from_conn(Plug.Conn.t(), keyword()) :: {:ok, tenant_info()} | {:error, atom()}
  def resolve_from_conn(conn, opts \\ []) do
    case get_client_cert(conn) do
      nil -> {:error, :no_client_cert}
      cert_der -> resolve_from_cert(cert_der, opts)
    end
  end

  @doc """
  Resolves tenant info from a DER-encoded client certificate.
  """
  @spec resolve_from_cert(binary(), keyword()) :: {:ok, tenant_info()} | {:error, atom()}
  def resolve_from_cert(cert_der, opts \\ []) when is_binary(cert_der) do
    if issuer_lookup_opts?(opts) do
      resolve_from_cert_with_issuer(cert_der, opts)
    else
      resolve_from_cert_only(cert_der)
    end
  end

  @doc """
  Resolves tenant info from a DER-encoded client certificate and issuer CA.

  Requires either `:issuer_cert_der` or `:issuer_cert_pem`.
  """
  @spec resolve_from_cert_with_issuer(binary(), keyword()) :: {:ok, tenant_info()} | {:error, atom()}
  def resolve_from_cert_with_issuer(cert_der, opts) when is_binary(cert_der) do
    with {:ok, resolved} <- resolve_from_cert_only(cert_der),
         {:ok, issuer_spki} <- issuer_spki_sha256(opts),
         {:ok, tenant_ca} <- lookup_tenant_ca_by_spki(issuer_spki),
         {:ok, tenant} <- ensure_tenant_loaded(tenant_ca),
         :ok <- validate_tenant_slug(resolved.tenant_slug, tenant.slug) do
      {:ok,
       resolved
       |> Map.put(:tenant_id, tenant.id)
       |> Map.put(:tenant_ca_id, tenant_ca.id)
       |> Map.put(:issuer_spki_sha256, issuer_spki)
       |> Map.put(:tenant_slug, tenant.slug)}
    end
  end

  @doc """
  Resolves tenant info from a PEM-encoded client certificate.
  """
  @spec resolve_from_pem(String.t(), keyword()) :: {:ok, tenant_info()} | {:error, atom()}
  def resolve_from_pem(pem, opts \\ []) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, _} | _] -> resolve_from_cert(der, opts)
      _ -> {:error, :invalid_pem}
    end
  end

  @doc """
  Validates that a client certificate belongs to the expected tenant.

  Use this when you already know the expected tenant and want to verify
  the client is authorized.

  ## Returns

    * `:ok` - Certificate belongs to expected tenant
    * `{:error, :tenant_mismatch}` - Certificate belongs to different tenant
    * `{:error, reason}` - Other validation failure
  """
  @spec validate_tenant(binary(), String.t()) :: :ok | {:error, atom()}
  def validate_tenant(cert_der, expected_tenant_slug) do
    case resolve_from_cert(cert_der) do
      {:ok, %{tenant_slug: ^expected_tenant_slug}} ->
        :ok

      {:ok, %{tenant_slug: actual}} ->
        Logger.warning(
          "Tenant mismatch: expected #{expected_tenant_slug}, got #{actual}"
        )

        {:error, :tenant_mismatch}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Looks up the tenant record from a tenant slug.

  Returns the full Tenant resource if found.
  """
  @spec lookup_tenant(String.t()) :: {:ok, map()} | {:error, :tenant_not_found}
  def lookup_tenant(tenant_slug) do
    case Ash.get(ServiceRadar.Identity.Tenant, %{slug: tenant_slug},
           action: :by_slug,
           authorize?: false
         ) do
      {:ok, tenant} -> {:ok, tenant}
      {:error, _} -> {:error, :tenant_not_found}
    end
  end

  @doc """
  Extracts tenant slug from a CN string without full validation.

  Useful for logging and metrics where you want the tenant slug
  even if validation fails.

  ## Examples

      iex> extract_slug_from_cn("poller-001.partition-1.acme-corp.serviceradar")
      {:ok, "acme-corp"}

      iex> extract_slug_from_cn("invalid")
      :error
  """
  @spec extract_slug_from_cn(String.t()) :: {:ok, String.t()} | :error
  def extract_slug_from_cn(cn) do
    case String.split(cn, ".") do
      [_, _, tenant_slug, "serviceradar"] -> {:ok, tenant_slug}
      _ -> :error
    end
  end

  # Private functions

  defp get_client_cert(conn) do
    # Try to get client cert from Cowboy/Bandit adapter
    case conn.adapter do
      {Plug.Cowboy.Conn, req} ->
        case :cowboy_req.cert(req) do
          :undefined -> nil
          cert -> cert
        end

      {Bandit.Adapter, _} ->
        # Bandit stores peer cert differently
        case Plug.Conn.get_req_header(conn, "x-client-cert") do
          [pem] ->
            case :public_key.pem_decode(pem) do
              [{:Certificate, der, _}] -> der
              _ -> nil
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp decode_cert(cert_der) do
    case :public_key.pkix_decode_cert(cert_der, :otp) do
      {:OTPCertificate, _, _, _} = cert -> {:ok, cert}
      _ -> {:error, :invalid_certificate}
    end
  end

  defp resolve_from_cert_only(cert_der) do
    with {:ok, otp_cert} <- decode_cert(cert_der),
         {:ok, cn} <- extract_cn(otp_cert),
         {:ok, parsed} <- parse_cn(cn) do
      spiffe_info = extract_spiffe_info(otp_cert)

      {:ok,
       %{
         tenant_slug: parsed.tenant_slug,
         component_id: parsed.component_id,
         partition_id: parsed.partition_id,
         component_type: spiffe_info[:component_type],
         spiffe_id: spiffe_info[:spiffe_id],
         tenant_id: nil,
         tenant_ca_id: nil,
         issuer_spki_sha256: nil
       }}
    end
  end

  defp issuer_lookup_opts?(opts) do
    is_binary(opts[:issuer_cert_der]) or
      is_binary(opts[:issuer_cert_pem])
  end

  defp issuer_spki_sha256(opts) do
    cond do
      is_binary(opts[:issuer_cert_der]) ->
        ServiceRadar.Edge.TenantCA.Generator.spki_sha256_from_cert_der(opts[:issuer_cert_der])

      is_binary(opts[:issuer_cert_pem]) ->
        ServiceRadar.Edge.TenantCA.Generator.spki_sha256_from_cert_pem(opts[:issuer_cert_pem])

      true ->
        {:error, :issuer_cert_missing}
    end
  end

  defp lookup_tenant_ca_by_spki(spki_sha256) do
    ServiceRadar.Edge.TenantCA
    |> Ash.Query.for_read(:by_spki, %{spki_sha256: spki_sha256})
    |> Ash.read_one(authorize?: false, load: [:tenant])
    |> case do
      {:ok, %ServiceRadar.Edge.TenantCA{} = tenant_ca} -> {:ok, tenant_ca}
      {:ok, nil} -> {:error, :tenant_ca_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_tenant_loaded(%ServiceRadar.Edge.TenantCA{tenant: %ServiceRadar.Identity.Tenant{} = tenant}) do
    {:ok, tenant}
  end

  defp ensure_tenant_loaded(%ServiceRadar.Edge.TenantCA{}), do: {:error, :tenant_ca_not_found}

  defp validate_tenant_slug(tenant_slug, tenant_slug), do: :ok

  defp validate_tenant_slug(_, _), do: {:error, :tenant_slug_mismatch}

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

  defp parse_cn(cn) do
    case String.split(cn, ".") do
      [component_id, partition_id, tenant_slug, "serviceradar"] ->
        {:ok,
         %{
           component_id: component_id,
           partition_id: partition_id,
           tenant_slug: tenant_slug
         }}

      # Also support CA certificates: tenant-<slug>.ca.serviceradar
      ["tenant-" <> tenant_slug, "ca", "serviceradar"] ->
        {:ok,
         %{
           component_id: "ca",
           partition_id: "platform",
           tenant_slug: tenant_slug
         }}

      _ ->
        {:error, :invalid_cn_format}
    end
  end

  defp extract_spiffe_info({:OTPCertificate, tbs_cert, _, _}) do
    extensions = elem(tbs_cert, 8)

    case find_san_extension(extensions) do
      nil ->
        %{}

      san_values ->
        spiffe_id = find_spiffe_uri(san_values)

        if spiffe_id do
          component_type = parse_component_type_from_spiffe(spiffe_id)
          %{spiffe_id: spiffe_id, component_type: component_type}
        else
          %{}
        end
    end
  end

  defp find_san_extension(extensions) when is_list(extensions) do
    # OID for Subject Alternative Name: 2.5.29.17
    san_oid = {2, 5, 29, 17}

    Enum.find_value(extensions, fn
      {:Extension, ^san_oid, _critical, value} -> value
      _ -> nil
    end)
  end

  defp find_san_extension(_), do: nil

  defp find_spiffe_uri(san_values) when is_list(san_values) do
    Enum.find_value(san_values, fn
      {:uniformResourceIdentifier, uri} when is_list(uri) ->
        uri_str = List.to_string(uri)

        if String.starts_with?(uri_str, "spiffe://") do
          uri_str
        else
          nil
        end

      {:uniformResourceIdentifier, uri} when is_binary(uri) ->
        if String.starts_with?(uri, "spiffe://"), do: uri, else: nil

      _ ->
        nil
    end)
  end

  defp find_spiffe_uri(_), do: nil

  defp parse_component_type_from_spiffe(spiffe_id) do
    # Format: spiffe://serviceradar.local/<component_type>/<tenant_slug>/<partition_id>/<component_id>
    case String.replace_prefix(spiffe_id, "spiffe://", "") |> String.split("/") do
      [_trust_domain, component_type | _] ->
        case component_type do
          "poller" -> :poller
          "agent" -> :agent
          "checker" -> :checker
          "sync" -> :sync
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
