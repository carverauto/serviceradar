defmodule ServiceRadarWebNGWeb.Plugs.ControlPlaneArchiveQualifications do
  @moduledoc """
  Qualification receipts on the private control-plane listener, after its auth plug.

  Reads bounded JSON before the general parser can discard duplicate keys. A
  receipt acknowledges persisted observations only, never storage readiness.
  """
  @behaviour Plug

  import Plug.Conn

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveQualifications

  @body_limit 16_384

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{path_info: ["v1", "archive-bindings", binding_id, "qualification"], method: "PUT"} = conn, _opts) do
    with true <- json_content_type?(conn),
         {:ok, body, conn} when byte_size(body) <= @body_limit <-
           read_body(conn, length: @body_limit, read_length: @body_limit, read_timeout: 5_000) do
      submit_body(conn, binding_id, body)
    else
      false -> respond(conn, 415, %{status: "unsupported_media_type"})
      {:more, _body, conn} -> respond(conn, 413, %{status: "request_too_large"})
      {:ok, body, conn} when is_binary(body) -> respond(conn, 413, %{status: "request_too_large"})
      _ -> respond(conn, 400, %{status: "invalid_request"})
    end
  end

  def call(%{path_info: ["v1", "archive-bindings", binding_id, "qualification"], method: "GET"} = conn, _opts) do
    respond_result(conn, ArchiveQualifications.status(binding_id, actor: actor()))
  end

  def call(conn, _opts), do: conn

  defp submit_body(conn, binding_id, body) do
    with {:ok, %Jason.OrderedObject{} = decoded} <- Jason.decode(body, objects: :ordered_objects),
         {:ok, document} <- plain_value(decoded) do
      respond_result(conn, ArchiveQualifications.submit(binding_id, document, actor: actor()))
    else
      _ -> respond(conn, 400, %{status: "invalid_request"})
    end
  end

  defp json_content_type?(conn) do
    case get_req_header(conn, "content-type") do
      [content_type] ->
        content_type |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase() == "application/json"

      _ ->
        false
    end
  end

  defp plain_value(%Jason.OrderedObject{values: pairs}) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, map} ->
      with false <- Map.has_key?(map, key),
           {:ok, value} <- plain_value(value) do
        {:cont, {:ok, Map.put(map, key, value)}}
      else
        _ -> {:halt, {:error, :invalid_request}}
      end
    end)
  end

  defp plain_value(value) when is_list(value), do: {:error, :invalid_request}
  defp plain_value(value), do: {:ok, value}

  defp respond_result(conn, {:ok, nil}) do
    respond(conn, 200, %{status: "not_submitted", applied_revision: nil, readiness: "unavailable"})
  end

  defp respond_result(conn, {:ok, receipt}) do
    respond(conn, 200, %{
      status: "recorded",
      binding_id: receipt.archive_binding_id,
      revision: receipt.revision,
      state: receipt.state,
      receipt_sha256: receipt.receipt_sha256,
      report_sha256: receipt.report_sha256,
      received_at: DateTime.to_iso8601(receipt.received_at),
      applied_revision: nil,
      readiness: "unavailable",
      reason: "qualification_receipt_only"
    })
  end

  defp respond_result(conn, {:error, :archive_binding_not_found}), do: respond(conn, 404, %{status: "not_found"})

  defp respond_result(conn, {:error, reason})
       when reason in [:qualification_revision_stale, :qualification_revision_conflict] do
    respond(conn, 409, %{status: Atom.to_string(reason)})
  end

  defp respond_result(conn, {:error, reason})
       when reason == :invalid_archive_binding_id or reason == :invalid_qualification_submission or
              reason == :qualification_binding_mismatch do
    respond(conn, 400, %{status: Atom.to_string(reason)})
  end

  defp respond_result(conn, {:error, _reason}), do: respond(conn, 503, %{status: "storage_unavailable"})

  defp actor, do: SystemActor.system(:archive_qualification_control)

  defp respond(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
