defmodule ServiceRadarWebNGWeb.Plugs.ControlPlaneArchiveBindings do
  @moduledoc "Registers unqualified archive destinations after private media authentication."
  @behaviour Plug

  import Plug.Conn

  alias Ash.Error.Changes.InvalidArgument
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.ArchiveDestination
  alias ServiceRadarWebNGWeb.ControlPlaneJSON

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case {conn.method, Enum.map(conn.path_info, &URI.decode/1)} do
      {"POST", ["v1", "media", "archive-bindings"]} -> register(conn)
      _ -> conn
    end
  end

  defp register(conn) do
    case ControlPlaneJSON.read(conn, 4096) do
      {:ok, document, conn} -> register_document(conn, document)
      {:error, status, reason, conn} -> respond(conn, status, %{status: reason})
    end
  end

  defp register_document(conn, %{"schema_version" => 1, "destination" => destination} = document)
       when map_size(document) == 2 do
    case ArchiveDestination.attributes(destination) do
      {:ok, _} -> persist(conn, destination)
      {:error, _} -> respond(conn, 400, %{status: "invalid_archive_destination"})
    end
  end

  defp register_document(conn, _document), do: respond(conn, 400, %{status: "invalid_archive_registration"})

  defp persist(conn, destination) do
    case ArchiveBinding.register(destination, actor: SystemActor.system(:archive_binding_control)) do
      {:ok, binding} ->
        respond(conn, 200, %{
          schema_version: 1,
          status: "registered",
          binding_id: binding.id,
          provisioning_ref: binding.provisioning_ref,
          generation: binding.generation,
          destination_sha256: binding.destination_sha256,
          capability_state: binding.capability_state,
          readiness: "unavailable",
          reason: "archive_binding_only"
        })

      {:error, %Ash.Error.Invalid{errors: [%InvalidArgument{field: :destination}]}} ->
        respond(conn, 409, %{status: "archive_binding_conflict"})

      {:error, _} ->
        respond(conn, 503, %{status: "storage_unavailable"})
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] ->
      respond(conn, 503, %{status: "storage_unavailable"})
  end

  defp respond(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
