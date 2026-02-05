defmodule ServiceRadarWebNG.AdminApi.Http do
  @moduledoc """
  HTTP-based admin API client.
  """

  @behaviour ServiceRadarWebNG.AdminApi

  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNGWeb.Endpoint

  @impl true
  def list_users(scope, params) do
    request(scope, :get, "/api/admin/users", params)
  end

  @impl true
  def create_user(scope, attrs) do
    request(scope, :post, "/api/admin/users", attrs)
  end

  @impl true
  def update_user(scope, id, attrs) do
    request(scope, :patch, "/api/admin/users/#{id}", attrs)
  end

  @impl true
  def deactivate_user(scope, id) do
    request(scope, :post, "/api/admin/users/#{id}/deactivate", %{})
  end

  @impl true
  def reactivate_user(scope, id) do
    request(scope, :post, "/api/admin/users/#{id}/reactivate", %{})
  end

  @impl true
  def get_authorization_settings(scope) do
    request(scope, :get, "/api/admin/authorization-settings", %{})
  end

  @impl true
  def update_authorization_settings(scope, attrs) do
    request(scope, :put, "/api/admin/authorization-settings", attrs)
  end

  defp request(scope, method, path, params) do
    with {:ok, token, _claims} <- Guardian.create_access_token(scope.user) do
      req =
        Req.new(
          base_url: base_url(),
          headers: [{"authorization", "Bearer #{token}"}],
          receive_timeout: 10_000
        )

      response =
        case method do
          :get -> Req.get(req, url: path, params: params)
          :post -> Req.post(req, url: path, json: params)
          :patch -> Req.patch(req, url: path, json: params)
          :put -> Req.put(req, url: path, json: params)
        end

      normalize_response(response)
    end
  end

  defp normalize_response({:ok, %Req.Response{status: status, body: body}})
       when status >= 200 and status < 300 do
    {:ok, normalize_body(body)}
  end

  defp normalize_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, {:http_error, status, body}}
  end

  defp normalize_response({:error, error}), do: {:error, error}

  defp normalize_body(body) when is_list(body) do
    Enum.map(body, &normalize_user/1)
  end

  defp normalize_body(%{"default_role" => _} = body), do: normalize_settings(body)
  defp normalize_body(%{} = body), do: normalize_user(body)
  defp normalize_body(body), do: body

  defp base_url do
    System.get_env("ADMIN_API_BASE_URL") ||
      Application.get_env(:serviceradar_web_ng, :admin_api_base_url) ||
      internal_base_url()
  end

  defp internal_base_url do
    http = Endpoint.config(:http)

    if is_list(http) do
      port = Keyword.get(http, :port, 4000)
      "http://127.0.0.1:#{port}"
    else
      Endpoint.url()
    end
  end

  defp normalize_user(%{} = body) do
    %{
      id: body["id"],
      email: body["email"],
      display_name: body["display_name"],
      role: parse_role(body["role"]),
      status: parse_status(body["status"]),
      confirmed_at: body["confirmed_at"],
      last_login_at: body["last_login_at"],
      last_auth_method: parse_auth_method(body["last_auth_method"]),
      authenticated_at: body["authenticated_at"],
      inserted_at: body["inserted_at"],
      updated_at: body["updated_at"]
    }
  end

  defp normalize_settings(%{} = body) do
    %{
      default_role: parse_role(body["default_role"]),
      role_mappings: body["role_mappings"] || []
    }
  end

  defp parse_role("admin"), do: :admin
  defp parse_role("operator"), do: :operator
  defp parse_role("viewer"), do: :viewer
  defp parse_role(role) when is_atom(role), do: role
  defp parse_role(_), do: :viewer

  defp parse_status("active"), do: :active
  defp parse_status("inactive"), do: :inactive
  defp parse_status(status) when is_atom(status), do: status
  defp parse_status(_), do: :active

  defp parse_auth_method(nil), do: nil
  defp parse_auth_method(""), do: nil
  defp parse_auth_method(value) when is_atom(value), do: value

  defp parse_auth_method(value) when is_binary(value) do
    case value do
      "password" -> :password
      "oidc" -> :oidc
      "saml" -> :saml
      "gateway" -> :gateway
      "api_token" -> :api_token
      "oauth_client" -> :oauth_client
      _ -> nil
    end
  end
end
