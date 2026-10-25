ExUnit.start()

defmodule ServiceRadarCoreElx.CameraRecording.ProviderProbeTest do
  use ExUnit.Case, async: true

  alias ServiceRadarCoreElx.CameraRecording.ProviderProbe
  alias ServiceRadarCoreElx.CameraStorage.HTTP

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

    {:ok, store} = Agent.start_link(fn -> %{objects: %{}, uploads: %{}, requests: [], races: %{}, mode: :normal} end)
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
              explicit_sse_s3: :passed,
              atomic_no_overwrite: :passed,
              diagnostic_requests: 75,
              cleanup_requests: 21,
              body_budget_charged_bytes: body_bytes
            }} =
             ProviderProbe.run(ctx.config, path)

    assert %{
             range_identity_hash: :passed,
             multipart: :passed,
             multipart_abort: :passed,
             conditional_put: :passed,
             conditional_multipart: :passed,
             explicit_sse_s3_put: :passed,
             explicit_sse_s3_multipart: :passed,
             cleanup: :passed
           } = checks

    assert body_bytes < 20 * 1_024 * 1_024
    assert %{objects: objects, uploads: uploads, requests: requests, races: races} = Agent.get(ctx.store, & &1)
    assert {objects, uploads} == {%{}, %{}}
    assert Enum.sort(Enum.map(races, fn {_, arrivals} -> length(arrivals) end)) == [2, 2]

    for {method, target, headers} <- requests do
      for name <- ["if-none-match", "x-amz-server-side-encryption"], Map.has_key?(headers, name) do
        assert headers[name] == if(name == "if-none-match", do: "*", else: "AES256")
        assert [_, signed] = Regex.run(~r/SignedHeaders=([^,]+)/, headers["authorization"])
        assert name in String.split(signed, ";")
      end

      if target =~ "/explicit-" and (method == "PUT" or target =~ "?uploads") and not (target =~ "uploadId=") do
        assert headers["x-amz-server-side-encryption"] == "AES256"
      end
    end

    assert Enum.count(requests, fn {method, _, h} -> method == "PUT" and h["if-none-match"] == "*" end) == 3
    assert Enum.count(requests, fn {method, _, h} -> method == "POST" and h["if-none-match"] == "*" end) == 3

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

      if mode == :no_encryption_header do
        assert checks.encryption == :not_confirmed and checks.multipart_encryption == :not_confirmed
        assert checks.explicit_sse_s3_put == :not_confirmed and checks.explicit_sse_s3_multipart == :not_confirmed
      else
        assert checks.range_identity_hash == :failed
      end

      assert Agent.get(ctx.store, & &1.objects) == %{}
    end
  end

  for {mode, check} <- [
        ignore_put_condition: :conditional_put,
        corrupt_put_precondition: :conditional_put,
        race_put_double_success: :conditional_put,
        ignore_multipart_condition: :conditional_multipart,
        corrupt_multipart_precondition: :conditional_multipart,
        race_multipart_double_success: :conditional_multipart
      ] do
    @tag mode: mode, check: check
    test "#{mode} fails the conditional contract and cleans its actual artifacts", ctx do
      Agent.update(ctx.store, &%{&1 | mode: ctx.mode})

      assert {:ok, %{status: :failed, checks: checks, diagnostic_requests: diagnostics, cleanup_requests: cleanup}} =
               ProviderProbe.run(ctx.config, Path.join(ctx.tmp_dir, "cleanup.json"))

      assert checks[ctx.check] == :failed
      assert checks.cleanup == :passed
      assert diagnostics <= 80 and cleanup <= 30
      assert Agent.get(ctx.store, &{&1.objects, &1.uploads}) == {%{}, %{}}
    end
  end

  test "an embedded completion error in HTTP 200 is not a successful upload", ctx do
    Agent.update(ctx.store, &%{&1 | mode: :embedded_error})

    assert {:ok,
            %{
              status: :failed,
              checks: %{multipart: :failed, cleanup: :passed},
              failures: %{multipart: :multipart_completion_unproven}
            }} =
             ProviderProbe.run(ctx.config, Path.join(ctx.tmp_dir, "cleanup.json"))

    assert Agent.get(ctx.store, &{&1.objects, &1.uploads}) == {%{}, %{}}
  end

  test "ambiguous initiation and denied cleanup retain exact durable authority", ctx do
    for mode <- [:ambiguous_initiation, :cleanup_denied] do
      Agent.update(ctx.store, &%{&1 | mode: mode, objects: %{}, uploads: %{}, races: %{}})
      path = Path.join(ctx.tmp_dir, to_string(mode))

      assert {:ok, %{status: :failed, checks: %{cleanup: :incomplete}, cleanup_requests: count}} =
               ProviderProbe.run(ctx.config, path)

      assert count <= 30
      receipt = Jason.decode!(File.read!(path))

      if mode == :ambiguous_initiation do
        assert receipt["pending_uploads"] == ["multipart"]
        assert map_size(Agent.get(ctx.store, & &1.uploads)) == 1
      else
        assert receipt["objects"] != [] and receipt["uploads"] != []
      end
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
               HTTP.request(ctx.config, :put, ctx.config.endpoint <> "/transport", [], "x", timeout, 64)
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
        pid = spawn_link(fn -> receive do: ({:socket, socket} -> proxy_socket(socket, origin_port)) end)
        :ok = :gen_tcp.controlling_process(client, pid)
        send(pid, {:socket, client})
        proxy_accept(listener, origin_port)

      _ ->
        :ok
    end
  end

  defp proxy_socket(client, origin_port) do
    with {:ok, request} <- :gen_tcp.recv(client, 0, 2_000),
         true <- String.starts_with?(request, "CONNECT localhost:#{origin_port} "),
         {:ok, origin} <- :gen_tcp.connect({127, 0, 0, 1}, origin_port, [:binary, active: true], 2_000) do
      :ok = :gen_tcp.send(client, "HTTP/1.0 200 OK\r\n\r\n")
      :ok = :inet.setopts(client, active: true)
      bridge(client, origin)
      :gen_tcp.close(origin)
    end

    :gen_tcp.close(client)
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
        pid = spawn_link(fn -> receive do: ({:socket, socket} -> serve_socket(socket, store)) end)
        :ok = :ssl.controlling_process(socket, pid)
        send(pid, {:socket, socket})
        accept(listener, store)

      _ ->
        :ok
    end
  end

  defp serve_socket(socket, store) do
    with {:ok, socket} <- :ssl.handshake(socket, 2_000),
         {:ok, method, target, headers, body} <- read_request(socket, "") do
      await_contender(store, method, target)
      response = Agent.get_and_update(store, &serve(&1, method, target, headers, body))
      send_response(socket, method, response)
    end

    :ssl.close(socket)
  end

  # Neither racing request can receive its response before both have arrived
  # through independent TLS/CONNECT sockets. The store still serializes commits.
  defp await_contender(store, method, target) do
    path = URI.parse(target).path

    if (method == "PUT" and String.ends_with?(path, "/put-race")) or
         (method == "POST" and String.ends_with?(path, "/multipart-race") and String.contains?(target, "uploadId=")) do
      caller = self()

      arrivals =
        Agent.get_and_update(store, fn state ->
          arrivals = [caller | Map.get(state.races, path, [])]
          {arrivals, put_in(state.races[path], arrivals)}
        end)

      if length(arrivals) == 2, do: Enum.each(arrivals, &send(&1, {:contenders, path}))

      receive do
        {:contenders, ^path} -> :ok
      after
        5_000 -> raise "the second conditional writer never reached the fixture"
      end
    end
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
    receipt = if(state.mode == :ambiguous_initiation, do: "invented&amp;opaque", else: id)

    {{200, %{}, "<InitiateMultipartUploadResult><UploadId>#{receipt}</UploadId></InitiateMultipartUploadResult>"},
     put_in(state.uploads[id], %{path: path, parts: %{}})}
  end

  defp route(state, method, path, %{"uploadId" => _} = query, headers, body),
    do: multipart_request(state, method, path, query, headers, body)

  defp route(%{mode: :ignore_checksum} = state, "PUT", path, _, %{"content-md5" => _}, body),
    do: {{200, %{}, ""}, put_in(state.objects[path], body)}

  defp route(state, "PUT", _, _, %{"content-md5" => _}, _),
    do: {{400, %{}, "<Error><Code>BadDigest</Code></Error>"}, state}

  defp route(state, "PUT", path, _, headers, body) do
    if headers["if-none-match"] == "*" and Map.has_key?(state.objects, path) and
         state.mode != :ignore_put_condition and
         not (state.mode == :race_put_double_success and String.ends_with?(path, "/put-race")) do
      state = if state.mode == :corrupt_put_precondition, do: put_in(state.objects[path], body), else: state
      {precondition_response(), state}
    else
      {{200, %{}, ""}, put_in(state.objects[path], body)}
    end
  end

  defp route(%{mode: :cleanup_denied} = state, "DELETE", _, _, _, _), do: {{403, %{}, ""}, state}
  defp route(state, "DELETE", path, _, _, _), do: {{204, %{}, ""}, %{state | objects: Map.delete(state.objects, path)}}
  defp route(state, method, path, _, headers, _) when method in ["HEAD", "GET"], do: {get(state, path, headers), state}

  defp multipart_request(state, method, path, query, headers, body) do
    if Map.has_key?(state.uploads, query["uploadId"]) do
      multipart_operation(state, method, path, query, headers, body)
    else
      {{404, %{}, "<Error><Code>NoSuchUpload</Code></Error>"}, state}
    end
  end

  defp multipart_operation(state, "PUT", _, query, _, body) do
    {{200, %{"etag" => ~s("part-#{query["partNumber"]}")}, ""},
     put_in(state.uploads[query["uploadId"]].parts[query["partNumber"]], body)}
  end

  defp multipart_operation(%{mode: :cleanup_denied} = state, "DELETE", _, _, _, _), do: {{403, %{}, ""}, state}

  defp multipart_operation(state, "DELETE", _, query, _, _),
    do: {{204, %{}, ""}, %{state | uploads: Map.delete(state.uploads, query["uploadId"])}}

  defp multipart_operation(%{mode: :embedded_error} = state, "POST", path, query, _, _) do
    {{200, %{}, "<Error><Code>InternalError</Code><Message>Not a <CompleteMultipartUploadResult/></Message></Error>"},
     complete_upload(state, path, query["uploadId"])}
  end

  defp multipart_operation(state, "POST", path, query, headers, _) do
    if headers["if-none-match"] == "*" and Map.has_key?(state.objects, path) and
         state.mode != :ignore_multipart_condition and
         not (state.mode == :race_multipart_double_success and String.ends_with?(path, "/multipart-race")) do
      state =
        if(state.mode == :corrupt_multipart_precondition,
          do: complete_upload(state, path, query["uploadId"]),
          else: state
        )

      {precondition_response(), state}
    else
      {{200, %{}, "<CompleteMultipartUploadResult/>"}, complete_upload(state, path, query["uploadId"])}
    end
  end

  defp complete_upload(state, path, id) do
    bytes =
      state.uploads[id].parts
      |> Enum.sort_by(fn {number, _} -> String.to_integer(number) end)
      |> Enum.map_join(fn {_, bytes} -> bytes end)

    %{state | objects: Map.put(state.objects, path, bytes), uploads: Map.delete(state.uploads, id)}
  end

  defp precondition_response, do: {412, %{}, "<Error><Code>PreconditionFailed</Code></Error>"}

  defp get(state, path, headers) do
    case Map.fetch(state.objects, path) do
      :error ->
        {404, %{}, ""}

      {:ok, bytes} ->
        etag = ~s("#{Base.encode16(:crypto.hash(:sha256, bytes))}")
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
