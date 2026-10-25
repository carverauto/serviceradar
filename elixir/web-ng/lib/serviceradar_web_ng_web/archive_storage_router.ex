defmodule ServiceRadarWebNGWeb.ArchiveStorageRouter do
  @moduledoc """
  Storage-purpose coordination behind mutual TLS and a pinned workload identity.

  This listener accepts no provider credential, destination, object key or media
  bytes. Its installed principal and stable actor never come from a request.
  """
  @behaviour Plug

  import Plug.Conn

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveInitAuthorities
  alias ServiceRadar.Camera.ArchiveUploads
  alias ServiceRadarWebNGWeb.ControlPlaneJSON

  @impl Plug
  def init(config), do: config

  @impl Plug
  def call(conn, config) do
    with :https <- conn.scheme,
         %{ssl_cert: certificate} when is_binary(certificate) <- get_peer_data(conn),
         true <-
           Plug.Crypto.secure_compare(
             :crypto.hash(:sha256, certificate),
             config.client_cert_sha256
           ),
         ["Bearer " <> token] when byte_size(token) <= 512 <-
           get_req_header(conn, "authorization"),
         true <-
           Plug.Crypto.secure_compare(
             :crypto.hash(:sha256, token),
             config.token_sha256
           ) do
      route(conn, config.principal)
    else
      _ -> respond(conn, 401, %{status: "unauthorized"})
    end
  end

  defp route(conn, principal) do
    path = Enum.map(conn.path_info, &URI.decode/1)

    case {conn.method, path} do
      {"POST", ["v1", "init-authorities", "challenge"]} ->
        read(conn, &ArchiveInitAuthorities.challenge(principal, &1, actor: actor()))

      {"POST", ["v1", "init-uploads", operation]}
      when operation in ~w(prepare grant observe verify) ->
        read(conn, &operation(operation, &1, principal))

      _ ->
        respond(conn, 404, %{status: "not_found"})
    end
  end

  defp read(conn, operation) do
    case ControlPlaneJSON.read(conn, 16_384) do
      {:ok, document, conn} -> respond_result(conn, operation.(document))
      {:error, status, reason, conn} -> respond(conn, status, %{status: reason})
    end
  end

  defp operation("prepare", %{"schema_version" => 1, "lease" => lease} = document, _principal)
       when map_size(document) == 2 do
    with {:ok, lease} <- lease(lease),
         {:ok, dispatch} <-
           ArchiveUploads.prepare_dispatch(lease, :init, :put_object, 5000, actor: actor()) do
      {:ok, %{schema_version: 1, dispatch_id: dispatch.id}}
    end
  end

  defp operation(
         "grant",
         %{
           "schema_version" => 1,
           "lease" => lease,
           "dispatch_id" => dispatch_id,
           "storage_boot_id" => boot,
           "desired_sha256" => digest,
           "nonce" => nonce
         } = document,
         principal
       )
       when map_size(document) == 6 do
    with {:ok, lease} <- lease(lease),
         {:ok, correlation} <- correlation(dispatch_id, boot, digest, nonce) do
      ArchiveUploads.authorize_init(lease, dispatch_id, principal, correlation, actor: actor())
    end
  end

  defp operation(
         "observe",
         %{"schema_version" => 1, "lease" => lease, "dispatch_id" => dispatch_id, "outcome" => "unknown"} = document,
         _principal
       )
       when map_size(document) == 4 do
    with {:ok, lease} <- lease(lease),
         :ok <- dispatch_id(dispatch_id),
         {:ok, _} <- ArchiveUploads.observe_unknown(lease, dispatch_id, actor: actor()) do
      {:ok, %{schema_version: 1, status: "recorded"}}
    end
  end

  defp operation(
         "observe",
         %{
           "schema_version" => 1,
           "lease" => lease,
           "dispatch_id" => dispatch_id,
           "outcome" => "response",
           "response" => response
         } = document,
         _principal
       )
       when map_size(document) == 5 do
    with {:ok, lease} <- lease(lease),
         :ok <- dispatch_id(dispatch_id),
         {:ok, _} <- ArchiveUploads.observe_response(lease, dispatch_id, response, actor: actor()) do
      {:ok, %{schema_version: 1, status: "recorded"}}
    end
  end

  defp operation(
         "verify",
         %{
           "schema_version" => 1,
           "lease" => lease,
           "dispatch_id" => dispatch_id,
           "storage_boot_id" => boot,
           "desired_sha256" => digest,
           "nonce" => nonce,
           "verification" => verification
         } = document,
         principal
       )
       when map_size(document) == 7 do
    with {:ok, lease} <- lease(lease),
         {:ok, correlation} <- correlation(dispatch_id, boot, digest, nonce),
         {:ok, dispatch} <-
           ArchiveUploads.observe_init_verification(
             lease,
             dispatch_id,
             principal,
             correlation,
             verification,
             actor: actor()
           ) do
      {:ok, %{schema_version: 1, status: "recorded", dispatch_id: dispatch.id}}
    end
  end

  defp operation(_, _, _), do: {:error, :invalid_request}

  defp lease(%{"id" => id, "upload_token" => token, "upload_epoch" => epoch, "descriptor_sha256" => sha} = lease)
       when map_size(lease) == 4 do
    with true <- uuid?(id) and uuid?(token) and sha?(sha),
         {number, ""} when number > 0 and number <= 9_223_372_036_854_775_807 <-
           parse_epoch(epoch),
         true <- Integer.to_string(number) == epoch do
      {:ok, %{id: id, upload_token: token, upload_epoch: number, descriptor_sha256: sha}}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp lease(_), do: {:error, :invalid_request}

  defp parse_epoch(epoch) when is_binary(epoch) and byte_size(epoch) <= 19, do: Integer.parse(epoch)

  defp parse_epoch(_), do: :error

  defp correlation(dispatch_id, boot, digest, nonce) do
    if uuid?(dispatch_id) and uuid?(boot) and sha?(digest) and sha?(nonce),
      do: {:ok, %{storage_boot_id: boot, desired_sha256: digest, nonce: nonce}},
      else: {:error, :invalid_request}
  end

  defp dispatch_id(id), do: if(uuid?(id), do: :ok, else: {:error, :invalid_request})

  defp uuid?(value) when is_binary(value) and byte_size(value) == 36, do: match?({:ok, ^value}, Ecto.UUID.cast(value))

  defp uuid?(_), do: false

  defp sha?(value) when is_binary(value) and byte_size(value) == 64,
    do: match?({:ok, _}, Base.decode16(value, case: :lower))

  defp sha?(_), do: false
  defp actor, do: SystemActor.system(:camera_archive_storage)

  defp respond_result(conn, {:ok, projection}), do: respond(conn, 200, projection)

  defp respond_result(conn, {:error, reason})
       when reason in [
              :invalid_request,
              :invalid_init_principal,
              :invalid_init_challenge,
              :invalid_init_grant,
              :invalid_init_verification,
              :invalid_upload_response
            ], do: respond(conn, 400, %{status: reason})

  defp respond_result(conn, {:error, reason})
       when reason in [
              :archive_binding_not_found,
              :init_authority_not_found,
              :upload_dispatch_not_found,
              :recording_block_not_found
            ], do: respond(conn, 404, %{status: reason})

  defp respond_result(conn, {:error, reason})
       when reason in [
              :init_authority_revision_stale,
              :init_authority_revision_conflict,
              :init_authority_challenge_mismatch,
              :init_authority_context_mismatch,
              :init_authority_origin_mismatch,
              :init_authority_generation_stale,
              :init_authority_report_unqualified,
              :init_authority_expired,
              :init_authority_not_applied,
              :init_dispatch_already_marked,
              :init_verification_conflict,
              :init_verification_origin_mismatch,
              :upload_dispatch_expired,
              :upload_lease_lost,
              :upload_dispatch_unmarked,
              :archive_upload_dispatch_conflict,
              :archive_upload_intent_conflict,
              :archive_upload_response_conflict,
              :archive_binding_required,
              :recording_block_unfrozen,
              :recording_stopped
            ], do: respond(conn, 409, %{status: reason})

  defp respond_result(conn, {:error, _}), do: respond(conn, 503, %{status: "storage_control_unavailable"})

  defp respond(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
