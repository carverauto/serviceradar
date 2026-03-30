defmodule ServiceRadarAgentGateway.ReleaseArtifactServerTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ServiceRadarAgentGateway.ReleaseArtifactServer

  test "returns forbidden when core authorization rejects the download" do
    conn =
      :get
      |> conn("/artifacts/releases/download")
      |> put_req_header("x-serviceradar-release-target-id", "target-123")
      |> put_req_header("x-serviceradar-release-command-id", "command-123")
      |> ReleaseArtifactServer.call(
        ReleaseArtifactServer.init(
          resolve_identity: fn _conn ->
            {:ok, %{component_id: "agent-123", component_type: :agent}}
          end,
          resolve_download: fn _target_id, _command_id, _caller_agent_id -> {:error, :unauthorized} end
        )
      )

    assert conn.status == 403
    assert conn.resp_body =~ "release artifact access denied"
  end

  test "streams mirrored artifact data on successful authorization" do
    conn =
      :get
      |> conn("/artifacts/releases/download")
      |> put_req_header("x-serviceradar-release-target-id", "target-123")
      |> put_req_header("x-serviceradar-release-command-id", "command-123")
      |> ReleaseArtifactServer.call(
        ReleaseArtifactServer.init(
          resolve_identity: fn _conn ->
            {:ok, %{component_id: "agent-123", component_type: :agent}}
          end,
          resolve_download: fn "target-123", "command-123", "agent-123" ->
            {:ok,
             %{
               object_key: "agent-releases/1.2.3/linux-amd64",
               file_name: "serviceradar-agent",
               content_type: "application/octet-stream"
             }}
          end,
          download_object: fn "agent-releases/1.2.3/linux-amd64" ->
            {:ok, "artifact-body"}
          end
        )
      )

    assert conn.status == 200
    assert conn.resp_body == "artifact-body"
    assert get_resp_header(conn, "content-type") == ["application/octet-stream; charset=utf-8"]
  end

  test "rejects callers without an authenticated agent identity" do
    conn =
      :get
      |> conn("/artifacts/releases/download")
      |> put_req_header("x-serviceradar-release-target-id", "target-123")
      |> put_req_header("x-serviceradar-release-command-id", "command-123")
      |> ReleaseArtifactServer.call(
        ReleaseArtifactServer.init(resolve_identity: fn _conn -> {:error, :unauthenticated} end)
      )

    assert conn.status == 401
    assert conn.resp_body =~ "invalid client certificate"
  end

  test "rejects non-agent client certificates" do
    conn =
      :get
      |> conn("/artifacts/releases/download")
      |> put_req_header("x-serviceradar-release-target-id", "target-123")
      |> put_req_header("x-serviceradar-release-command-id", "command-123")
      |> ReleaseArtifactServer.call(
        ReleaseArtifactServer.init(
          resolve_identity: fn _conn ->
            {:ok, %{component_id: "gateway-123", component_type: :gateway}}
          end
        )
      )

    assert conn.status == 403
    assert conn.resp_body =~ "release artifact access denied"
  end
end
