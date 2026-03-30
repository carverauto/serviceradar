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

  test "prepare_publish_attrs rejects redirect targets that fail fetch policy" do
    attrs = %{
      version: "1.2.3",
      manifest: %{
        "version" => "1.2.3",
        "artifacts" => [
          %{
            "url" => "https://releases.example.com/artifact.tar.gz",
            "sha256" => @artifact_sha256,
            "os" => "linux",
            "arch" => "amd64"
          }
        ]
      }
    }

    http_get = fn
      "https://releases.example.com/artifact.tar.gz", _opts ->
        response =
          Req.Response.put_header(
            %Req.Response{status: 302},
            "location",
            "https://127.0.0.1/internal.tar.gz"
          )

        {:ok, response}

      _url, _opts ->
        flunk("redirect target should not be fetched")
    end

    validate_url = fn
      "https://releases.example.com/artifact.tar.gz" -> :ok
      "https://127.0.0.1/internal.tar.gz" -> {:error, :disallowed_host}
    end

    assert {:error, reason} =
             ReleaseArtifactMirror.prepare_publish_attrs(
               attrs,
               validate_url: validate_url,
               http_get: http_get,
               upload_object: fn _metadata, _data, _opts -> flunk("upload should not run") end
             )

    assert reason =~ "artifact URL host is not allowed"
  end

  test "prepare_publish_attrs aborts streaming download once artifact exceeds limit" do
    attrs = %{
      version: "1.2.3",
      manifest: %{
        "version" => "1.2.3",
        "artifacts" => [
          %{
            "url" => "https://releases.example.com/large-artifact.tar.gz",
            "sha256" => @artifact_sha256,
            "os" => "linux",
            "arch" => "amd64"
          }
        ]
      }
    }

    chunk = String.duplicate("a", 128 * 1024 * 1024)

    http_get = fn _url, opts ->
      into = Keyword.fetch!(opts, :into)
      state = {%Req.Request{}, %Req.Response{status: 200}}
      assert {:cont, _state} = into.({:data, chunk}, state)

      assert_raise RuntimeError, "artifact_too_large", fn ->
        into.({:data, chunk <> "b"}, state)
      end

      {:error, :artifact_too_large}
    end

    assert {:error, reason} =
             ReleaseArtifactMirror.prepare_publish_attrs(
               attrs,
               validate_url: fn _url -> :ok end,
               http_get: http_get,
               upload_object: fn _metadata, _data, _opts -> flunk("upload should not run") end
             )

    assert reason =~ "mirror limit"
  end

  test "prepare_publish_attrs mirrors pathless artifact URLs with a safe fallback basename" do
    attrs = %{
      version: "1.2.3",
      manifest: %{
        "version" => "1.2.3",
        "artifacts" => [
          %{
            "url" => "https://releases.example.com",
            "sha256" => @artifact_sha256,
            "os" => "linux",
            "arch" => "amd64"
          }
        ]
      }
    }

    http_get = fn _url, _opts ->
      {:ok, %Req.Response{status: 200, body: @artifact_body}}
    end

    upload_object = fn metadata, data, _opts ->
      assert metadata.key =~ "-linux-amd64-artifact"
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

    assert [%{"file_name" => "linux-amd64-artifact"}] =
             get_in(mirrored_attrs, [:metadata, "storage", "artifacts"])
  end
end
