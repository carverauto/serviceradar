defmodule ServiceRadarWebNGWeb.LogLive.NetflowRuntime do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [cancel_async: 2, start_async: 3]

  def panels(context) do
    view = Map.get(context, :netflow_view, "overview")
    graph = Map.get(context, :netflow_graph_mode, "stacked")
    traffic? = view in ["overview", "traffic"]

    %{
      summary: view == "overview",
      timeseries: traffic?,
      compare: traffic? and graph in ["lines", "grid"],
      stacked: traffic? and graph in ["stacked", "stacked100"],
      activity: view == "traffic",
      talkers: view == "talkers",
      geo: view == "topology",
      sankey: view in ["topology", "talkers"],
      rows: view in ["explorer", "all"]
    }
  end

  def begin_refresh(socket, request, load) do
    if is_reference(socket.assigns[:netflow_request_ref]) and socket.assigns[:netflow_request] == request do
      socket
    else
      ref = make_ref()

      socket
      |> prepare_refresh()
      |> assign(:netflow_request, request)
      |> assign(:netflow_request_ref, ref)
      |> start_async({:netflow_analytics, ref}, load)
    end
  end

  def prepare_refresh(socket) do
    socket
    |> cancel_refresh()
    |> assign(:netflow_loading, true)
    |> assign(:netflow_load_error, nil)
    |> clear_charts()
  end

  def current?(socket, ref) do
    socket.assigns[:active_tab] == "netflows" and is_reference(ref) and socket.assigns[:netflow_request_ref] == ref
  end

  def complete(socket) do
    socket
    |> assign(:netflow_request_ref, nil)
    |> assign(:netflow_request, nil)
    |> assign(:netflow_loading, false)
  end

  def cancel_refresh(socket) do
    socket =
      case socket.assigns[:netflow_request_ref] do
        ref when is_reference(ref) -> cancel_async(socket, {:netflow_analytics, ref})
        _ -> socket
      end

    complete(socket)
  end

  defp clear_charts(socket) do
    Enum.reduce(
      [
        :netflow_timeseries,
        :netflow_timeseries_compare,
        :netflow_timeseries_stacked,
        :netflow_protocol_activity,
        :netflow_app_activity
      ],
      socket,
      fn key, acc ->
        assign(acc, key, %{bucket_seconds: 300, points: [], keys: [], colors: %{}})
      end
    )
  end
end
