defmodule ServiceRadarWebNGWeb.DeviceLive.DeviceMetricsRuntime do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [cancel_async: 2, start_async: 3]

  def begin_refresh(socket, %{uid: uid} = request, load, opts \\ []) do
    if is_reference(socket.assigns[:device_metrics_request_ref]) and
         socket.assigns[:device_metrics_request] == request do
      socket
    else
      request_ref = make_ref()

      socket
      |> cancel_refresh()
      |> assign(:device_metrics_request, request)
      |> assign(:device_metrics_request_ref, request_ref)
      |> assign(:metrics_loading, true)
      |> maybe_clear_sections(Keyword.get(opts, :clear_sections, false))
      |> start_async({:device_metrics, uid, request_ref}, load)
    end
  end

  def current_request?(socket, uid, request_ref) do
    is_reference(request_ref) and uid == socket.assigns.device_uid and
      request_ref == socket.assigns[:device_metrics_request_ref]
  end

  def complete_refresh(socket) do
    socket
    |> assign(:device_metrics_request, nil)
    |> assign(:device_metrics_request_ref, nil)
    |> assign(:metrics_loading, false)
    |> assign(:metrics_error, nil)
  end

  def fail_refresh(socket) do
    socket
    |> complete_refresh()
    |> assign(:metrics_error, "Unable to load metrics for this window. Select a window to retry.")
  end

  defp maybe_clear_sections(socket, true), do: assign(socket, :metric_sections, [])
  defp maybe_clear_sections(socket, false), do: socket

  def cancel_refresh(socket) do
    # The pending UID belongs to the task, even after navigation changes the
    # device UID rendered by the socket.
    socket =
      case {socket.assigns[:device_metrics_request], socket.assigns[:device_metrics_request_ref]} do
        {%{uid: uid}, request_ref} when is_reference(request_ref) ->
          cancel_async(socket, {:device_metrics, uid, request_ref})

        _ ->
          socket
      end

    complete_refresh(socket)
  end
end
