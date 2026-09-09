defmodule ServiceRadarWebNGWeb.Plugs.UploadGuardTest do
  use ExUnit.Case, async: false

  @moduletag :db_free

  import Plug.Conn

  alias ServiceRadarWebNGWeb.Plugs.UploadGuard

  @png_header <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>
  @jpeg_header <<0xFF, 0xD8, 0xFF, 0xE0>>
  @zip_header <<"PK", 0x03, 0x04>>

  describe "happy path" do
    test "accepts a PNG, sanitizes filename, generates storage name" do
      upload = build_upload("logo.png", @png_header <> :crypto.strong_rand_bytes(64))

      conn =
        :post
        |> Plug.Test.conn("/upload")
        |> add_param("file", upload)
        |> run_guard(param: "file", max_bytes: 10_000, allowed_kinds: [:png, :jpeg])

      refute conn.halted

      metadata = conn.assigns.upload_guard["file"]
      assert metadata.kind == :png
      assert metadata.original_filename == "logo.png"
      assert metadata.sanitized_filename == "logo.png"
      assert metadata.byte_size > 0
      assert metadata.storage_filename =~ ~r/^\d+-[A-Za-z0-9_\-]+\.png$/

      assert conn.params["file"].filename == "logo.png"
    end

    test "guards multiple param fields independently" do
      png = build_upload("a.png", @png_header)
      zip = build_upload("b.zip", @zip_header)

      conn =
        :post
        |> Plug.Test.conn("/upload")
        |> add_param("a", png)
        |> add_param("b", zip)
        |> run_guard(param: ["a", "b"], max_bytes: 10_000, allowed_kinds: [:png, :zip])

      refute conn.halted
      assert conn.assigns.upload_guard["a"].kind == :png
      assert conn.assigns.upload_guard["b"].kind == :zip
    end

    test "no-op when the configured param is missing" do
      conn =
        :post
        |> Plug.Test.conn("/upload")
        |> run_guard(param: "absent", max_bytes: 1_000, allowed_kinds: [:png])

      refute conn.halted
      refute Map.has_key?(conn.assigns, :upload_guard)
    end
  end

  describe "rejection" do
    test "415 when the magic number does not match an allowed kind" do
      # Declared as PNG but the bytes are actually a ZIP signature.
      upload = build_upload("evil.png", @zip_header <> "junk")

      conn =
        :post
        |> Plug.Test.conn("/upload")
        |> add_param("file", upload)
        |> run_guard(param: "file", max_bytes: 10_000, allowed_kinds: [:png])

      assert conn.halted
      assert conn.status == 415
      assert conn.resp_body =~ "unsupported_media_type"
    end

    test "413 when the upload exceeds max_bytes" do
      big = build_upload("big.png", @png_header <> :crypto.strong_rand_bytes(2_000))

      conn =
        :post
        |> Plug.Test.conn("/upload")
        |> add_param("file", big)
        |> run_guard(param: "file", max_bytes: 100, allowed_kinds: [:png])

      assert conn.halted
      assert conn.status == 413
      assert conn.resp_body =~ "upload_too_large"
    end

    test "400 when the param value is not an upload" do
      conn =
        :post
        |> Plug.Test.conn("/upload")
        |> add_param("file", "not-an-upload")
        |> run_guard(param: "file", max_bytes: 100, allowed_kinds: [:png])

      assert conn.halted
      assert conn.status == 400
      assert conn.resp_body =~ "invalid_upload"
    end
  end

  describe "sanitize_filename/1" do
    test "replaces control characters" do
      assert {:ok, "my___file.png"} = UploadGuard.sanitize_filename("my\x01\x02\x03file.png")
    end

    test "strips path separators" do
      assert {:ok, "_etc_passwd"} = UploadGuard.sanitize_filename("/etc/passwd")
    end

    test "truncates to 120 bytes while preserving extension" do
      long_stem = String.duplicate("x", 200)
      input = long_stem <> ".png"

      assert {:ok, result} = UploadGuard.sanitize_filename(input)
      assert byte_size(result) == 120
      assert String.ends_with?(result, ".png")
    end

    test "falls back to 'unnamed' for empty input" do
      assert {:ok, "unnamed"} = UploadGuard.sanitize_filename("")
      assert {:ok, "unnamed"} = UploadGuard.sanitize_filename(nil)
    end
  end

  describe "init/1 validation" do
    test "rejects unknown allowed kinds" do
      assert_raise ArgumentError, ~r/unknown kind/, fn ->
        UploadGuard.init(param: "file", max_bytes: 100, allowed_kinds: [:bogus_kind])
      end
    end
  end

  ## Helpers

  defp run_guard(conn, opts) do
    UploadGuard.call(conn, UploadGuard.init(opts))
  end

  defp build_upload(filename, body) do
    path = Path.join(System.tmp_dir!(), "upload_guard_test_#{System.unique_integer([:positive])}")
    File.write!(path, body)

    on_exit(fn -> File.rm(path) end)

    %Plug.Upload{path: path, filename: filename, content_type: "application/octet-stream"}
  end

  defp add_param(conn, key, value) do
    params =
      case conn.params do
        %Plug.Conn.Unfetched{} -> %{}
        params -> params
      end

    %{conn | params: Map.put(params, key, value)}
  end
end
