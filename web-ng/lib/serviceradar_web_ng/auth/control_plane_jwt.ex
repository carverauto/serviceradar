defmodule ServiceRadarWebNG.Auth.ControlPlaneJWT do
  @moduledoc """
  JWT validation for tokens issued by the ServiceRadar Control Plane.

  This module validates JWTs that were issued by the SaaS Control Plane
  (serviceradar-web) for authenticating requests to Tenant Instances.

  ## Token Structure

  Control Plane JWTs contain:
    - `sub` - User ID (UUID) or system identifier
    - `tenant_id` - Tenant ID (UUID) this token is authorized for
    - `tenant_slug` - Human-readable tenant slug
    - `role` - One of: admin, operator, viewer, system
    - `component` - Optional system component name (for system tokens)
    - `iss` - Issuer: "serviceradar-control-plane"
    - `aud` - Audience: "serviceradar-tenant-instance"
    - `exp` - Expiration timestamp
    - `iat` - Issued at timestamp
    - `jti` - Unique token ID

  ## Configuration

  Configure the Control Plane public key in your config:

      config :serviceradar_web_ng, ServiceRadarWebNG.Auth.ControlPlaneJWT,
        public_key: "-----BEGIN PUBLIC KEY-----\\n...\\n-----END PUBLIC KEY-----",
        # Or use a file path
        public_key_file: "/path/to/control-plane-public.pem",
        # Or use an environment variable name
        public_key_env: "CONTROL_PLANE_PUBLIC_KEY",
        # Expected issuer (default: "serviceradar-control-plane")
        issuer: "serviceradar-control-plane",
        # Expected audience (default: "serviceradar-tenant-instance")
        audience: "serviceradar-tenant-instance"

  ## Usage

      case ControlPlaneJWT.verify_and_decode(token) do
        {:ok, claims} ->
          # claims contains: tenant_id, user_id, role, etc.
          actor = ControlPlaneJWT.build_actor(claims)

        {:error, :invalid_signature} ->
          # Token signature is invalid

        {:error, :expired} ->
          # Token has expired

        {:error, reason} ->
          # Other validation failure
      end
  """

  require Logger

  @type claims :: %{
          sub: String.t(),
          tenant_id: String.t(),
          tenant_slug: String.t(),
          role: atom(),
          component: String.t() | nil,
          iss: String.t(),
          aud: String.t(),
          exp: integer(),
          iat: integer(),
          jti: String.t()
        }

  @type actor :: %{
          id: String.t(),
          tenant_id: String.t(),
          role: atom(),
          email: String.t() | nil,
          component: String.t() | nil
        }

  @expected_issuer "serviceradar-control-plane"
  @expected_audience "serviceradar-tenant-instance"

  @doc """
  Verify and decode a Control Plane JWT.

  Returns `{:ok, claims}` if the token is valid, or `{:error, reason}` otherwise.

  ## Validation Steps

  1. Decode the JWT header and payload
  2. Verify the signature using the configured public key
  3. Check the issuer matches expected value
  4. Check the audience matches expected value
  5. Check the token has not expired
  6. Extract and normalize claims
  """
  @spec verify_and_decode(String.t()) :: {:ok, claims()} | {:error, atom()}
  def verify_and_decode(token) when is_binary(token) do
    with {:ok, public_key} <- get_public_key(),
         {:ok, {header, payload}} <- decode_token(token),
         :ok <- verify_signature(token, public_key, header),
         {:ok, claims} <- validate_claims(payload) do
      {:ok, claims}
    end
  end

  def verify_and_decode(_), do: {:error, :invalid_token}

  @doc """
  Build an Ash-compatible actor map from JWT claims.

  The returned actor can be used with Ash operations:

      Ash.read!(query, actor: actor, tenant: claims.tenant_id)

  ## Actor Structure

  For user tokens:
      %{
        id: "user-uuid",
        tenant_id: "tenant-uuid",
        role: :admin,  # or :operator, :viewer
        email: nil     # Not included in JWT, must be fetched if needed
      }

  For system tokens:
      %{
        id: "system:component-name",
        tenant_id: "tenant-uuid",
        role: :system,
        component: "component-name"
      }
  """
  @spec build_actor(claims()) :: actor()
  def build_actor(%{role: :system, component: component, tenant_id: tenant_id}) do
    %{
      id: "system:#{component}",
      tenant_id: tenant_id,
      role: :system,
      email: "#{component}@system.serviceradar",
      component: component
    }
  end

  def build_actor(%{sub: user_id, tenant_id: tenant_id, role: role}) do
    %{
      id: user_id,
      tenant_id: tenant_id,
      role: normalize_role(role),
      email: nil,
      component: nil
    }
  end

  @doc """
  Check if a token is a system token (vs a user token).
  """
  @spec system_token?(claims()) :: boolean()
  def system_token?(%{role: :system}), do: true
  def system_token?(%{component: component}) when is_binary(component), do: true
  def system_token?(_), do: false

  @doc """
  Extract the tenant ID from a token without full verification.

  Useful for determining which tenant's schema to use before full validation.
  Note: This does NOT verify the signature - use `verify_and_decode/1` for that.
  """
  @spec peek_tenant_id(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def peek_tenant_id(token) when is_binary(token) do
    case decode_token(token) do
      {:ok, {_header, payload}} ->
        case Map.get(payload, "tenant_id") do
          nil -> {:error, :missing_tenant_id}
          tenant_id -> {:ok, tenant_id}
        end

      error ->
        error
    end
  end

  def peek_tenant_id(_), do: {:error, :invalid_token}

  # Private Functions

  defp get_public_key do
    config = Application.get_env(:serviceradar_web_ng, __MODULE__, [])

    cond do
      key = config[:public_key] ->
        parse_public_key(key)

      file = config[:public_key_file] ->
        read_public_key_file(file)

      env_var = config[:public_key_env] ->
        case System.get_env(env_var) do
          nil -> {:error, :public_key_not_configured}
          key -> parse_public_key(key)
        end

      true ->
        {:error, :public_key_not_configured}
    end
  end

  defp parse_public_key(key_pem) when is_binary(key_pem) do
    try do
      jwk = JOSE.JWK.from_pem(key_pem)
      {:ok, jwk}
    rescue
      _ -> {:error, :invalid_public_key}
    end
  end

  defp read_public_key_file(path) do
    case File.read(path) do
      {:ok, content} -> parse_public_key(content)
      {:error, _} -> {:error, :public_key_file_not_found}
    end
  end

  defp decode_token(token) do
    try do
      case String.split(token, ".") do
        [header_b64, payload_b64, _signature] ->
          with {:ok, header_json} <- Base.url_decode64(header_b64, padding: false),
               {:ok, header} <- Jason.decode(header_json),
               {:ok, payload_json} <- Base.url_decode64(payload_b64, padding: false),
               {:ok, payload} <- Jason.decode(payload_json) do
            {:ok, {header, payload}}
          else
            _ -> {:error, :malformed_token}
          end

        _ ->
          {:error, :malformed_token}
      end
    rescue
      _ -> {:error, :malformed_token}
    end
  end

  defp verify_signature(token, jwk, header) do
    alg = Map.get(header, "alg", "RS256")

    try do
      case JOSE.JWS.verify_strict(jwk, [alg], token) do
        {true, _payload, _jws} -> :ok
        {false, _payload, _jws} -> {:error, :invalid_signature}
      end
    rescue
      _ -> {:error, :signature_verification_failed}
    end
  end

  defp validate_claims(payload) do
    config = Application.get_env(:serviceradar_web_ng, __MODULE__, [])
    expected_issuer = config[:issuer] || @expected_issuer
    expected_audience = config[:audience] || @expected_audience
    now = System.system_time(:second)

    with :ok <- validate_issuer(payload, expected_issuer),
         :ok <- validate_audience(payload, expected_audience),
         :ok <- validate_expiration(payload, now),
         {:ok, claims} <- extract_claims(payload) do
      {:ok, claims}
    end
  end

  defp validate_issuer(payload, expected) do
    case Map.get(payload, "iss") do
      ^expected -> :ok
      nil -> {:error, :missing_issuer}
      _ -> {:error, :invalid_issuer}
    end
  end

  defp validate_audience(payload, expected) do
    case Map.get(payload, "aud") do
      ^expected -> :ok
      aud when is_list(aud) ->
        if expected in aud, do: :ok, else: {:error, :invalid_audience}
      nil -> {:error, :missing_audience}
      _ -> {:error, :invalid_audience}
    end
  end

  defp validate_expiration(payload, now) do
    case Map.get(payload, "exp") do
      nil -> {:error, :missing_expiration}
      exp when is_integer(exp) and exp > now -> :ok
      _ -> {:error, :expired}
    end
  end

  defp extract_claims(payload) do
    with {:ok, sub} <- get_required(payload, "sub"),
         {:ok, tenant_id} <- get_required(payload, "tenant_id"),
         {:ok, tenant_slug} <- get_required(payload, "tenant_slug"),
         {:ok, role} <- get_required(payload, "role") do
      claims = %{
        sub: sub,
        tenant_id: tenant_id,
        tenant_slug: tenant_slug,
        role: normalize_role(role),
        component: Map.get(payload, "component"),
        iss: Map.get(payload, "iss"),
        aud: Map.get(payload, "aud"),
        exp: Map.get(payload, "exp"),
        iat: Map.get(payload, "iat"),
        jti: Map.get(payload, "jti")
      }

      {:ok, claims}
    end
  end

  defp get_required(map, key) do
    case Map.get(map, key) do
      nil -> {:error, String.to_atom("missing_#{key}")}
      value -> {:ok, value}
    end
  end

  defp normalize_role(role) when is_atom(role), do: role
  defp normalize_role("admin"), do: :admin
  defp normalize_role("operator"), do: :operator
  defp normalize_role("viewer"), do: :viewer
  defp normalize_role("system"), do: :system
  defp normalize_role("super_admin"), do: :super_admin
  defp normalize_role(_), do: :viewer
end
