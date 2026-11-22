defmodule ServiceRadarWebNG.CameraTimelineReader.ArchiveTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Camera.RecordingTimeline.RedactedCredential
  alias ServiceRadarWebNG.CameraTimelineReader
  alias ServiceRadarWebNG.CameraTimelineReader.Archive
  alias ServiceRadarWebNG.CameraTimelineReader.NVRLocal

  @moduletag :db_free
  @moduletag :tmp_dir

  @storage_id "00000000-0000-4000-8000-000000000055"
  @entry_id "00000000-0000-4000-8000-000000000056"
  @block_key String.duplicate("ef", 32)
  @reader_token "synthetic-timeline-archive-reader-token-0123"
  @access_key_id "SYNTHETICTIMELINEREADER01"
  @secret_access_key "invented-timeline-archive-reader-secret"
  @session_token "invented-timeline-archive-session-token"

  setup ctx do
    {:ok, _} = Application.ensure_all_started(:ssl)
    prev_cfg = Application.get_env(:serviceradar_web_ng, :timeline_archive_reader_config)
    prev_readers = Application.get_env(:serviceradar_web_ng, :camera_timeline_readers)

    on_exit(fn ->
      Application.put_env(:serviceradar_web_ng, :timeline_archive_reader_config, prev_cfg)
      Application.put_env(:serviceradar_web_ng, :camera_timeline_readers, prev_readers)
    end)

    %{certs: write_certs(ctx.tmp_dir)}
  end

  test "forwards destination, credential, and plan to POST /v1/timeline-archive-ranges", ctx do
    fragment = "invented-s3-archived-fragment-bytes"
    port = start_reader_peer(ctx.certs, 200, fragment)
    configure(ctx, port)

    assert {:ok, ^fragment} = Archive.fetch_archive(plan(fragment), deadline())

    assert_receive {:archive_reader_request, req}, 2_000
    assert req.request_line == "POST /v1/timeline-archive-ranges HTTP/1.1"
    assert req.headers["authorization"] == "Bearer " <> @reader_token
    assert req.headers["content-type"] == "application/json"

    decoded = Jason.decode!(req.body)
    assert decoded["schema_version"] == 1
    assert decoded["destination"]["bucket"] == "synthetic-archive-bucket"
    assert decoded["credential"]["access_key_id"] == @access_key_id
    assert decoded["credential"]["secret_access_key"] == @secret_access_key
    assert decoded["credential"]["session_token"] == @session_token
    assert decoded["plan"]["storage_id"] == @storage_id
    assert decoded["plan"]["block_key"] == @block_key
    assert decoded["plan"]["object_key"] == "recordings/v1/#{@storage_id}/#{@block_key}/media.m4s"
    assert decoded["plan"]["first"] == 128
    assert decoded["plan"]["last"] == 128 + byte_size(fragment) - 1
    assert decoded["plan"]["sha256"] == digest(fragment)
  end

  test "refuses immediately without connecting when credential_error is set or credential is nil", ctx do
    port = start_reader_peer(ctx.certs, 200, "unused")
    configure(ctx, port)

    bad_err_plan = %{plan("x") | credential_error: {:credential_error, :archive_reader_credential_not_configured}}
    nil_cred_plan = %{plan("x") | credential: nil}

    log =
      capture_log([level: :warning], fn ->
        assert {:error, :reader_unavailable} = Archive.fetch_archive(bad_err_plan, deadline())
        assert {:error, :reader_unavailable} = Archive.fetch_archive(nil_cred_plan, deadline())
      end)

    refute_receive {:archive_reader_request, _}, 100
    refute_leaked_secrets(log)
  end

  test "rejects plain map credentials, missing object_key, and unconfigured app env", ctx do
    port = start_reader_peer(ctx.certs, 200, "unused")
    config_file = configure(ctx, port)

    plain_map_plan = %{
      plan("x")
      | credential: %{access_key_id: @access_key_id, secret_access_key: @secret_access_key}
    }

    key_alias_only_plan =
      "x"
      |> plan()
      |> Map.delete(:object_key)
      |> Map.put(:key, "recordings/v1/#{@storage_id}/#{@block_key}/media.m4s")

    log =
      capture_log([level: :warning], fn ->
        assert {:error, :reader_unavailable} = Archive.fetch_archive(plain_map_plan, deadline())
        assert {:error, :reader_unavailable} = Archive.fetch_archive(key_alias_only_plan, deadline())

        Application.delete_env(:serviceradar_web_ng, :timeline_archive_reader_config)
        prev_env = System.get_env("SERVICERADAR_TIMELINE_ARCHIVE_READER_CONFIG")
        System.put_env("SERVICERADAR_TIMELINE_ARCHIVE_READER_CONFIG", config_file)

        try do
          assert {:error, :reader_unavailable} = Archive.fetch_archive(plan("x"), deadline())
        after
          if prev_env,
            do: System.put_env("SERVICERADAR_TIMELINE_ARCHIVE_READER_CONFIG", prev_env),
            else: System.delete_env("SERVICERADAR_TIMELINE_ARCHIVE_READER_CONFIG")
        end
      end)

    refute_receive {:archive_reader_request, _}, 100
    refute_leaked_secrets(log)
  end

  test "maps 404, 409, 503, and timeout without logging credentials and rejects tampered bytes via CameraTimelineReader",
       ctx do
    fragment = "invented-s3-archived-fragment-bytes"

    cases = [
      {404, ~s({"error":"archive_object_not_found"}), {:error, :not_found}},
      {409, ~s({"error":"archive_integrity_mismatch"}), {:error, :integrity_mismatch}},
      {503, ~s({"error":"archive_read_busy"}), {:error, :reader_unavailable}}
    ]

    for {status, body, expected} <- cases do
      port = start_reader_peer(ctx.certs, status, body)
      configure(ctx, port)

      log =
        capture_log([level: :warning], fn ->
          assert Archive.fetch_archive(plan(fragment), deadline()) == expected
        end)

      assert_receive {:archive_reader_request, _}, 2_000
      refute_leaked_secrets(log)
    end

    tampered_port = start_reader_peer(ctx.certs, 200, "wrong-bytes-of-different-digest-val")
    configure(ctx, tampered_port)

    tampered_log =
      capture_log([level: :warning], fn ->
        assert {:error, :recording_integrity_failed} =
                 CameraTimelineReader.execute_plans([plan(fragment)], :archive, readers: %{archive: Archive})
      end)

    assert_receive {:archive_reader_request, _}, 2_000
    refute_leaked_secrets(tampered_log)

    # Expired deadline fails immediately without connecting.
    port = start_reader_peer(ctx.certs, 200, fragment)
    configure(ctx, port)

    timeout_log =
      capture_log([level: :warning], fn ->
        assert {:error, :reader_unavailable} =
                 Archive.fetch_archive(plan(fragment), System.monotonic_time(:millisecond) - 10)
      end)

    refute_receive {:archive_reader_request, _}, 100
    refute_leaked_secrets(timeout_log)
  end

  test "integrates with CameraTimelineReader.execute_plans including local-to-archive fallback", ctx do
    fragment = "invented-s3-archived-fragment-bytes"
    port = start_reader_peer(ctx.certs, 200, fragment)
    configure(ctx, port)

    Application.put_env(:serviceradar_web_ng, :camera_timeline_readers,
      local: NVRLocal,
      archive: Archive
    )

    assert CameraTimelineReader.archive_reader_installed?()

    local_plan = %{
      copy: :local,
      entry_id: @entry_id,
      provisional?: false,
      expected_length: byte_size(fragment),
      expected_sha256: digest(fragment)
    }

    archive_plan = plan(fragment)

    assert {:ok, %{copy: :archive, copy_header: "archive", bytes: ^fragment}} =
             CameraTimelineReader.execute_plans([local_plan, archive_plan], :auto,
               readers: %{local: fn _plan, _dl -> {:error, :not_found} end, archive: Archive}
             )
  end

  test "runtime.exs installs Archive timeline reader only when SERVICERADAR_TIMELINE_ARCHIVE_READER_CONFIG is set" do
    runtime = Path.expand("../../../config/runtime.exs", __DIR__)
    prev_env = System.get_env("SERVICERADAR_TIMELINE_ARCHIVE_READER_CONFIG")

    on_exit(fn ->
      if prev_env,
        do: System.put_env("SERVICERADAR_TIMELINE_ARCHIVE_READER_CONFIG", prev_env),
        else: System.delete_env("SERVICERADAR_TIMELINE_ARCHIVE_READER_CONFIG")
    end)

    System.delete_env("SERVICERADAR_TIMELINE_ARCHIVE_READER_CONFIG")
    unset_cfg = runtime |> Config.Reader.read!(env: :test, target: :host) |> Keyword.get(:serviceradar_web_ng, [])
    refute Keyword.has_key?(unset_cfg, :timeline_archive_reader_config)
    refute Keyword.has_key?(unset_cfg, :camera_timeline_readers)

    path = "/etc/serviceradar/archive-reader/config/config.json"
    System.put_env("SERVICERADAR_TIMELINE_ARCHIVE_READER_CONFIG", path)
    set_cfg = runtime |> Config.Reader.read!(env: :test, target: :host) |> Keyword.get(:serviceradar_web_ng, [])
    assert Keyword.get(set_cfg, :timeline_archive_reader_config) == path

    assert Keyword.get(set_cfg, :camera_timeline_readers) == [
             local: NVRLocal,
             archive: Archive
           ]
  end

  defp plan(bytes) do
    %{
      copy: :archive,
      entry_id: @entry_id,
      storage_id: @storage_id,
      block_key: @block_key,
      destination: %{
        "schema_version" => 1,
        "provisioning_ref" => "operator:primary",
        "generation" => 1,
        "purpose" => "recording",
        "provider" => "s3_compatible",
        "endpoint" => "https://objects.example.test",
        "region" => "example-1",
        "bucket" => "synthetic-archive-bucket",
        "namespace" => "recordings/v1",
        "archive_format_version" => 1,
        "required_encryption" => "sse_s3_aes256"
      },
      object_key: "recordings/v1/#{@storage_id}/#{@block_key}/media.m4s",
      first: 128,
      last: 128 + byte_size(bytes) - 1,
      object_size: 128 + byte_size(bytes) + 64,
      etag: ~s("synthetic-etag"),
      version_id: "v1",
      expected_length: byte_size(bytes),
      expected_sha256: digest(bytes),
      credential: %RedactedCredential{
        reference: "network_credential_secret:00000000-0000-4000-8000-000000000099",
        generation: 1,
        role: :reader,
        access_key_id: @access_key_id,
        secret_access_key: @secret_access_key,
        session_token: @session_token
      },
      credential_error: nil
    }
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000

  defp digest(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp refute_leaked_secrets(text) do
    refute text =~ @access_key_id
    refute text =~ @secret_access_key
    refute text =~ @session_token
    refute text =~ @reader_token
  end

  defp configure(ctx, port) do
    token_file = Path.join(ctx.tmp_dir, "reader-token")
    config_file = Path.join(ctx.tmp_dir, "timeline-reader.json")
    File.write!(token_file, @reader_token)

    File.write!(
      config_file,
      Jason.encode!(%{
        "schema_version" => 1,
        "storage" => %{
          "base_url" => "https://localhost:#{port}",
          "certfile" => ctx.certs.client_cert,
          "keyfile" => ctx.certs.client_key,
          "cacertfile" => ctx.certs.ca_file,
          "token_file" => token_file
        }
      })
    )

    Application.put_env(:serviceradar_web_ng, :timeline_archive_reader_config, config_file)
    config_file
  end

  defp write_certs(dir) do
    algorithm = [{:digest, :sha256}, {:key, {:namedCurve, :secp256r1}}]
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}

    certs =
      :public_key.pkix_test_data(%{
        server_chain: %{root: algorithm, intermediates: [], peer: algorithm ++ [extensions: [san]]},
        client_chain: %{root: algorithm, intermediates: [], peer: algorithm}
      })

    roots = Enum.uniq(certs.server_config[:cacerts] ++ certs.client_config[:cacerts])
    ca_file = write_pem(dir, "ca.crt", Enum.map(roots, &{:Certificate, &1, :not_encrypted}))
    client_cert = write_pem(dir, "client.crt", [{:Certificate, certs.client_config[:cert], :not_encrypted}])
    {ck_type, ck_der} = certs.client_config[:key]
    client_key = write_pem(dir, "client.key", [{ck_type, ck_der, :not_encrypted}])

    %{
      server_config: certs.server_config,
      roots: roots,
      ca_file: ca_file,
      client_cert: client_cert,
      client_key: client_key
    }
  end

  defp write_pem(dir, name, entries) do
    path = Path.join(dir, name)
    File.write!(path, :public_key.pem_encode(entries))
    path
  end

  defp start_reader_peer(certs, status, body) do
    test_pid = self()

    opts = [
      :binary,
      active: false,
      reuseaddr: true,
      ip: {127, 0, 0, 1},
      cert: certs.server_config[:cert],
      key: certs.server_config[:key],
      cacerts: certs.roots,
      verify: :verify_peer,
      fail_if_no_peer_cert: true
    ]

    {:ok, listen} = :ssl.listen(0, opts)
    {:ok, {_ip, port}} = :ssl.sockname(listen)

    spawn(fn ->
      case :ssl.transport_accept(listen, 5_000) do
        {:ok, sock} ->
          with {:ok, sock} <- :ssl.handshake(sock, 5_000),
               {:ok, req} <- read_http_request(sock) do
            send(test_pid, {:archive_reader_request, req})

            resp = [
              "HTTP/1.1 #{status} OK\r\n",
              "Content-Length: #{byte_size(body)}\r\n",
              "Cache-Control: no-store\r\n",
              "Connection: close\r\n\r\n",
              body
            ]

            :ssl.send(sock, resp)
          end

          :ssl.close(sock)

        _ ->
          :ok
      end

      :ssl.close(listen)
    end)

    port
  end

  defp read_http_request(sock, acc \\ "") do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        [request_line | header_lines] = String.split(head, "\r\n")

        headers =
          Map.new(header_lines, fn line ->
            [k, v] = String.split(line, ":", parts: 2)
            {String.downcase(String.trim(k)), String.trim(v)}
          end)

        content_length = headers |> Map.get("content-length", "0") |> String.to_integer()
        body = read_exact_body(sock, rest, content_length)
        {:ok, %{request_line: request_line, headers: headers, body: body}}

      _ ->
        case :ssl.recv(sock, 0, 2_000) do
          {:ok, chunk} -> read_http_request(sock, acc <> chunk)
          error -> error
        end
    end
  end

  defp read_exact_body(_sock, buf, target) when byte_size(buf) >= target do
    binary_part(buf, 0, target)
  end

  defp read_exact_body(sock, buf, target) do
    case :ssl.recv(sock, 0, 2_000) do
      {:ok, chunk} -> read_exact_body(sock, buf <> chunk, target)
      _ -> buf
    end
  end
end
