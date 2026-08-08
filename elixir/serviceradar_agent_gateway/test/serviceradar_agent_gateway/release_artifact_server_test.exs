defmodule ServiceRadarAgentGateway.ReleaseArtifactServerTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ServiceRadar.Plugins.StorageToken
  alias ServiceRadarAgentGateway.ReleaseArtifactServer

  @moduletag :requires_app

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
          resolve_download: fn _target_id, _command_id, _caller_agent_id ->
            {:error, :unauthorized}
          end
        )
      )

    assert conn.status == 403
    assert conn.resp_body =~ "release artifact access denied"
  end

  test "returns a retryable 409 when the artifact is not ready yet" do
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
          resolve_download: fn _target_id, _command_id, _caller_agent_id ->
            {:error, :artifact_not_ready}
          end
        )
      )

    assert conn.status == 409
    assert conn.resp_body =~ "release artifact is not ready yet"
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

  test "streams native add-on artifact data through token authorization" do
    with_plugin_storage(fn ->
      request = StorageToken.download_addon_request("package-123", "native-addons/pkg.tar.gz")

      conn =
        :post
        |> conn("/artifacts/addons/package-123/blob/download")
        |> put_req_header("x-serviceradar-plugin-token", request.token)
        |> ReleaseArtifactServer.call(
          ReleaseArtifactServer.init(
            resolve_identity: fn _conn ->
              {:ok, %{component_id: "agent-123", component_type: :agent}}
            end,
            resolve_addon_artifact_download: fn "package-123", "native-addons/pkg.tar.gz", "agent-123" ->
              {:ok,
               %{
                 object_key: "native-addons/pkg.tar.gz",
                 file_name: "pkg.tar.gz",
                 content_type: "application/gzip"
               }}
            end,
            download_object: fn "native-addons/pkg.tar.gz" ->
              {:ok, "addon-body"}
            end
          )
        )

      assert conn.status == 200
      assert conn.resp_body == "addon-body"
      assert get_resp_header(conn, "content-type") == ["application/gzip; charset=utf-8"]
    end)
  end

  test "streams generic agent artifact data through token authorization" do
    with_plugin_storage(fn ->
      request =
        StorageToken.download_agent_artifact_request("catalog-source", "catalogs/current.json")

      assert request.url ==
               "https://gateway.example:50053/artifacts/agent-artifacts/catalog-source/download"

      conn =
        :post
        |> conn("/artifacts/agent-artifacts/catalog-source/download")
        |> put_req_header("x-serviceradar-plugin-token", request.token)
        |> ReleaseArtifactServer.call(
          ReleaseArtifactServer.init(
            resolve_identity: fn _conn ->
              {:ok, %{component_id: "agent-123", component_type: :agent}}
            end,
            resolve_agent_artifact_download: fn "catalog-source", "catalogs/current.json", "agent-123" ->
              {:ok,
               %{
                 object_key: "catalogs/current.json",
                 file_name: "current.json",
                 content_type: "application/json"
               }}
            end,
            download_object: fn "catalogs/current.json" ->
              {:ok, ~s({"entries":[]})}
            end
          )
        )

      assert conn.status == 200
      assert conn.resp_body == ~s({"entries":[]})
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    end)
  end

  test "uploads plugin staged artifacts under an agent scoped object key" do
    body = ~s({"advisories":[]})
    sha256 = :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)

    conn =
      :post
      |> conn("/artifacts/agent-artifacts/upload", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-serviceradar-artifact-key", "feeds/nvd.json")
      |> put_req_header("x-serviceradar-artifact-assignment-id", "assign-123")
      |> put_req_header("x-serviceradar-artifact-plugin-id", "feed-plugin")
      |> put_req_header("x-serviceradar-artifact-sha256", sha256)
      |> put_req_header("x-serviceradar-artifact-size", Integer.to_string(byte_size(body)))
      |> ReleaseArtifactServer.call(
        ReleaseArtifactServer.init(
          resolve_identity: fn _conn ->
            {:ok, %{component_id: "agent-123", component_type: :agent}}
          end,
          upload_object: fn metadata, data ->
            assert data == body
            assert metadata.key == "agent-artifacts/agent-123/assign-123/feeds/nvd.json"
            assert metadata.content_type == "application/json"
            assert metadata.sha256 == sha256
            assert metadata.total_size == byte_size(body)
            assert metadata.attributes["agent_id"] == "agent-123"
            assert metadata.attributes["assignment_id"] == "assign-123"
            assert metadata.attributes["plugin_id"] == "feed-plugin"

            {:ok,
             %Proto.UploadObjectResponse{
               info: %Proto.ObjectInfo{
                 metadata: metadata,
                 sha256: sha256,
                 size: byte_size(body)
               }
             }}
          end
        )
      )

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "attributes" => %{
               "agent_id" => "agent-123",
               "assignment_id" => "assign-123",
               "plugin_id" => "feed-plugin",
               "source" => "wasm-plugin",
               "storage_backend" => "datasvc_object_store"
             },
             "content_type" => "application/json",
             "object_key" => "agent-artifacts/agent-123/assign-123/feeds/nvd.json",
             "sha256" => sha256,
             "size_bytes" => byte_size(body)
           }
  end

  test "uploads native add-on staged artifacts with native source provenance" do
    body = ~s({"snapshot":"ok"})
    sha256 = :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)

    conn =
      :post
      |> conn("/artifacts/agent-artifacts/upload", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-serviceradar-artifact-key", "feeds/example.json")
      |> put_req_header("x-serviceradar-artifact-assignment-id", "endpoint-inventory")
      |> put_req_header("x-serviceradar-artifact-plugin-id", "endpoint-inventory")
      |> put_req_header("x-serviceradar-artifact-source", "native-addon")
      |> put_req_header("x-serviceradar-artifact-sha256", sha256)
      |> put_req_header("x-serviceradar-artifact-size", Integer.to_string(byte_size(body)))
      |> ReleaseArtifactServer.call(
        ReleaseArtifactServer.init(
          resolve_identity: fn _conn ->
            {:ok, %{component_id: "agent-123", component_type: :agent}}
          end,
          upload_object: fn metadata, data ->
            assert data == body

            assert metadata.key ==
                     "agent-artifacts/agent-123/endpoint-inventory/feeds/example.json"

            assert metadata.attributes["source"] == "native-addon"

            {:ok,
             %Proto.UploadObjectResponse{
               info: %Proto.ObjectInfo{
                 metadata: metadata,
                 sha256: sha256,
                 size: byte_size(body)
               }
             }}
          end
        )
      )

    assert conn.status == 200

    assert %{
             "attributes" => %{
               "source" => "native-addon",
               "storage_backend" => "datasvc_object_store"
             },
             "object_key" => "agent-artifacts/agent-123/endpoint-inventory/feeds/example.json"
           } = Jason.decode!(conn.resp_body)
  end

  test "rejects unsafe staged artifact object keys" do
    conn =
      :post
      |> conn("/artifacts/agent-artifacts/upload", "body")
      |> put_req_header("x-serviceradar-artifact-key", "../nvd.json")
      |> put_req_header("x-serviceradar-artifact-assignment-id", "assign-123")
      |> ReleaseArtifactServer.call(
        ReleaseArtifactServer.init(
          resolve_identity: fn _conn ->
            {:ok, %{component_id: "agent-123", component_type: :agent}}
          end
        )
      )

    assert conn.status == 400
    assert conn.resp_body =~ "invalid artifact key"
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

  defp with_plugin_storage(fun) do
    original = Application.get_env(:serviceradar_core, :plugin_storage)

    Application.put_env(:serviceradar_core, :plugin_storage,
      public_url: "https://gateway.example:50053",
      signing_secret: String.duplicate("s", 32),
      download_ttl_seconds: 60
    )

    try do
      fun.()
    after
      if original do
        Application.put_env(:serviceradar_core, :plugin_storage, original)
      else
        Application.delete_env(:serviceradar_core, :plugin_storage)
      end
    end
  end
end
