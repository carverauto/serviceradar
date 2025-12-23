defmodule ServiceRadarWebNGWeb.Plugs.ApiAuth do
  @moduledoc """
  API authentication plug supporting API keys and bearer tokens.

  Checks for authentication in the following order:
  1. `Authorization: Bearer <token>` header
  2. `X-API-Key: <key>` header

  ## Configuration

  Configure API keys in your config:

      config :serviceradar_web_ng, :api_auth,
        api_keys: ["key1", "key2"]

  For bearer tokens, the plug validates against the user session token system.
  """

  import Plug.Conn
  require Logger

  alias ServiceRadarWebNG.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    case authenticate(conn) do
      {:ok, conn} ->
        conn

      {:error, :unauthorized} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{error: "unauthorized", message: "Invalid or missing authentication"})
        )
        |> halt()
    end
  end

  defp authenticate(conn) do
    cond do
      # Check Bearer token first
      bearer_token = get_bearer_token(conn) ->
        validate_bearer_token(conn, bearer_token)

      # Check API key
      api_key = get_api_key(conn) ->
        validate_api_key(conn, api_key)

      # No auth provided
      true ->
        {:error, :unauthorized}
    end
  end

  defp get_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> String.trim(token)
      ["bearer " <> token] -> String.trim(token)
      _ -> nil
    end
  end

  defp get_api_key(conn) do
    case get_req_header(conn, "x-api-key") do
      [key] -> String.trim(key)
      _ -> nil
    end
  end

  defp validate_bearer_token(conn, token) do
    # For bearer tokens, we validate against the user session system
    case Accounts.get_user_by_session_token(token) do
      nil ->
        {:error, :unauthorized}

      user ->
        scope = %ServiceRadarWebNG.Accounts.Scope{user: user}
        conn = assign(conn, :current_scope, scope)
        {:ok, conn}
    end
  end

  defp validate_api_key(conn, key) do
    valid_keys = get_api_keys()

    if key in valid_keys do
      # API key auth - create a system scope
      scope = %ServiceRadarWebNG.Accounts.Scope{user: nil}
      conn = assign(conn, :current_scope, scope)
      conn = assign(conn, :api_key_auth, true)
      {:ok, conn}
    else
      {:error, :unauthorized}
    end
  end

  defp get_api_keys do
    Application.get_env(:serviceradar_web_ng, :api_auth, [])
    |> Keyword.get(:api_keys, [])
  end
end
