defmodule ServiceRadar.Jobs.SettingsBackupS3UploaderTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Jobs.SettingsBackup.S3Uploader

  @connect_reply "HTTP/1.0 200 OK\r\n\r\n"

  setup do
    {:ok, _} = Application.ensure_all_started(:ssl)
    certs = generate_certs()
    test_pid = self()
    origin = start_tls_origin(certs.server_config, test_pid)
    proxy = start_connect_proxy(origin.port, @connect_reply)

    on_exit(fn ->
      origin.stop.()
      proxy.stop.()
    end)

    %{
      origin: origin,
      proxy: proxy,
      cacerts: Keyword.fetch!(certs.client_config, :cacerts)
    }
  end

  test "uploads versioned snapshot then latest.json with SigV4 headers over CONNECT proxy", ctx do
    body = Jason.encode!(%{"schema_version" => 1, "settings" => %{}})
    sha256 = :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)
    sha_prefix = binary_part(sha256, 0, 12)
    exported_at = ~U[2026-11-22 15:30:05Z]

    dest = %{
      endpoint: "https://localhost:#{ctx.origin.port}",
      bucket: "synthetic-backup-bucket",
      region: "us-east-1",
      prefix: "/tenant-synthetic/",
      access_key_id: "AKIA_SYNTHETIC_ACCESS",
      secret_access_key: "synthetic-secret-access-key"
    }

    assert {:ok, result} =
             S3Uploader.upload(dest, body,
               exported_at: exported_at,
               now: exported_at,
               sha256: sha256,
               sha256_prefix: sha_prefix,
               proxy: %{scheme: :http, host: "127.0.0.1", port: ctx.proxy.port},
               cacerts: ctx.cacerts
             )

    expected_versioned = "tenant-synthetic/settings-export/20261122T153005Z-#{sha_prefix}.json"
    expected_latest = "tenant-synthetic/settings-export/latest.json"

    assert result.object_key == expected_versioned
    assert result.latest_key == expected_latest
    assert result.etag == "\"etag-synthetic-1\""
    assert result.sha256 == sha256

    assert_receive {:origin_put, req1}
    assert req1.path == "/synthetic-backup-bucket/#{expected_versioned}"
    assert req1.body == body
    assert req1.headers["x-amz-content-sha256"] == sha256
    assert req1.headers["content-type"] == "application/json"
    assert String.starts_with?(req1.headers["authorization"], "AWS4-HMAC-SHA256 ")

    assert String.contains?(
             req1.headers["authorization"],
             "Credential=AKIA_SYNTHETIC_ACCESS/20261122/us-east-1/s3/aws4_request"
           )

    assert_receive {:origin_put, req2}
    assert req2.path == "/synthetic-backup-bucket/#{expected_latest}"
    assert req2.body == body
    assert req2.headers["x-amz-content-sha256"] == sha256
  end

  test "stops before uploading latest.json when versioned PUT fails", ctx do
    dest = %{
      endpoint: "https://localhost:#{ctx.origin.port}",
      bucket: "fail-bucket",
      region: "us-east-1",
      prefix: "",
      access_key_id: "AKIA_SYNTHETIC_ACCESS",
      secret_access_key: "synthetic-secret-access-key"
    }

    assert {:error, {:http_status, 403}} =
             S3Uploader.upload(dest, "{}",
               proxy: %{scheme: :http, host: "127.0.0.1", port: ctx.proxy.port},
               cacerts: ctx.cacerts
             )

    assert_receive {:origin_put, req1}
    assert String.starts_with?(req1.path, "/fail-bucket/settings-export/")
    refute_receive {:origin_put, _req2}, 150
  end

  defp generate_certs do
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}
    alg = [{:digest, :sha256}, {:key, {:namedCurve, :secp256r1}}]

    :public_key.pkix_test_data(%{
      server_chain: %{root: alg, intermediates: [], peer: alg ++ [{:extensions, [san]}]},
      client_chain: %{root: alg, intermediates: [], peer: alg}
    })
  end

  defp start_tls_origin(server_config, test_pid) do
    listen_opts =
      server_config ++
        [
          :binary,
          active: false,
          packet: :raw,
          reuseaddr: true,
          ip: {127, 0, 0, 1},
          versions: [:"tlsv1.3", :"tlsv1.2"]
        ]

    {:ok, listener} = :ssl.listen(0, listen_opts)
    {:ok, {_addr, port}} = :ssl.sockname(listener)
    pid = spawn_link(fn -> origin_accept(listener, test_pid) end)
    %{port: port, stop: fn -> stop_proc(pid, fn -> :ssl.close(listener) end) end}
  end

  defp origin_accept(listener, test_pid) do
    case :ssl.transport_accept(listener) do
      {:ok, socket} ->
        case :ssl.handshake(socket, 5_000) do
          {:ok, tls_socket} -> origin_serve(tls_socket, test_pid)
          _ -> :ok
        end

        origin_accept(listener, test_pid)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        origin_accept(listener, test_pid)
    end
  end

  defp origin_serve(socket, test_pid) do
    with {:ok, raw} <- read_full_http_request(socket, "") do
      [head, body] = String.split(raw, "\r\n\r\n", parts: 2)
      [request_line | header_lines] = String.split(head, "\r\n")
      [_method, path | _] = String.split(request_line, " ")

      headers =
        Map.new(header_lines, fn line ->
          [k, v] = String.split(line, ":", parts: 2)
          {String.downcase(String.trim(k)), String.trim(v)}
        end)

      send(test_pid, {:origin_put, %{path: path, headers: headers, body: body}})

      response =
        if String.starts_with?(path, "/fail-bucket/") do
          "HTTP/1.1 403 Forbidden\r\ncontent-length: 6\r\nconnection: close\r\n\r\ndenied"
        else
          "HTTP/1.1 200 OK\r\netag: \"etag-synthetic-1\"\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
        end

      :ssl.send(socket, response)
    end

    :ssl.close(socket)
  end

  defp read_full_http_request(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, body] ->
        expected_len = parse_content_length(head)

        if byte_size(body) >= expected_len do
          {:ok, head <> "\r\n\r\n" <> binary_part(body, 0, expected_len)}
        else
          read_more(socket, acc)
        end

      [_] ->
        read_more(socket, acc)
    end
  end

  defp read_more(socket, acc) do
    case :ssl.recv(socket, 0, 5_000) do
      {:ok, chunk} -> read_full_http_request(socket, acc <> to_string(chunk))
      err -> err
    end
  end

  defp parse_content_length(head) do
    head
    |> String.split("\r\n")
    |> Enum.find_value(0, fn line ->
      case String.split(line, ":", parts: 2) do
        [name, val] ->
          if String.downcase(String.trim(name)) == "content-length" do
            case Integer.parse(String.trim(val)) do
              {len, ""} -> len
              _ -> 0
            end
          end

        _ ->
          nil
      end
    end)
  end

  defp start_connect_proxy(origin_port, reply) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listener)
    pid = spawn_link(fn -> proxy_accept(listener, origin_port, reply) end)
    %{port: port, stop: fn -> stop_proc(pid, fn -> :gen_tcp.close(listener) end) end}
  end

  defp proxy_accept(listener, origin_port, reply) do
    case :gen_tcp.accept(listener) do
      {:ok, client} ->
        handler = spawn(fn -> receive do: (:go -> proxy_handle(client, origin_port, reply)) end)
        :ok = :gen_tcp.controlling_process(client, handler)
        send(handler, :go)
        proxy_accept(listener, origin_port, reply)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        proxy_accept(listener, origin_port, reply)
    end
  end

  defp proxy_handle(client, origin_port, reply) do
    with {:ok, request} <- :gen_tcp.recv(client, 0, 5_000),
         true <- String.starts_with?(to_string(request), "CONNECT "),
         {:ok, upstream} <-
           :gen_tcp.connect(
             {127, 0, 0, 1},
             origin_port,
             [:binary, active: false, packet: :raw],
             5_000
           ) do
      :ok = :gen_tcp.send(client, reply)
      :ok = :inet.setopts(client, active: true)
      :ok = :inet.setopts(upstream, active: true)
      relay(client, upstream)
    else
      _ -> :gen_tcp.close(client)
    end
  end

  defp relay(client, upstream) do
    receive do
      {:tcp, ^client, data} ->
        :gen_tcp.send(upstream, data)
        relay(client, upstream)

      {:tcp, ^upstream, data} ->
        :gen_tcp.send(client, data)
        relay(client, upstream)

      {:tcp_closed, _} ->
        :ok

      {:tcp_error, _, _} ->
        :ok
    after
      15_000 -> :ok
    end
  end

  defp stop_proc(pid, close) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
    close.()
  end
end
