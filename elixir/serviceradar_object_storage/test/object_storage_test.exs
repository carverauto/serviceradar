defmodule ServiceRadarObjectStorageTest do
  use ExUnit.Case, async: false

  alias ServiceRadarObjectStorage, as: Storage

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
            lines = Enum.map(response_headers, fn {key, value} -> [key, ": ", value, "\r\n"] end)

            :ok =
              :gen_tcp.send(socket, [
                "HTTP/1.1 ",
                Integer.to_string(status),
                " Test\r\n",
                "content-length: ",
                Integer.to_string(byte_size(response_body)),
                "\r\n",
                lines,
                "\r\n",
                response_body
              ])
        after
          10_000 -> flunk("test did not release the provider response")
        end

        serve(socket, owner)

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
end
