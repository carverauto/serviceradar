defmodule ServiceRadar.HTTP.EgressClientTest do
  @moduledoc """
  Guards the transport that `SERVICERADAR_EGRESS_PROXY` actually puts in front of
  every external fetch.

  The failure this exists for reached demo because nothing tested a CONNECT
  proxy: `ReleaseArtifactMirror`'s tests inject `http_get`, so they never open a
  socket. What broke was invisible at that seam -- a proxy that answers CONNECT
  with `HTTP/1.0 200 OK` and no headers, which is what `elazarl/goproxy` (and so
  Smokescreen) sends, made Mint close the tunnel socket before upgrading it. The
  operator saw `%Req.TransportError{reason: {:dtls_upgrade, :notsup}}`, which
  names neither the proxy nor the closed socket.

  So the proxy here replies with exactly those 19 bytes.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.HTTP.EgressClient
  alias ServiceRadar.Inventory.AdvisoryFeeds.Acquisition
  alias ServiceRadar.Observability.GeoLiteMmdbDownloadWorker
  alias ServiceRadar.Observability.IpinfoMmdbDownloadWorker

  @goproxy_connect_reply "HTTP/1.0 200 OK\r\n\r\n"
  @body "synthetic-release-artifact"
  @stall_body String.duplicate(@body, 4_096)

  setup do
    {:ok, _} = Application.ensure_all_started(:ssl)
    certs = generate_certs()
    origin = start_tls_origin(certs.server_config)
    proxy = start_connect_proxy(origin.port, @goproxy_connect_reply)
    profile = unique_profile()

    on_exit(fn ->
      origin.stop.()
      proxy.stop.()
      :inets.stop(:httpc, profile)
    end)

    %{
      origin: origin,
      proxy: proxy,
      profile: profile,
      cacerts: Keyword.fetch!(certs.client_config, :cacerts)
    }
  end

  defp opts(ctx, extra) do
    Keyword.merge(
      [
        proxy: %{scheme: :http, host: "127.0.0.1", port: ctx.proxy.port},
        profile: ctx.profile,
        cacerts: ctx.cacerts,
        into: fn {:data, chunk}, acc ->
          send(self(), {:chunk, chunk})
          {:cont, acc}
        end,
        receive_timeout: 15_000
      ],
      extra
    )
  end

  test "tunnels through a proxy that answers CONNECT with HTTP/1.0 and no headers", ctx do
    assert {:ok, %Req.Response{status: 200, body: ""}} =
             EgressClient.get("https://localhost/artifact.tar.gz", opts(ctx, []))

    assert collect_chunks() == @body
  end

  @tag :tmp_dir
  test "acquires CISA through CONNECT and cleans up failed transfers", ctx do
    previous_root = System.get_env("SERVICERADAR_ADVISORY_STAGING_DIR")
    System.put_env("SERVICERADAR_ADVISORY_STAGING_DIR", ctx.tmp_dir)

    on_exit(fn ->
      if previous_root do
        System.put_env("SERVICERADAR_ADVISORY_STAGING_DIR", previous_root)
      else
        System.delete_env("SERVICERADAR_ADVISORY_STAGING_DIR")
      end
    end)

    download_opts = opts(ctx, timeout_ms: 2_000)

    assert {:ok, acquired} =
             Acquisition.acquire_cisa(
               "https://localhost/cisa.json",
               "connect-success",
               download_opts
             )

    assert File.read!(Path.join(acquired.extracted_dir, "cisa-kev.json")) == @body

    assert {:error, {:download_failed, {:http_status, 302}}} =
             Acquisition.acquire_cisa(
               "https://localhost/redirect",
               "connect-redirect",
               download_opts
             )

    refute File.exists?(Path.join([ctx.tmp_dir, "cisa-kev", "connect-redirect"]))

    assert {:error, {:download_failed, :timeout}} =
             Acquisition.acquire_cisa(
               "https://localhost/stall",
               "connect-timeout",
               download_opts
             )

    refute File.exists?(Path.join([ctx.tmp_dir, "cisa-kev", "connect-timeout"]))
  end

  test "returns the redirect instead of following it", ctx do
    assert {:ok, %Req.Response{status: 302} = response} =
             EgressClient.get("https://localhost/redirect", opts(ctx, []))

    assert Req.Response.get_header(response, "location") == ["https://localhost/artifact.tar.gz"]
  end

  @tag :tmp_dir
  test "downloads to a file through the tunnel, following a redirect", ctx do
    dest = Path.join(ctx.tmp_dir, "GeoLite2-ASN.mmdb")

    assert {:ok, ^dest} =
             EgressClient.download_to_file("https://localhost/redirect", dest, opts(ctx, []))

    assert File.read!(dest) == @body
    refute File.exists?(dest <> ".tmp")
  end

  @tag :tmp_dir
  test "a failed download leaves neither the file nor its temporary", ctx do
    dest = Path.join(ctx.tmp_dir, "GeoLite2-ASN.mmdb")

    assert {:error, {:http_status, 404}} =
             EgressClient.download_to_file("https://localhost/missing", dest, opts(ctx, []))

    refute File.exists?(dest)
    refute File.exists?(dest <> ".tmp")
  end

  test "fetches a whole body through the tunnel, following a redirect", ctx do
    assert {:ok, %Req.Response{status: 200, body: @body}} =
             EgressClient.fetch_body("https://localhost/redirect", opts(ctx, []))
  end

  test "returns a non-2xx status with its body for the caller to judge", ctx do
    assert {:ok, %Req.Response{status: 404, body: "not found"}} =
             EgressClient.fetch_body("https://localhost/missing", opts(ctx, []))
  end

  test "stops following redirects after :max_redirects", ctx do
    assert {:error, :too_many_redirects} =
             EgressClient.fetch_body("https://localhost/loop", opts(ctx, max_redirects: 3))
  end

  # The MMDB downloads failed on every proxied deployment: they rode the shared
  # Finch pool, which could not tunnel through this proxy.
  @tag :tmp_dir
  test "downloads a GeoLite database through the tunnel", ctx do
    dest = Path.join(ctx.tmp_dir, "GeoLite2-ASN.mmdb")

    assert {:ok, ^dest} =
             GeoLiteMmdbDownloadWorker.download_file(
               "https://localhost/redirect",
               dest,
               opts(ctx, [])
             )

    assert File.read!(dest) == @body
  end

  @tag :tmp_dir
  test "downloads the ipinfo database through the tunnel", ctx do
    dest = Path.join(ctx.tmp_dir, "ipinfo_lite.mmdb")

    assert {:ok, ^dest} =
             IpinfoMmdbDownloadWorker.download_file(
               "https://localhost/redirect",
               dest,
               opts(ctx, [])
             )

    assert File.read!(dest) == @body
  end

  test "refuses a redirect off HTTPS", ctx do
    assert {:error, {:insecure_redirect, "http://localhost/artifact.tar.gz"}} =
             EgressClient.fetch_body("https://localhost/insecure-redirect", opts(ctx, []))
  end

  test "mirrors a release through the CONNECT tunnel with verified artifact bytes", ctx do
    digest = :sha256 |> :crypto.hash(@body) |> Base.encode16(case: :lower)

    attrs = %{
      version: "1.2.3",
      manifest: %{
        "artifacts" => [
          %{
            "url" => "https://localhost/artifact.tar.gz",
            "sha256" => digest,
            "os" => "linux",
            "arch" => "amd64"
          }
        ]
      }
    }

    assert {:ok, mirrored} =
             ServiceRadar.Edge.ReleaseArtifactMirror.prepare_publish_attrs(attrs,
               validate_url: fn _ -> :ok end,
               http_get: fn url, download_opts ->
                 EgressClient.get(url, opts(ctx, download_opts))
               end,
               upload_object: fn metadata, bytes, _ ->
                 assert bytes == @body
                 assert metadata.sha256 == digest
                 send(self(), {:uploaded, metadata.key})
                 {:ok, %Proto.UploadObjectResponse{}}
               end
             )

    assert_receive {:uploaded, key}

    assert %{"status" => "mirrored", "artifacts" => [%{"object_key" => ^key}]} =
             mirrored.metadata["storage"]
  end

  test "streams the body through :into so a caller can cap it mid-flight", ctx do
    parent = self()

    into = fn {:data, chunk}, {req, resp} ->
      send(parent, {:chunk, chunk})
      {:cont, {req, resp}}
    end

    assert {:ok, %Req.Response{status: 200}} =
             EgressClient.get("https://localhost/artifact.tar.gz", opts(ctx, into: into))

    assert collect_chunks() == @body
  end

  test "stops the transfer when it exceeds :max_bytes", ctx do
    assert {:error, :response_too_large} =
             EgressClient.get("https://localhost/artifact.tar.gz", opts(ctx, max_bytes: 4))
  end

  # The other branch of configure_proxy/2. It matters on its own: :httpc has no
  # option value meaning "no proxy", so getting this wrong fails every
  # deployment that does not set SERVICERADAR_EGRESS_PROXY.
  test "connects directly when no proxy is configured", ctx do
    assert {:ok, %Req.Response{status: 200, body: ""}} =
             EgressClient.get(
               "https://localhost:#{ctx.origin.port}/artifact.tar.gz",
               opts(ctx, proxy: nil)
             )

    assert collect_chunks() == @body
  end

  test "rejects an origin certificate that does not chain to the given anchors", ctx do
    %{client_config: other} = generate_certs()

    assert {:error, _reason} =
             EgressClient.get(
               "https://localhost/artifact.tar.gz",
               opts(ctx, cacerts: Keyword.fetch!(other, :cacerts))
             )
  end

  test "allows a progressing transfer to exceed the receive timeout", ctx do
    assert {:ok, %Req.Response{status: 200, body: ""}} =
             EgressClient.get("https://localhost/slow", opts(ctx, receive_timeout: 2_000))

    assert collect_chunks() == String.duplicate(@body, 5)
  end

  test "times out while waiting for the next chunk", ctx do
    assert {:error, :timeout} =
             EgressClient.get("https://localhost/stall", opts(ctx, receive_timeout: 2_000))

    assert collect_chunks() == @stall_body
  end

  test "does not deliver more chunks while the consumer is busy", ctx do
    into = fn {:data, chunk}, acc ->
      Process.sleep(2_400)
      refute_received {:http, {_, :stream, _}}
      send(self(), {:chunk, chunk})
      {:cont, acc}
    end

    assert {:ok, %Req.Response{status: 200}} =
             EgressClient.get(
               "https://localhost/slow",
               opts(ctx, into: into, receive_timeout: 2_000)
             )

    assert collect_chunks() == String.duplicate(@body, 5)
  end

  defp collect_chunks(acc \\ "") do
    receive do
      {:chunk, chunk} -> collect_chunks(acc <> chunk)
    after
      0 -> acc
    end
  end

  defp unique_profile do
    String.to_atom("egress_client_test_#{System.unique_integer([:positive])}")
  end

  # `localhost` in a subjectAltName, so the hostname check under
  # `verify: :verify_peer` is exercised rather than disabled.
  #
  # The key/digest are explicit because `pkix_test_data/1` otherwise generates an
  # ECDSA-with-SHA1 chain, and TLS 1.3 removed SHA-1 signature algorithms: the
  # origin answers the handshake with `unable_to_supply_acceptable_cert`, which
  # looks like a client trust failure rather than a test-fixture problem.
  defp generate_certs do
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}
    alg = [{:digest, :sha256}, {:key, {:namedCurve, :secp256r1}}]

    :public_key.pkix_test_data(%{
      server_chain: %{root: alg, intermediates: [], peer: alg ++ [{:extensions, [san]}]},
      client_chain: %{root: alg, intermediates: [], peer: alg}
    })
  end

  defp start_tls_origin(server_config) do
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
    pid = spawn_link(fn -> origin_accept(listener) end)

    %{port: port, stop: fn -> stop(pid, fn -> :ssl.close(listener) end) end}
  end

  defp origin_accept(listener) do
    case :ssl.transport_accept(listener) do
      {:ok, socket} ->
        # Handshake and serve inline: :ssl.recv/3 only works from the socket's
        # controlling process, and transport_accept/handshake leave that as this
        # process. Each test drives one request, so serial accept is enough.
        case :ssl.handshake(socket, 5_000) do
          {:ok, socket} -> origin_serve(socket)
          _ -> :ok
        end

        origin_accept(listener)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        origin_accept(listener)
    end
  end

  defp origin_serve(socket) do
    case :ssl.recv(socket, 0, 5_000) do
      {:ok, request} ->
        request = to_string(request)

        cond do
          String.contains?(request, "/stall") ->
            # Deliver a substantial partial body without waiting for the chunked
            # decoder to emit a tiny chunk before the origin stalls.
            :ssl.send(socket, [
              "HTTP/1.1 200 OK\r\ncontent-length: #{2 * byte_size(@stall_body)}\r\n",
              "connection: close\r\n\r\n",
              @stall_body
            ])

            Process.sleep(5_000)

          String.contains?(request, "/slow") ->
            :ssl.send(
              socket,
              "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n"
            )

            Enum.each(1..5, fn _ ->
              :ssl.send(socket, [Integer.to_string(byte_size(@body), 16), "\r\n", @body, "\r\n"])
              Process.sleep(800)
            end)

            :ssl.send(socket, "0\r\n\r\n")

          true ->
            :ssl.send(socket, origin_response(request))
        end

        :ssl.close(socket)

      _ ->
        :ssl.close(socket)
    end
  end

  defp origin_response(request) do
    cond do
      # Before "/redirect", which it contains.
      String.contains?(request, "/insecure-redirect") ->
        redirect_response("http://localhost/artifact.tar.gz")

      String.contains?(request, "/redirect") ->
        redirect_response("https://localhost/artifact.tar.gz")

      String.contains?(request, "/loop") ->
        redirect_response("https://localhost/loop")

      String.contains?(request, "/missing") ->
        "HTTP/1.1 404 Not Found\r\ncontent-type: text/plain\r\n" <>
          "content-length: 9\r\nconnection: close\r\n\r\nnot found"

      true ->
        "HTTP/1.1 200 OK\r\ncontent-type: application/octet-stream\r\n" <>
          "content-length: #{byte_size(@body)}\r\nconnection: close\r\n\r\n" <> @body
    end
  end

  defp redirect_response(location) do
    "HTTP/1.1 302 Found\r\nlocation: #{location}\r\n" <>
      "content-length: 0\r\nconnection: close\r\n\r\n"
  end

  # An HTTP CONNECT proxy shaped like elazarl/goproxy: it answers with an
  # HTTP/1.0 status line carrying no headers, then relays bytes verbatim.
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

    %{port: port, stop: fn -> stop(pid, fn -> :gen_tcp.close(listener) end) end}
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

      {:tcp_closed, _socket} ->
        :ok

      {:tcp_error, _socket, _reason} ->
        :ok
    after
      15_000 -> :ok
    end
  end

  defp stop(pid, close) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
    close.()
  end
end
