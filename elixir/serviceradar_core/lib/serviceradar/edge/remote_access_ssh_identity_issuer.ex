defmodule ServiceRadar.Edge.RemoteAccessSSHIdentityIssuer do
  @moduledoc """
  Issues SSH certificates from a trusted SSO identity context.

  Browser request parameters may identify the session, target, public key, and
  requested login principals, but IdP claims must come from the server-side
  authenticated login context or a freshly verified IdP token. This boundary
  strips caller-supplied claims before invoking certificate policy.
  """

  alias ServiceRadar.Edge.RemoteAccessSSHCertificates

  @trusted_auth_methods [:oidc, :saml]
  @identity_claim_keys [:claims, "claims", :idp_claims, "idp_claims"]

  @spec issue(map() | struct(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def issue(actor, request_attrs, opts \\ [])

  def issue(actor, request_attrs, opts) when is_map(request_attrs) do
    with :ok <- require_sso_identity(actor, opts),
         {:ok, claims} <- authoritative_claims(actor, opts) do
      attrs =
        request_attrs
        |> Map.drop(@identity_claim_keys)
        |> Map.put(:claims, claims)

      RemoteAccessSSHCertificates.issue(actor, attrs, opts)
    end
  end

  def issue(_actor, _request_attrs, _opts), do: {:error, :invalid_request}

  defp require_sso_identity(actor, opts) do
    if Keyword.get(opts, :require_sso?, true) do
      trusted_auth_methods = Keyword.get(opts, :trusted_auth_methods, @trusted_auth_methods)

      if auth_method(actor) in Enum.map(trusted_auth_methods, &normalize_atom/1) do
        :ok
      else
        {:error, :sso_identity_required}
      end
    else
      :ok
    end
  end

  defp authoritative_claims(actor, opts) do
    claims = Keyword.get(opts, :idp_claims) || Keyword.get(opts, :claims) || %{}

    if is_map(claims) do
      {:ok, Map.merge(stringify_keys(claims), actor_claims(actor))}
    else
      {:error, :invalid_identity_claims}
    end
  end

  defp actor_claims(actor) do
    %{
      "sub" => actor_field(actor, :external_id) || actor_field(actor, :id),
      "email" => actor_field(actor, :email),
      "name" => actor_field(actor, :display_name),
      "service_radar_user_id" => actor_field(actor, :id),
      "service_radar_auth_method" => actor_field(actor, :last_auth_method),
      "service_radar_role" => actor_field(actor, :role)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp auth_method(actor) do
    actor
    |> actor_field(:last_auth_method)
    |> normalize_atom()
  end

  defp normalize_atom(value) when is_atom(value), do: value

  defp normalize_atom(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> String.to_existing_atom()
  rescue
    ArgumentError -> nil
  end

  defp normalize_atom(_value), do: nil

  defp actor_field(actor, key) when is_map(actor) and is_atom(key) do
    actor
    |> Map.get(key)
    |> string_value()
    |> Kernel.||(string_value(Map.get(actor, Atom.to_string(key))))
  end

  defp actor_field(_actor, _key), do: nil

  defp string_value(nil), do: nil

  defp string_value(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_value(value) when is_integer(value), do: Integer.to_string(value)
  defp string_value(value), do: to_string(value)
end
