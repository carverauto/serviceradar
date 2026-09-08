defmodule Boombox.Application do
  @moduledoc """
  Boombox application. If released with release name set to `"server"`, Boombox.Server will be
  started under the supervision tree. If `BOOMBOX_NODE_TO_PING` environment variable is set,
  then a node with the provided name will be pinged.
  """
  use Application

  @impl true
  def start(_type, _args) do
    case System.fetch_env("RELEASE_NAME") do
      {:ok, "server"} ->
        start_server()

      _not_server ->
        Supervisor.start_link([], strategy: :one_for_one)
    end
  end

  defp start_server() do
    case System.fetch_env("BOOMBOX_NODE_TO_PING") do
      :error ->
        :ok

      {:ok, node_to_ping} ->
        case Node.ping(String.to_atom(node_to_ping)) do
          :pong -> :ok
          :pang -> raise "Connection with node #{node_to_ping} failed."
        end
    end

    Supervisor.start_link(
      [
        {Boombox.Server,
         [packet_serialization: true, stop_application: true, name: :boombox_server]}
      ],
      strategy: :one_for_one
    )
  end

  @impl true
  def stop(_state) do
    System.stop(0)
  end
end
