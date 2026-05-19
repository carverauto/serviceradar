defmodule ServiceRadarWebNGWeb.Api.NorthboundActionCallbackController do
  @moduledoc false

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Automation.Northbound.CommandResultHandler
  alias ServiceRadarWebNGWeb.Api.RawBodyReader

  @token_header "x-serviceradar-callback-token"
  @signature_header "x-serviceradar-callback-signature"
  @timestamp_header "x-serviceradar-callback-timestamp"

  def create(conn, %{"job_id" => job_id} = params) do
    payload = Map.drop(params, ["job_id", "callback_token"])
    token = callback_token(conn, params)

    case CommandResultHandler.handle_callback_result(job_id, payload,
           token: token,
           raw_body: RawBodyReader.raw_body(conn),
           headers: callback_signature_headers(conn)
         ) do
      {:ok, status} ->
        json(conn, %{status: Atom.to_string(status), job_id: job_id})

      {:error, :target_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "job_not_found"})

      {:error, reason}
      when reason in [
             :invalid_callback_token,
             :callback_not_configured,
             :missing_callback_signature,
             :missing_callback_timestamp,
             :invalid_callback_timestamp,
             :stale_callback_signature,
             :invalid_callback_signature
           ] ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "unauthorized"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "callback_rejected", reason: inspect(reason)})
    end
  end

  defp callback_token(conn, params) do
    conn
    |> get_req_header(@token_header)
    |> List.first()
    |> case do
      nil -> bearer_token(conn) || params["callback_token"]
      token -> token
    end
  end

  defp bearer_token(conn) do
    conn
    |> get_req_header("authorization")
    |> List.first()
    |> case do
      "Bearer " <> token -> token
      "bearer " <> token -> token
      _ -> nil
    end
  end

  defp callback_signature_headers(conn) do
    %{
      @signature_header => first_header(conn, @signature_header),
      @timestamp_header => first_header(conn, @timestamp_header)
    }
  end

  defp first_header(conn, header) do
    conn
    |> get_req_header(header)
    |> List.first()
  end
end
