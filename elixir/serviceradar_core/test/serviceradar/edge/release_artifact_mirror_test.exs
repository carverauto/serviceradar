defmodule ServiceRadar.Edge.ReleaseArtifactMirrorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.ReleaseArtifactMirror

  @artifact_body "release-binary"
  @artifact_sha256 :sha256 |> :crypto.hash(@artifact_body) |> Base.encode16(case: :lower)

  test "prepare_publish_attrs mirrors artifacts into storage metadata" do
    attrs = %{
      version: "1.2.3",
      manifest: %{
        "version" => "1.2.3",
        "artifacts" => [
          %{
            "url" => "https://releases.example.com/serviceradar-agent-linux-amd64.tar.gz",
            "sha256" => @artifact_sha256,
            "os" => "linux",
            "arch" => "amd64",
            "format" => "tar.gz",
            "entrypoint" => "serviceradar-agent"
          }
        ]
      }
    }

    http_get = fn _url, _opts ->
      {:ok, %Req.Response{status: 200, body: @artifact_body}}
    end

    upload_object = fn metadata, data, _opts ->
      assert metadata.key =~ "agent-releases/1.2.3/"
      assert metadata.sha256 == @artifact_sha256
      assert data == @artifact_body
      {:ok, %Proto.UploadObjectResponse{}}
    end

    assert {:ok, mirrored_attrs} =
             ReleaseArtifactMirror.prepare_publish_attrs(
               attrs,
               validate_url: fn _url -> :ok end,
               http_get: http_get,
               upload_object: upload_object
             )

    storage = get_in(mirrored_attrs, [:metadata, "storage"])
    assert storage["status"] == "mirrored"
    assert storage["backend"] == "datasvc_object_store"
    assert storage["artifact_count"] == 1
    assert [%{"object_key" => object_key}] = storage["artifacts"]
    assert object_key =~ "agent-releases/1.2.3/"
  end

  test "prepare_publish_attrs blocks publication when mirror digest does not match" do
    attrs = %{
      version: "1.2.3",
      manifest: %{
        "version" => "1.2.3",
        "artifacts" => [
          %{
            "url" => "https://releases.example.com/serviceradar-agent-linux-amd64.tar.gz",
            "sha256" => @artifact_sha256,
            "os" => "linux",
            "arch" => "amd64"
          }
        ]
      }
    }

    http_get = fn _url, _opts ->
      {:ok, %Req.Response{status: 200, body: "wrong-binary"}}
    end

    assert {:error, reason} =
             ReleaseArtifactMirror.prepare_publish_attrs(
               attrs,
               validate_url: fn _url -> :ok end,
               http_get: http_get,
               upload_object: fn _metadata, _data, _opts -> flunk("upload should not run") end
             )

    assert reason =~ "artifact sha256 mismatch"
  end

  test "prepare_publish_attrs rejects private artifact URLs" do
    attrs = %{
      version: "1.2.3",
      manifest: %{
        "version" => "1.2.3",
        "artifacts" => [
          %{
            "url" => "https://127.0.0.1/serviceradar-agent-linux-amd64.tar.gz",
            "sha256" => @artifact_sha256,
            "os" => "linux",
            "arch" => "amd64"
          }
        ]
      }
    }

    assert {:error, reason} =
             ReleaseArtifactMirror.prepare_publish_attrs(
               attrs,
               http_get: fn _url, _opts -> flunk("http_get should not run") end,
               upload_object: fn _metadata, _data, _opts -> flunk("upload should not run") end
             )

    assert reason =~ "artifact URL host is not allowed"
  end
end
