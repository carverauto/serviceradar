defmodule ServiceRadarWebNG.BitmapTransport.Channel do
  @moduledoc false
  use Phoenix.Channel

  @impl true
  def join("topology:tiles", _params, socket), do: {:ok, socket}

  @impl true
  def handle_in("next", %{"sequence" => sequence}, socket) do
    frame = Map.fetch!(:persistent_term.get({__MODULE__, :frames}), sequence)
    push(socket, "membership:frame", {:binary, frame})
    {:noreply, socket}
  end
end
