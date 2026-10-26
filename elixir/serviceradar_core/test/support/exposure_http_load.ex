defmodule ServiceRadar.TestSupport.ExposureHTTPLoad do
  @moduledoc false
  # Exercise the real HTTP loader and acknowledgement boundary, without
  # replacing the processor or implementing a fake warehouse's merge rules.
  def serve(listener, parent) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
        ["PUT", path, _] = String.split(request)
        headers = headers(socket, %{})
        :ok = :gen_tcp.send(socket, "HTTP/1.1 100 Continue\r\n\r\n")
        :ok = :inet.setopts(socket, packet: :raw)
        {:ok, body} = :gen_tcp.recv(socket, String.to_integer(headers["content-length"]), 5_000)
        rows = Jason.decode!(body)
        send(parent, {:load, self(), path, headers, rows})

        response =
          receive do
            :commit ->
              %{
                "Status" => "Success",
                "NumberLoadedRows" => length(rows),
                "NumberFilteredRows" => 0
              }

            :filtered ->
              %{"Status" => "Success", "NumberLoadedRows" => 0, "NumberFilteredRows" => 1}

            :failure ->
              %{"Status" => "Fail", "Message" => "synthetic load failure"}
          after
            5_000 -> raise "load was never answered"
          end

        body = Jason.encode!(response)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\nContent-Length: ",
            Integer.to_string(byte_size(body)),
            "\r\nConnection: close\r\n\r\n",
            body
          ])

        :gen_tcp.close(socket)
        serve(listener, parent)

      {:error, :closed} ->
        :ok
    end
  end

  defp headers(socket, acc) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)

    case String.split(String.trim(line), ":", parts: 2) do
      [""] -> acc
      [key, value] -> headers(socket, Map.put(acc, String.downcase(key), String.trim(value)))
    end
  end
end
