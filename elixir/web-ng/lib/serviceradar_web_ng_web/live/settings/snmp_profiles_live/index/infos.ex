defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Infos do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  def handle_info({ref, result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     socket
     |> assign(:test_connection_loading, false)
     |> assign(:test_connection_result, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) when is_reference(ref) do
    result = %{
      success: false,
      message: "Connection test failed: #{inspect(reason)}"
    }

    {:noreply,
     socket
     |> assign(:test_connection_loading, false)
     |> assign(:test_connection_result, result)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}
end
