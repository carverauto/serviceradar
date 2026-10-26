defmodule ServiceRadarCoreElx.Test.StorageHTTPFixture do
  @moduledoc false

  def start(tls, handler) do
    tasks =
      ExUnit.Callbacks.start_supervised!(Task.Supervisor, id: make_ref(), restart: :temporary)

    {:ok, socket} = :ssl.listen(0, tls ++ [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :ssl.sockname(socket)
    {:ok, _} = Task.Supervisor.start_child(tasks, fn -> accept(socket, tasks, handler) end)

    ExUnit.Callbacks.on_exit(fn -> :ssl.close(socket) end)

    port
  end

  def proxy(port) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, {_, proxy_port}} = :inet.sockname(socket)

    tasks =
      ExUnit.Callbacks.start_supervised!(Task.Supervisor, id: make_ref(), restart: :temporary)

    {:ok, _} = Task.Supervisor.start_child(tasks, fn -> proxy_accept(socket, port, tasks) end)

    ExUnit.Callbacks.on_exit(fn -> :gen_tcp.close(socket) end)

    %{scheme: :http, host: "127.0.0.1", port: proxy_port}
  end

  defp accept(listener, tasks, handler) do
    case :ssl.transport_accept(listener) do
      {:ok, socket} ->
        {:ok, child} =
          Task.Supervisor.start_child(tasks, fn -> receive do: ({:socket, socket} -> serve(socket, handler)) end)

        :ok = :ssl.controlling_process(socket, child)
        send(child, {:socket, socket})
        accept(listener, tasks, handler)

      _ ->
        :ok
    end
  end

  defp serve(socket, handler) do
    with {:ok, socket} <- :ssl.handshake(socket, 2_000),
         {:ok, request} <- read(socket, "") do
      respond(socket, handler.(request), request.method)
    end

    :ssl.close(socket)
  end

  defp read(socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [head, body] ->
        [line | lines] = String.split(head, "\r\n")
        [method, target, _] = String.split(line, " ")

        headers =
          Map.new(lines, fn line ->
            [name, value] = String.split(line, ":", parts: 2)
            {String.downcase(name), String.trim(value)}
          end)

        with {:ok, body} <- body(socket, body, String.to_integer(headers["content-length"] || "0")) do
          {:ok, %{method: method, target: target, headers: headers, body: body}}
        end

      [_] when byte_size(bytes) < 16_384 ->
        with {:ok, more} <- :ssl.recv(socket, 0, 2_000), do: read(socket, bytes <> more)

      _ ->
        {:error, :invalid_request}
    end
  end

  defp body(_, bytes, length) when byte_size(bytes) == length, do: {:ok, bytes}

  defp body(socket, bytes, length) when length <= 1_500_000 do
    with {:ok, more} <- :ssl.recv(socket, 0, 2_000), do: body(socket, bytes <> more, length)
  end

  defp respond(_, :close, _), do: :ok

  defp respond(socket, {:hold, parent, response}, method) do
    send(parent, {:held_response, self()})

    receive do
      :release_response -> respond(socket, response, method)
    after
      2_000 -> :ok
    end
  end

  defp respond(socket, {:delay, milliseconds, response}, method) do
    Process.sleep(milliseconds)
    respond(socket, response, method)
  end

  defp respond(socket, {status, headers, bytes}, method) do
    headers = Map.put_new(headers, "content-length", Integer.to_string(byte_size(bytes)))
    header_bytes = Enum.map(headers, fn {name, value} -> "#{name}: #{value}\r\n" end)
    :ssl.send(socket, ["HTTP/1.1 #{status} fixture\r\n", header_bytes, "\r\n", if(method == "HEAD", do: "", else: bytes)])
  end

  defp proxy_accept(listener, port, tasks) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, child} =
          Task.Supervisor.start_child(tasks, fn -> receive do: ({:socket, socket} -> tunnel(socket, port)) end)

        :ok = :gen_tcp.controlling_process(socket, child)
        send(child, {:socket, socket})
        proxy_accept(listener, port, tasks)

      _ ->
        :ok
    end
  end

  defp tunnel(client, port) do
    with {:ok, request} <- :gen_tcp.recv(client, 0, 2_000),
         true <- String.starts_with?(request, "CONNECT objects.example.test:443 "),
         {:ok, server} <- :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: true], 2_000) do
      :ok = :gen_tcp.send(client, "HTTP/1.0 200 OK\r\n\r\n")
      :ok = :inet.setopts(client, active: true)
      relay(client, server)
      :gen_tcp.close(server)
    end

    :gen_tcp.close(client)
  end

  defp relay(left, right) do
    receive do
      {:tcp, ^left, bytes} ->
        :gen_tcp.send(right, bytes)
        relay(left, right)

      {:tcp, ^right, bytes} ->
        :gen_tcp.send(left, bytes)
        relay(left, right)

      {:tcp_closed, _} ->
        :ok

      {:tcp_error, _, _} ->
        :ok
    after
      7_000 -> :ok
    end
  end
end
