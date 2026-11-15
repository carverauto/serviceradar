defmodule ServiceRadarObjectStorageTest do
  use ExUnit.Case, async: false

  alias ServiceRadarObjectStorage, as: Storage
  alias ServiceRadarObjectStorage.Session

  @moduletag timeout: 60_000

  setup do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(listener)
    owner = self()
    peer = spawn_link(fn -> accept(listener, owner) end)

    config = %{
      host: "127.0.0.1",
      port: port,
      region: "test-region",
      bucket: "synthetic-recordings",
      access_key: "SYNTHETICACCESS",
      secret_key: "synthetic-secret-not-a-credential",
      session_token: nil,
      tls: false,
      concurrency: 1,
      buffer_size: 16_384
    }

    on_exit(fn ->
      Process.exit(peer, :kill)
      :gen_tcp.close(listener)
    end)

    %{config: config}
  end

  test "the loaded NIF sends conditional bytes and returns exact full and ranged reads", %{config: config} do
    assert {:ok, client} = Storage.open(config)
    on_exit(fn -> drain(client) end)
    bytes = :binary.copy(<<3, 17, 29, 41>>, 2048)
    key = "qualification/block.m4s"

    assert {:ok, put_ref} = Storage.put(client, key, bytes)
    assert_receive {:request, peer, :PUT, "/synthetic-recordings/" <> ^key, headers, ^bytes}, 10_000
    assert headers["if-none-match"] == "*"
    assert String.starts_with?(headers["authorization"], "AWS4-HMAC-SHA256 ")
    assert headers["x-amz-checksum-crc64nvme"] == "KEM0ggfxTyw="
    reply(peer, 200, [], "")
    assert_receive {:longshore_reply, ^put_ref, {:ok, :stored}, {queue, elapsed}}, 10_000
    assert queue >= 0 and elapsed >= 0

    assert {:ok, fetch_ref} = Storage.fetch(client, key)
    assert_receive {:request, peer, :GET, "/synthetic-recordings/" <> ^key, _headers, ""}, 10_000
    reply(peer, 200, [], bytes)
    assert_receive {:longshore_reply, ^fetch_ref, {:ok, ^bytes}, _stats}, 10_000

    assert {:ok, range_ref} = Storage.fetch_range(client, key, 3, 18)
    assert_receive {:request, peer, :GET, "/synthetic-recordings/" <> ^key, headers, ""}, 10_000
    assert headers["range"] == "bytes=3-18"
    slice = binary_part(bytes, 3, 16)
    reply(peer, 206, [{"content-range", "bytes 3-18/8192"}], slice)
    assert_receive {:longshore_reply, ^range_ref, {:ok, ^slice}, _stats}, 10_000

    assert {:error, :too_large} = Storage.put(client, key, :binary.copy(<<0>>, 16_385))
    assert {:error, :bad_range} = Storage.fetch_range(client, key, 0, 16_384)
    assert {:closing, :ok} = {Storage.close(client), wait_closed(client)}
    assert {:error, :closed} = Storage.fetch(client, key)
  end

  test "strict put/head/get option, expect, budget, and range decoding rejects invalid maps", %{config: config} do
    assert {:ok, client} = Storage.open(config)
    on_exit(fn -> drain(client) end)

    valid_put = %{no_clobber: true, encryption: :aes256, checksum: {:sha256, :crypto.hash(:sha256, "payload")}}
    valid_expect = %{etag: "\"etag-1\"", version: nil}
    valid_budget = %{timeout_ms: 5_000}

    for bad_put <- [
          nil,
          %{},
          Map.delete(valid_put, :no_clobber),
          Map.put(valid_put, :no_clobber, nil),
          Map.put(valid_put, :no_clobber, "true"),
          Map.put(valid_put, :unknown, true),
          Map.put(valid_put, :encryption, :kms),
          Map.put(valid_put, :encryption, "AES256"),
          Map.put(valid_put, :checksum, {:sha256, "too-short"}),
          Map.put(valid_put, :checksum, {:sha256, :binary.copy(<<0>>, 33)}),
          Map.put(valid_put, :checksum, {:md5, "1234"}),
          Map.put(valid_put, :checksum, "none")
        ] do
      assert {:error, :bad_config} = Storage.put(client, "qualification/strict.m4s", "payload", bad_put, valid_budget)
    end

    for bad_expect <- [
          nil,
          %{},
          %{etag: "\"etag-1\""},
          %{etag: nil, version: nil, extra: 1},
          %{etag: "", version: nil},
          %{etag: "\"bad\r\netag\"", version: nil},
          %{etag: 123, version: nil},
          %{etag: nil, version: ""},
          %{etag: nil, version: "bad\nversion"}
        ] do
      assert {:error, :bad_config} = Storage.head(client, "qualification/strict.m4s", bad_expect, valid_budget)
      assert {:error, :bad_config} = Storage.get(client, "qualification/strict.m4s", nil, bad_expect, valid_budget)
    end

    for bad_budget <- [
          nil,
          %{},
          %{timeout_ms: nil},
          %{timeout_ms: 0},
          %{timeout_ms: -1},
          %{timeout_ms: 600_001},
          %{timeout_ms: 1_000, extra: true},
          %{attempts: 0, timeout_ms: 1_000},
          %{attempts: 5, timeout_ms: 1_000},
          %{attempts: 1, timeout_ms: 0}
        ] do
      assert {:error, :bad_config} = Storage.put(client, "qualification/strict.m4s", "payload", valid_put, bad_budget)
      assert {:error, :bad_config} = Storage.head(client, "qualification/strict.m4s", valid_expect, bad_budget)
      assert {:error, :bad_config} = Storage.get(client, "qualification/strict.m4s", nil, valid_expect, bad_budget)
    end

    for bad_range <- [[0, 10], {0, 10, 20}, {-1, 10}, %{}] do
      assert {:error, :bad_config} =
               Storage.get(client, "qualification/strict.m4s", bad_range, valid_expect, valid_budget)
    end

    assert {:error, :bad_range} = Storage.get(client, "qualification/strict.m4s", {10, 5}, valid_expect, valid_budget)
    assert {:error, :bad_range} = Storage.get(client, "qualification/strict.m4s", {0, 16_384}, valid_expect, valid_budget)
    assert {:error, :too_large} = Storage.put(client, "qualification/strict.m4s", :binary.copy(<<0>>, 16_385), valid_put)
    assert Storage.info(client).outstanding == 0
  end

  test "Session executes verified single-attempt put with SHA-256 and canonical request evidence", %{
    config: config
  } do
    session = start_supervised!({Session, config: config})
    bytes = :binary.copy(<<11, 23, 37, 53>>, 1024)
    digest = :crypto.hash(:sha256, bytes)
    key = "qualification/verified.m4s"

    put_task =
      Task.async(fn ->
        Session.put(session, key, bytes, %{
          no_clobber: true,
          encryption: :aes256,
          checksum: {:sha256, digest}
        })
      end)

    assert_receive {:request, peer, :PUT, "/synthetic-recordings/" <> ^key = path, headers, ^bytes}, 10_000
    assert headers["if-none-match"] == "*"
    assert headers["x-amz-server-side-encryption"] == "AES256"
    assert headers["x-amz-checksum-sha256"] == Base.encode64(digest)
    refute Map.has_key?(headers, "x-amz-checksum-crc64nvme")

    # Model an S3-compatible store that reports AES256 and version "null" without echoing sha256.
    reply(
      peer,
      200,
      [
        {"etag", "\"etag-verified-1\""},
        {"x-amz-version-id", "null"},
        {"x-amz-server-side-encryption", "AES256"},
        {"x-amz-request-id", "req-put-001"}
      ],
      ""
    )

    assert {:ok, put_report, {queue_us, op_us}} = Task.await(put_task, 10_000)
    assert queue_us >= 0 and op_us >= 0
    assert {put_report.sent, put_report.unanswered} == {1, 0}
    assert {put_report.request.method, byte_size(put_report.request.date)} == {"PUT", 16}

    assert put_report.request.canonical_request_sha256 ==
             canonical_sha256("PUT", path, "", headers, put_report.request.signed_headers)

    assert {:answered, put_answer} = put_report.end
    assert {put_answer.status, put_answer.etag, put_answer.version} == {200, "\"etag-verified-1\"", "null"}
    assert {put_answer.request_id, put_answer.encryption} == {"req-put-001", :aes256}
    assert {put_answer.sha256, put_answer.body} == {nil, nil}
  end

  test "Session executes identity-bound head and get without leaking refused XML error bodies", %{
    config: config
  } do
    session = start_supervised!({Session, config: config})
    bytes = :binary.copy(<<11, 23, 37, 53>>, 1024)
    key = "qualification/verified.m4s"

    head_task =
      Task.async(fn ->
        Session.head(session, key, %{etag: "\"etag-verified-1\"", version: "v-explicit"})
      end)

    assert_receive {:request, peer, :HEAD, "/synthetic-recordings/" <> rest, head_headers, ""}, 10_000
    assert rest == key <> "?versionId=v-explicit"
    assert head_headers["if-match"] == "\"etag-verified-1\""

    reply(
      peer,
      200,
      [
        {"etag", "\"etag-verified-1\""},
        {"content-length", Integer.to_string(byte_size(bytes))},
        {"x-amz-server-side-encryption", "AES256"}
      ],
      ""
    )

    assert {:ok, %{end: {:answered, head_answer}}, _stats} = Task.await(head_task, 10_000)
    assert {head_answer.status, head_answer.content_length} == {200, byte_size(bytes)}
    assert {head_answer.etag, head_answer.body} == {"\"etag-verified-1\"", nil}

    slice = binary_part(bytes, 16, 64)

    get_task =
      Task.async(fn ->
        Session.get(session, key, {16, 79}, %{etag: "\"etag-verified-1\"", version: nil})
      end)

    assert_receive {:request, peer, :GET, "/synthetic-recordings/" <> ^key, get_headers, ""}, 10_000
    assert {get_headers["if-match"], get_headers["range"]} == {"\"etag-verified-1\"", "bytes=16-79"}

    reply(
      peer,
      206,
      [
        {"etag", "\"etag-verified-1\""},
        {"content-range", "bytes 16-79/#{byte_size(bytes)}"}
      ],
      slice
    )

    assert {:ok, %{end: {:answered, get_answer}}, _stats} = Task.await(get_task, 10_000)
    assert {get_answer.status, get_answer.body_len, get_answer.body} == {206, 64, slice}
    assert get_answer.content_range == %{first: 16, last: 79, size: byte_size(bytes)}

    xml_error = "<?xml version=\"1.0\"?><Error><Code>PreconditionFailed</Code></Error>"

    refused_task =
      Task.async(fn ->
        Session.get(session, key, {0, 31}, %{etag: "\"stale-etag\"", version: nil})
      end)

    assert_receive {:request, peer, :GET, "/synthetic-recordings/" <> ^key, _headers, ""}, 10_000
    reply(peer, 412, [{"content-type", "application/xml"}], xml_error)

    assert {:ok, %{end: {:answered, refused_answer}}, _stats} = Task.await(refused_task, 10_000)
    assert {refused_answer.status, refused_answer.body, refused_answer.body_len} == {412, nil, byte_size(xml_error)}
  end

  test "Session classifies dropped write replies as unknown and holds token drain across caller timeout", %{
    config: config
  } do
    session = start_supervised!({Session, config: config})
    put_opts = %{no_clobber: true, encryption: nil, checksum: :none}

    dropped_task =
      Task.async(fn ->
        Session.put(session, "qualification/unknown.m4s", "payload", put_opts)
      end)

    assert_receive {:request, peer, :PUT, "/synthetic-recordings/qualification/unknown.m4s", _headers, "payload"}, 10_000
    close_peer_socket(peer)

    assert {:ok, unknown_report, _stats} = Task.await(dropped_task, 10_000)
    assert {unknown_report.end, unknown_report.sent, unknown_report.unanswered} == {{:unknown, :transport}, 1, 1}

    owner = self()
    token = make_ref()

    caller =
      spawn_link(fn ->
        result =
          try do
            Session.get(
              session,
              "qualification/late-reply.m4s",
              nil,
              %{etag: nil, version: nil},
              owner_token: token,
              call_timeout: 25
            )
          catch
            :exit, {:timeout, _} -> :caller_timed_out
          end

        send(owner, {:caller_finished, result})

        receive do
          :release_caller ->
            {:messages, messages} = Process.info(self(), :messages)
            send(owner, {:caller_mailbox, messages})
        end
      end)

    assert_receive {:request, peer, :GET, "/synthetic-recordings/qualification/late-reply.m4s", _headers, ""}, 10_000
    assert_receive {:caller_finished, :caller_timed_out}, 10_000

    :ok = Session.await_token_drain(session, token, self())
    refute_receive {:token_drained, ^token}, 50

    reply(peer, 200, [{"etag", "\"late-etag\""}], :binary.copy(<<9>>, 4096))
    assert_receive {:token_drained, ^token}, 10_000

    send(caller, :release_caller)
    assert_receive {:caller_mailbox, []}, 10_000
  end

  test "supervisor shutdown outlasts the 5 s default and replies with the drained classification", %{
    config: config
  } do
    assert %{shutdown: shutdown} = Supervisor.child_spec({Session, config: config}, [])
    assert shutdown > 30_000

    {:ok, sup} = Supervisor.start_link([{Session, config: config}], strategy: :one_for_one)
    [{_id, session, :worker, _modules}] = Supervisor.which_children(sup)
    session_monitor = Process.monitor(session)
    put_opts = %{no_clobber: true, encryption: nil, checksum: :none}

    put_task =
      Task.async(fn ->
        Session.put(session, "qualification/shutdown.m4s", "synthetic", put_opts)
      end)

    assert_receive {:request, peer, :PUT, "/synthetic-recordings/qualification/shutdown.m4s", _headers, "synthetic"},
                   10_000

    owner = self()
    spawn(fn -> send(owner, {:supervisor_stopped, Supervisor.stop(sup, :normal, :infinity)}) end)

    refute_receive {:DOWN, ^session_monitor, :process, ^session, _reason}, 6_000

    reply(peer, 200, [{"etag", "\"shutdown-etag\""}], "")
    assert {:ok, %{end: {:answered, %{status: 200}}}, _stats} = Task.await(put_task, 10_000)
    assert_receive {:DOWN, ^session_monitor, :process, ^session, :shutdown}, 10_000
    assert_receive {:supervisor_stopped, :ok}, 10_000

    assert {:ok, first} = Storage.open(config)
    assert {:ok, second} = Storage.open(config)
    drain(first)
    drain(second)
  end

  test "a linked non-parent process exiting normally stops Session and closes its client", %{config: config} do
    session = start_supervised!(Supervisor.child_spec({Session, config: config}, restart: :temporary))
    session_monitor = Process.monitor(session)

    linker =
      spawn(fn ->
        Process.link(session)

        receive do
          :exit -> :ok
        end
      end)

    linker_monitor = Process.monitor(linker)
    send(linker, :exit)
    assert_receive {:DOWN, ^linker_monitor, :process, ^linker, :normal}, 10_000
    assert_receive {:DOWN, ^session_monitor, :process, ^session, :normal}, 10_000

    assert {:ok, first} = Storage.open(config)
    assert {:ok, second} = Storage.open(config)
    drain(first)
    drain(second)
  end

  test "caller exit and close retain capacity until the real operation finishes", %{config: config} do
    assert {:ok, client} = Storage.open(config)
    on_exit(fn -> drain(client) end)
    owner = self()

    caller =
      spawn(fn ->
        send(owner, {:admitted, Storage.put(client, "qualification/drain.m4s", "synthetic")})

        receive do
          :exit -> :ok
        end
      end)

    assert_receive {:admitted, {:ok, _ref}}, 10_000
    assert_receive {:request, peer, :PUT, _path, _headers, "synthetic"}, 10_000
    monitor = Process.monitor(caller)
    send(caller, :exit)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
    assert {:error, :busy} = Storage.fetch(client, "qualification/drain.m4s")
    assert :closing = Storage.close(client)
    assert %{accepting: false, outstanding: 1, workers: 1} = Storage.info(client)

    reply(peer, 200, [], "")
    assert :ok = wait_closed(client)
    assert %{outstanding: 0, workers: 0} = Storage.info(client)
  end

  test "the VM-wide client limit is released after shutdown", %{config: config} do
    assert {:ok, first} = Storage.open(config)
    assert {:ok, second} = Storage.open(config)

    on_exit(fn ->
      drain(first)
      drain(second)
    end)

    assert {:error, :busy} = Storage.open(config)
    drain(first)
    assert {:ok, replacement} = Storage.open(config)
    drain(replacement)
  end

  defp canonical_sha256(method, path, query, headers, signed_headers) do
    canonical_headers =
      signed_headers
      |> String.split(";")
      |> Enum.map_join(fn name -> "#{name}:#{String.trim(Map.fetch!(headers, name))}\n" end)

    canonical =
      Enum.join(
        [method, path, query, canonical_headers, signed_headers, "UNSIGNED-PAYLOAD"],
        "\n"
      )

    :crypto.hash(:sha256, canonical)
  end

  defp drain(client) do
    Storage.close(client)
    wait_closed(client)
  end

  defp wait_closed(client), do: wait_closed(client, System.monotonic_time(:millisecond) + 10_000)

  defp wait_closed(client, deadline) do
    if Storage.info(client).workers == 0 do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline, "native workers did not drain"
      Process.sleep(5)
      wait_closed(client, deadline)
    end
  end

  defp accept(listener, owner) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        serve(socket, owner)
        accept(listener, owner)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve(socket, owner) do
    :ok = :inet.setopts(socket, packet: :http_bin)

    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, {:http_request, method, {:abs_path, path}, _version}} ->
        headers = headers(socket, %{})
        :ok = :inet.setopts(socket, packet: :raw)
        length = headers |> Map.get("content-length", "0") |> String.to_integer()
        body = if length == 0, do: "", else: elem(:gen_tcp.recv(socket, length, 10_000), 1)
        send(owner, {:request, self(), method, path, headers, body})

        receive do
          {:reply, status, response_headers, response_body} ->
            has_content_length? =
              Enum.any?(response_headers, fn {key, _} ->
                String.downcase(to_string(key)) == "content-length"
              end)

            lines = Enum.map(response_headers, fn {key, value} -> [key, ": ", value, "\r\n"] end)

            length_line =
              if has_content_length? do
                []
              else
                ["content-length: ", Integer.to_string(byte_size(response_body)), "\r\n"]
              end

            wire_body = if method == :HEAD, do: "", else: response_body

            :ok =
              :gen_tcp.send(socket, [
                "HTTP/1.1 ",
                Integer.to_string(status),
                " Test\r\n",
                length_line,
                lines,
                "\r\n",
                wire_body
              ])

            serve(socket, owner)

          :close_socket ->
            :gen_tcp.close(socket)
        after
          10_000 -> flunk("test did not release the provider response")
        end

      {:error, :closed} ->
        :ok
    end
  end

  defp headers(socket, collected) do
    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, {:http_header, _, name, _, value}} ->
        headers(socket, Map.put(collected, name |> to_string() |> String.downcase(), value))

      {:ok, :http_eoh} ->
        collected
    end
  end

  defp reply(peer, status, headers, body), do: send(peer, {:reply, status, headers, body})
  defp close_peer_socket(peer), do: send(peer, :close_socket)
end
