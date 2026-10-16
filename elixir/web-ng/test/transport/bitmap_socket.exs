defmodule ServiceRadarWebNG.BitmapTransport.Socket do
  @moduledoc false
  use Phoenix.Socket

  channel "topology:tiles", ServiceRadarWebNG.BitmapTransport.Channel

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
