defmodule ServiceRadarWebNGWeb.NVRPublicationRouter do
  @moduledoc """
  Private metadata-only intent acceptance for authenticated NVR workloads.

  The installed certificate binding supplies the storage UUID and system actor.
  Raw canonical intent bytes reach Core unchanged. Acknowledgement follows the
  durable Core transaction and does not advertise a playable local copy.
  """
  @behaviour Plug

  import Plug.Conn

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.LocalPublicationIntents

  @impl Plug
  def init(config), do: config

  @impl Plug
  def call(conn, config) do
    # The one-request HTTP/1 connection owns body reads, DB work and the reply.
    # A caller disappearing cannot leave it alive past this absolute deadline.
    {:ok, timer} = :timer.exit_after(10_000, :kill)

    try do
      with :https <- conn.scheme,
           %{ssl_cert: certificate} when is_binary(certificate) <- get_peer_data(conn),
           {:ok, storage_id} <- Map.fetch(config.clients, :crypto.hash(:sha256, certificate)),
           ["Bearer " <> token] when byte_size(token) <= 512 <- get_req_header(conn, "authorization"),
           true <- Plug.Crypto.secure_compare(:crypto.hash(:sha256, token), config.token_sha256) do
        route(conn, storage_id)
      else
        _ -> error(conn, 401, "unauthorized")
      end
    after
      :timer.cancel(timer)
    end
  end

  defp route(%{method: "POST", path_info: ["v1", "local-publication-intents"]} = conn, storage_id) do
    with ["application/json"] <- get_req_header(conn, "content-type"),
         {:ok, bytes, conn} when byte_size(bytes) <= 65_536 <-
           read_body(conn, length: 65_536, read_length: 65_536, read_timeout: 5_000) do
      result =
        LocalPublicationIntents.accept_from_storage(bytes, storage_id, actor: SystemActor.system(:nvr_publication))

      respond(conn, result)
    else
      {:more, _bytes, conn} -> error(conn, 413, "request_too_large")
      {:ok, _bytes, conn} -> error(conn, 413, "request_too_large")
      _ -> error(conn, 400, "invalid_request")
    end
  end

  defp route(conn, _storage_id), do: error(conn, 404, "not_found")

  defp respond(conn, {:ok, acknowledgement}), do: send_json(conn, 200, acknowledgement)

  defp respond(conn, {:error, :local_publication_storage_mismatch}), do: error(conn, 403, "storage_mismatch")

  defp respond(conn, {:error, :invalid_publication_intent}), do: error(conn, 400, "invalid_intent")

  defp respond(conn, {:error, :recording_block_not_found}), do: error(conn, 404, "recording_block_not_found")

  defp respond(conn, {:error, reason})
       when reason in [
              :local_publication_authority_mismatch,
              :local_publication_intent_conflict,
              :recording_block_unfrozen
            ], do: error(conn, 409, "publication_conflict")

  defp respond(conn, {:error, _}), do: error(conn, 503, "publication_unavailable")

  defp error(conn, status, reason), do: send_json(conn, status, Jason.encode!(%{error: reason}))

  defp send_json(conn, status, bytes) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_content_type("application/json")
    |> send_resp(status, bytes)
    |> halt()
  end
end
