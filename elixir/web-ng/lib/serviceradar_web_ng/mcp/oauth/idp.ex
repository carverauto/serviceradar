defmodule ServiceRadarWebNG.Mcp.OAuth.IdP do
  @moduledoc false

  alias ServiceRadarWebNG.Accounts.Scope

  @spec from_conn(Plug.Conn.t()) :: map()
  def from_conn(%Plug.Conn{} = conn) do
    claims =
      case conn.assigns[:current_scope] do
        %Scope{identity_claims: claims} when is_map(claims) -> claims
        _ -> %{}
      end

    from_claims(claims, Plug.Conn.get_session(conn, "mcp_idp_refresh"))
  end

  @spec from_session(map(), Scope.t() | nil) :: map()
  def from_session(session, scope) when is_map(session) do
    claims =
      case scope do
        %Scope{identity_claims: claims} when is_map(claims) -> claims
        _ -> %{}
      end

    from_claims(claims, session["mcp_idp_refresh"])
  end

  defp from_claims(claims, refresh) do
    method = claims["service_radar_auth_method"] || claims[:service_radar_auth_method] || "password"

    %{
      auth_method: auth_method(method),
      idp_iss: blank_to_nil(claims["iss"] || claims[:iss]),
      idp_sid: blank_to_nil(claims["sid"] || claims["SessionIndex"] || claims[:sid]),
      idp_refresh_token: blank_to_nil(refresh)
    }
  end

  defp auth_method("oidc"), do: :oidc
  defp auth_method(:oidc), do: :oidc
  defp auth_method("saml"), do: :saml
  defp auth_method(:saml), do: :saml
  defp auth_method(_), do: :password

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_), do: nil
end
