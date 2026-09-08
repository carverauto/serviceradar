defmodule ServiceRadarWebNGWeb.Auth.ErrorHandler do
  @moduledoc """
  Guardian error handler for authentication failures.

  Handles errors from Guardian pipelines and returns appropriate
  responses based on the request type (JSON API vs browser).

  ## Error Types

  - `:unauthenticated` - No valid token provided
  - `:invalid_token` - Token verification failed
  - `:token_expired` - Token has expired
  - `:invalid_token_type` - Token type doesn't match expected
  """

  @behaviour Guardian.Plug.ErrorHandler

  use ServiceRadarWebNGWeb, :controller

  require Logger

  @impl Guardian.Plug.ErrorHandler
  def auth_error(conn, {type, reason}, _opts) do
    conn
    |> log_auth_error(type, reason)
    |> respond_with_error(type, reason)
  end

  defp log_auth_error(conn, type, reason) do
    Logger.warning("Authentication error",
      type: type,
      reason: inspect(reason),
      path: conn.request_path,
      method: conn.method,
      remote_ip: format_ip(conn.remote_ip)
    )

    conn
  end

  defp respond_with_error(conn, type, _reason) do
    if json_request?(conn) do
      json_error(conn, type)
    else
      html_error(conn, type)
    end
  end

  defp json_request?(conn) do
    accept = conn |> get_req_header("accept") |> List.first() || ""
    content_type = conn |> get_req_header("content-type") |> List.first() || ""

    String.contains?(accept, "application/json") or
      String.contains?(content_type, "application/json") or
      String.starts_with?(conn.request_path, "/api")
  end

  defp json_error(conn, type) do
    {status, message} = error_details(type)

    conn
    |> put_status(status)
    |> put_resp_content_type("application/json")
    |> json(%{
      error: %{
        type: to_string(type),
        message: message
      }
    })
  end

  defp html_error(conn, type) do
    {status, _message} = error_details(type)

    case type do
      :unauthenticated ->
        conn
        |> put_flash(:error, "You must log in to access this page.")
        |> maybe_store_return_to()
        |> redirect(to: ~p"/users/log-in")

      :token_expired ->
        conn
        |> put_flash(:error, "Your session has expired. Please log in again.")
        |> clear_session()
        |> redirect(to: ~p"/users/log-in")

      _ ->
        conn
        |> put_status(status)
        |> put_flash(:error, "Authentication failed. Please log in again.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  defp error_details(type) do
    case type do
      :unauthenticated ->
        {401, "Authentication required"}

      :invalid_token ->
        {401, "Invalid authentication token"}

      :token_expired ->
        {401, "Authentication token has expired"}

      :invalid_token_type ->
        {401, "Invalid token type for this endpoint"}

      :no_resource_found ->
        {401, "User not found"}

      _ ->
        {401, "Authentication failed"}
    end
  end

  defp maybe_store_return_to(conn) do
    if conn.method == "GET" and not String.starts_with?(conn.request_path, "/api") do
      put_session(conn, :user_return_to, conn.request_path)
    else
      conn
    end
  end

  defp format_ip(ip) when is_tuple(ip) do
    ip |> Tuple.to_list() |> Enum.join(".")
  end

  defp format_ip(ip), do: inspect(ip)
end
