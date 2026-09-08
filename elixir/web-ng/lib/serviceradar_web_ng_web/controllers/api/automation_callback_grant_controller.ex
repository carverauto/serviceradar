defmodule ServiceRadarWebNGWeb.Api.AutomationCallbackGrantController do
  @moduledoc false

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Automation.CallbackGrants.Runtime
  alias ServiceRadar.Automation.CallbackGrants.SshCaBundleResponse

  @denied_body ~s({"error":"callback_denied"})
  @pending_body ~s({"code":"grant_pending","retryable":true})
  @max_headers 32
  @max_header_bytes 16_384

  def consume_ssh_ca_bundle(conn, %{"grant_id" => grant_id}) do
    with :ok <- bounded_headers(conn),
         :ok <- valid_grant_id(grant_id),
         {:ok, bearer} <- callback_bearer(conn),
         {:ok, idempotency_key} <- idempotency_key(conn),
         {:ok, request} <- SshCaBundleResponse.validate_request(conn.body_params) do
      respond(conn, Runtime.consume(grant_id, bearer, idempotency_key, request))
    else
      _ -> denied(conn)
    end
  end

  def consume_ssh_ca_bundle(conn, _params), do: denied(conn)

  defp respond(conn, {:ok, %{status: 200, content_type: "application/json", body: body}}) when is_binary(body) do
    conn
    |> private_response_headers()
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  defp respond(conn, {:retry, %{status: 409, retry_after_seconds: 1}}) do
    conn
    |> private_response_headers()
    |> put_resp_header("retry-after", "1")
    |> put_resp_content_type("application/json")
    |> send_resp(409, @pending_body)
  end

  defp respond(conn, _result), do: denied(conn)

  defp denied(conn) do
    conn
    |> private_response_headers()
    |> put_resp_content_type("application/json")
    |> send_resp(401, @denied_body)
  end

  defp private_response_headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
  end

  # The callback bearer is deliberately accepted from exactly one header.
  # Session cookies, current-user assigns, API keys, query/body tokens, and
  # platform JWTs are never inspected as authority on this route.
  defp callback_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> bearer] when byte_size(bearer) in 32..128 ->
        if Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, bearer),
          do: {:ok, bearer},
          else: {:error, :invalid_callback_bearer}

      _ ->
        {:error, :invalid_callback_bearer}
    end
  end

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key] when byte_size(key) in 32..128 ->
        if Regex.match?(~r/\A[A-Za-z0-9._~-]+\z/, key),
          do: {:ok, key},
          else: {:error, :invalid_idempotency_key}

      _ ->
        {:error, :invalid_idempotency_key}
    end
  end

  defp valid_grant_id(grant_id) when is_binary(grant_id) do
    case Ecto.UUID.cast(grant_id) do
      {:ok, ^grant_id} -> :ok
      _ -> {:error, :invalid_grant_id}
    end
  end

  defp valid_grant_id(_grant_id), do: {:error, :invalid_grant_id}

  defp bounded_headers(%{req_headers: headers}) when length(headers) <= @max_headers do
    bytes =
      Enum.reduce(headers, 0, fn {name, value}, total ->
        total + byte_size(name) + byte_size(value)
      end)

    if bytes <= @max_header_bytes,
      do: :ok,
      else: {:error, :request_headers_too_large}
  end

  defp bounded_headers(_conn), do: {:error, :too_many_request_headers}
end
