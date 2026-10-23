ExUnit.start()

defmodule ServiceRadarCoreElx.CameraRecording.ProviderProbeTest do
  use ExUnit.Case, async: true

  alias ServiceRadarCoreElx.CameraRecording.ProviderProbe
  alias ServiceRadarCoreElx.CameraRecording.ProviderProbeHTTP

  @moduletag :tmp_dir
  @run String.duplicate("a", 32)

  setup do
    {:ok, _} = Application.ensure_all_started(:ssl)
    alg = [{:digest, :sha256}, {:key, {:namedCurve, :secp256r1}}]
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}

    certs =
      :public_key.pkix_test_data(%{
        server_chain: %{root: alg, intermediates: [], peer: alg ++ [extensions: [san]]},
        client_chain: %{root: alg, intermediates: [], peer: alg}
      })

    {:ok, store} = Agent.start_link(fn -> %{objects: %{}, uploads: %{}, requests: [], mode: :normal} end)
    {:ok, listener} = :ssl.listen(0, certs.server_config ++ [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :ssl.sockname(listener)
    server = spawn_link(fn -> accept(listener, store) end)
    {:ok, proxy_listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, {_, proxy_port}} = :inet.sockname(proxy_listener)
    proxy = spawn_link(fn -> proxy_accept(proxy_listener, port) end)

    on_exit(fn ->
      :ssl.close(listener)
      Process.exit(server, :kill)
      :gen_tcp.close(proxy_listener)
      Process.exit(proxy, :kill)
    end)

    {:ok, config} =
      ProviderProbe.configuration(%{
        "run_id" => @run,
        "endpoint" => "https://localhost:#{port}",
        "region" => "test-region",
        "writer_a" => key("writer-a"),
        "writer_b" => key("writer-b"),
        "reader_a" => key("reader-a")
      })

    config = %{
      config
      | proxy: %{scheme: :http, host: "127.0.0.1", port: proxy_port},
        cacerts: Keyword.fetch!(certs.client_config, :cacerts)
    }

    %{config: config, store: store}
  end

  test "real TLS workflow checks bytes, denies unsafe roles, aborts and cleans exact owned objects", ctx do
    path = Path.join(ctx.tmp_dir, "cleanup.json")

    assert {:ok,
            %{
              status: :passed,
              checks: checks,
              recorder_credentials: :unsupported,
              explicit_sse_s3: :not_tested,
              atomic_no_overwrite: :not_tested
            }} =
             ProviderProbe.run(ctx.config, path)

    assert checks.range_identity_hash == :passed
    assert checks.multipart == :passed
    assert checks.multipart_abort == :passed
    assert checks.cleanup == :passed
    assert %{objects: objects, uploads: uploads, requests: requests} = Agent.get(ctx.store, & &1)
    assert objects == %{}
    assert uploads == %{}

    assert Enum.any?(requests, fn {method, _, headers} ->
             method == "GET" and headers["range"] == "bytes=5242864-5242895"
           end)

    assert Enum.any?(requests, fn {_, _, headers} ->
             String.contains?(headers["authorization"] || "", "if-match;range")
           end)

    assert Enum.any?(requests, fn {method, _, headers} ->
             method == "PUT" and headers["content-md5"] == "AAAAAAAAAAAAAAAAAAAAAA==" and
               String.contains?(headers["authorization"] || "", "content-md5;")
           end)

    journal = File.read!(path)
    refute journal =~ "invented-secret"
    assert %{"objects" => [], "uploads" => [], "pending_uploads" => []} = Jason.decode!(journal)
    assert {:error, :eexist} = ProviderProbe.run(ctx.config, path)
  end

  test "missing default-encryption evidence and a 200 range fallback fail, both still clean", ctx do
    for mode <- [:no_encryption_header, :range_fallback] do
      Agent.update(ctx.store, &%{&1 | mode: mode})

      assert {:ok, %{status: :failed, checks: checks}} =
               ProviderProbe.run(ctx.config, Path.join(ctx.tmp_dir, to_string(mode)))

      assert checks.cleanup == :passed

      if mode == :no_encryption_header,
        do: assert(checks.encryption == :not_confirmed and checks.multipart_encryption == :not_confirmed),
        else: assert(checks.range_identity_hash == :failed)

      assert Agent.get(ctx.store, & &1.objects) == %{}
    end
  end

  test "an unexpectedly permitted reader write fails the denial check and deletes its actual artifact", ctx do
    Agent.update(ctx.store, &%{&1 | mode: :reader_can_write})

    assert {:ok, %{status: :failed, checks: %{roles: :failed, cleanup: :passed}}} =
             ProviderProbe.run(ctx.config, Path.join(ctx.tmp_dir, "cleanup.json"))

    assert Agent.get(ctx.store, & &1.objects) == %{}
  end

  test "redirects, oversized error bodies and timeouts are bounded without returning private response text", ctx do
    for {mode, expected} <- [redirect: :redirect_refused, oversized: :response_too_large, stall: :request_timeout] do
      Agent.update(ctx.store, &%{&1 | mode: mode})

      timeout = if mode == :stall, do: 100, else: 2_000

      assert {:error, ^expected} =
               ProviderProbeHTTP.request(ctx.config, :put, ctx.config.endpoint <> "/transport", [], "x", timeout, 64)
    end
  end

  test "invalid binding is rejected before opening a cleanup journal", ctx do
    assert {:error, :invalid_input} = ProviderProbe.configuration(%{"run_id" => "not-a-run"})
    assert {:error, :invalid_journal} = ProviderProbe.run(ctx.config, nil)
  end

  test "versioning drift preserves cleanup authority instead of creating delete markers", ctx do
    Agent.update(ctx.store, &%{&1 | mode: :versioning_drift})
    path = Path.join(ctx.tmp_dir, "cleanup.json")
    assert {:ok, %{status: :failed, checks: %{cleanup: :incomplete}}} = ProviderProbe.run(ctx.config, path)
    assert %{"objects" => objects} = Jason.decode!(File.read!(path))
    assert %{"bucket" => "a", "key" => "small"} in objects
    assert Agent.get(ctx.store, &Map.has_key?(&1.objects, "/sr-vms-probe-#{@run}-a/#{@run}/small"))
  end

  test "an ignored bad checksum is unsupported while independent multipart checks still run", ctx do
    Agent.update(ctx.store, &%{&1 | mode: :ignore_checksum})

    assert {:ok, %{status: :failed, checks: checks}} =
             ProviderProbe.run(ctx.config, Path.join(ctx.tmp_dir, "cleanup.json"))

    assert %{checksum_rejection: :unsupported, multipart: :passed, cleanup: :passed} = checks
    assert Agent.get(ctx.store, & &1.objects) == %{}
  end

  test "existing content is refused and never becomes cleanup authority", ctx do
    foreign = "/sr-vms-probe-#{@run}-a/unrelated/invented-object"
    Agent.update(ctx.store, &put_in(&1.objects[foreign], "invented pre-existing bytes"))
    path = Path.join(ctx.tmp_dir, "cleanup.json")

    assert {:ok, %{status: :failed, checks: %{empty_buckets: :failed, cleanup: :passed}}} =
             ProviderProbe.run(ctx.config, path)

    assert Agent.get(ctx.store, & &1.objects) == %{foreign => "invented pre-existing bytes"}
    assert %{"objects" => []} = Jason.decode!(File.read!(path))
  end

  defp key(id), do: %{"access_key_id" => id, "secret_access_key" => "invented-secret-#{id}"}

  # Smokescreen's HTTP/1.0 CONNECT response deliberately has no headers.
  # Exercise the whole provider workflow through that actual socket boundary.
  defp proxy_accept(listener, origin_port) do
    case :gen_tcp.accept(listener) do
      {:ok, client} ->
        with {:ok, request} <- :gen_tcp.recv(client, 0, 2_000),
             true <- String.starts_with?(request, "CONNECT localhost:#{origin_port} "),
             {:ok, origin} <- :gen_tcp.connect({127, 0, 0, 1}, origin_port, [:binary, active: true], 2_000) do
          :ok = :gen_tcp.send(client, "HTTP/1.0 200 OK\r\n\r\n")
          :ok = :inet.setopts(client, active: true)
          bridge(client, origin)
          :gen_tcp.close(origin)
        end

        :gen_tcp.close(client)
        proxy_accept(listener, origin_port)

      _ ->
        :ok
    end
  end

  defp bridge(client, origin) do
    receive do
      {:tcp, ^client, bytes} ->
        :gen_tcp.send(origin, bytes)
        bridge(client, origin)

      {:tcp, ^origin, bytes} ->
        :gen_tcp.send(client, bytes)
        bridge(client, origin)

      {:tcp_closed, _} ->
        :ok

      {:tcp_error, _, _} ->
        :ok
    after
      5_000 -> :ok
    end
  end

  defp accept(listener, store) do
    case :ssl.transport_accept(listener) do
      {:ok, socket} ->
        serve_socket(socket, store)

        accept(listener, store)

      _ ->
        :ok
    end
  end

  defp serve_socket(socket, store) do
    with {:ok, socket} <- :ssl.handshake(socket, 2_000),
         {:ok, method, target, headers, body} <- read_request(socket, "") do
      response = Agent.get_and_update(store, &serve(&1, method, target, headers, body))
      send_response(socket, method, response)
    end

    :ssl.close(socket)
  end

  defp read_request(socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [head, body] ->
        [line | lines] = String.split(head, "\r\n")
        [method, target, _] = String.split(line, " ")

        headers =
          Map.new(lines, fn line ->
            [k, v] = String.split(line, ":", parts: 2)
            {String.downcase(k), String.trim(v)}
          end)

        size = String.to_integer(headers["content-length"] || "0")
        {:ok, body} = read_body(socket, body, size)
        {:ok, method, target, headers, body}

      [_] when byte_size(bytes) < 16_384 ->
        with {:ok, more} <- :ssl.recv(socket, 0, 2_000), do: read_request(socket, bytes <> more)

      _ ->
        {:error, :headers}
    end
  end

  defp read_body(_, bytes, size) when byte_size(bytes) == size, do: {:ok, bytes}

  defp read_body(socket, bytes, size) when size <= 6 * 1_024 * 1_024 do
    with {:ok, more} <- :ssl.recv(socket, 0, 5_000), do: read_body(socket, bytes <> more, size)
  end

  defp send_response(_, _, :stall), do: Process.sleep(150)

  defp send_response(socket, method, {status, headers, body}) do
    headers = Map.put_new(headers, "content-length", to_string(byte_size(body)))
    head = Enum.map(headers, fn {key, value} -> "#{key}: #{value}\r\n" end)

    :ssl.send(socket, [
      "HTTP/1.1 #{status} test\r\n",
      head,
      "connection: close\r\n\r\n",
      if(method == "HEAD", do: "", else: body)
    ])
  end

  defp serve(%{mode: :redirect} = state, _, _, _, _),
    do: {{302, %{"location" => "https://invalid.example/secret"}, ""}, state}

  defp serve(%{mode: :oversized} = state, _, _, _, _), do: {{403, %{}, String.duplicate("private response", 100)}, state}
  defp serve(%{mode: :stall} = state, _, _, _, _), do: {:stall, state}

  defp serve(state, method, target, headers, body) do
    state = %{state | requests: [{method, target, headers} | state.requests]}
    uri = URI.parse(target)
    query = URI.decode_query(uri.query || "")

    if denied?(role(headers), uri.path, method, state.mode) do
      {{403, %{}, "<Error><Code>AccessDenied</Code></Error>"}, state}
    else
      route(state, method, uri.path, query, headers, body)
    end
  end

  defp role(headers) do
    auth = headers["authorization"] || ""

    cond do
      String.contains?(auth, "Credential=writer-a/") -> :writer_a
      String.contains?(auth, "Credential=writer-b/") -> :writer_b
      String.contains?(auth, "Credential=reader-a/") -> :reader_a
      true -> :anonymous
    end
  end

  defp denied?(:anonymous, _, _, _), do: true

  defp denied?(role, path, method, mode) do
    bucket_b = String.contains?(path, "-b/") or String.ends_with?(path, "-b")

    bucket_b != (role == :writer_b) or
      (role == :reader_a and method in ["PUT", "DELETE"] and mode != :reader_can_write)
  end

  defp route(state, _, path, %{"list-type" => _}, _, _) do
    count = if Enum.any?(state.objects, fn {key, _} -> String.starts_with?(key, path <> "/") end), do: 1, else: 0
    {{200, %{}, "<ListBucketResult><KeyCount>#{count}</KeyCount></ListBucketResult>"}, state}
  end

  defp route(state, _, _, %{"versioning" => _}, _, _) do
    body =
      if state.mode == :versioning_drift and map_size(state.objects) > 0,
        do: "<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>",
        else: "<VersioningConfiguration/>"

    {{200, %{}, body}, state}
  end

  defp route(state, _, path, %{"uploads" => _}, _, _) do
    id = "invented~receipt-#{map_size(state.uploads)}.+/="

    {{200, %{}, "<InitiateMultipartUploadResult><UploadId>#{id}</UploadId></InitiateMultipartUploadResult>"},
     put_in(state.uploads[id], %{path: path, parts: %{}})}
  end

  defp route(state, method, path, %{"uploadId" => _} = query, _, body),
    do: multipart_request(state, method, path, query, body)

  defp route(%{mode: :ignore_checksum} = state, "PUT", path, _, _, body),
    do: {{200, %{}, ""}, put_in(state.objects[path], body)}

  defp route(state, "PUT", _, _, %{"content-md5" => _}, _),
    do: {{400, %{}, "<Error><Code>BadDigest</Code></Error>"}, state}

  defp route(state, "PUT", path, _, _, body), do: {{200, %{}, ""}, put_in(state.objects[path], body)}
  defp route(state, "DELETE", path, _, _, _), do: {{204, %{}, ""}, %{state | objects: Map.delete(state.objects, path)}}
  defp route(state, method, path, _, headers, _) when method in ["HEAD", "GET"], do: {get(state, path, headers), state}

  defp multipart_request(state, method, path, query, body) do
    id = query["uploadId"]

    cond do
      not Map.has_key?(state.uploads, id) ->
        {{404, %{}, "<Error><Code>NoSuchUpload</Code></Error>"}, state}

      method == "PUT" ->
        {{200, %{"etag" => ~s("part-#{query["partNumber"]}")}, ""},
         put_in(state.uploads[id].parts[query["partNumber"]], body)}

      method == "DELETE" ->
        {{204, %{}, ""}, %{state | uploads: Map.delete(state.uploads, id)}}

      method == "POST" ->
        bytes = state.uploads[id].parts["1"] <> state.uploads[id].parts["2"]

        {{200, %{}, "<CompleteMultipartUploadResult/>"},
         %{state | objects: Map.put(state.objects, path, bytes), uploads: Map.delete(state.uploads, id)}}
    end
  end

  defp get(state, path, headers) do
    case Map.fetch(state.objects, path) do
      :error ->
        {404, %{}, ""}

      {:ok, bytes} ->
        etag = ~s("invented-etag")
        output = %{"etag" => etag, "content-length" => to_string(byte_size(bytes))}

        output =
          if(state.mode == :no_encryption_header,
            do: output,
            else: Map.put(output, "x-amz-server-side-encryption", "AES256")
          )

        cond do
          headers["if-match"] && headers["if-match"] != etag ->
            {412, %{}, ""}

          headers["range"] && state.mode != :range_fallback ->
            [_, first, last] = Regex.run(~r/^bytes=(\d+)-(\d+)$/, headers["range"])
            first = String.to_integer(first)
            last = String.to_integer(last)
            body = binary_part(bytes, first, last - first + 1)

            {206,
             Map.merge(output, %{
               "content-length" => to_string(byte_size(body)),
               "content-range" => "bytes #{first}-#{last}/#{byte_size(bytes)}"
             }), body}

          true ->
            {200, output, bytes}
        end
    end
  end
end
