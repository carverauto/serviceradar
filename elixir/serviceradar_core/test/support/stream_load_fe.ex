defmodule ServiceRadar.TestSupport.StreamLoadFE do
  @moduledoc """
  A StarRocks Frontend that accepts every Stream Load and reports each row
  loaded, so a test exercises the real HTTP loader rather than a stubbed one.

  `start!/0` serves from a task supervised by the calling test and returns the
  `fe_http` URL to configure. Each load's rows are sent to the calling test as
  `{:wire_request, rows}` before the load is answered, so the message is in
  the mailbox by the time the load returns.
  """

  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  @spec start!() :: String.t()
  def start! do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, reuseaddr: true])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()
    start_supervised!({Task, fn -> serve(listener, parent) end})
    "http://127.0.0.1:#{port}"
  end

  defp serve(listener, parent) do
    case :gen_tcp.accept(listener, 5_000) do
      {:ok, socket} ->
        {:ok, {:http_request, :PUT, _, _}} = :gen_tcp.recv(socket, 0, 5_000)
        headers = receive_headers(socket, %{})
        :ok = :gen_tcp.send(socket, "HTTP/1.1 100 Continue\r\n\r\n")
        :ok = :inet.setopts(socket, packet: :raw)
        {:ok, body} = :gen_tcp.recv(socket, String.to_integer(headers["content-length"]), 5_000)
        rows = Jason.decode!(body)
        send(parent, {:wire_request, rows})

        response =
          Jason.encode!(%{
            "Status" => "Success",
            "NumberLoadedRows" => length(rows),
            "NumberFilteredRows" => 0
          })

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ",
            Integer.to_string(byte_size(response)),
            "\r\n\r\n",
            response
          ])

        :gen_tcp.close(socket)
        serve(listener, parent)

      {:error, :closed} ->
        :ok

      {:error, :timeout} ->
        serve(listener, parent)
    end
  end

  defp receive_headers(socket, headers) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, :http_eoh} ->
        headers

      {:ok, {:http_header, _, key, _, value}} ->
        receive_headers(socket, Map.put(headers, key |> to_string() |> String.downcase(), value))
    end
  end
end
