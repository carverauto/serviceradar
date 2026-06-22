defmodule ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.Loader do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.Config
  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrData

  def refresh_diagnostics(socket) do
    socket
    |> load_traces()
    |> load_trace_coverage()
    |> load_retention_status()
    |> load_pending_jobs()
    |> load_bulk_jobs()
  end

  def schedule_refresh(socket) do
    case socket.assigns[:refresh_timer] do
      nil ->
        ref = Process.send_after(self(), :refresh_diagnostics, 250)
        assign(socket, :refresh_timer, ref)

      _ref ->
        socket
    end
  end

  defp load_traces(socket) do
    srql_query = Map.get(socket.assigns.srql || %{}, :query, "")

    case MtrData.list_traces_paginated(
           target_filter: socket.assigns.filter_target,
           agent_filter: socket.assigns.filter_agent,
           srql_query: srql_query,
           limit: socket.assigns.limit,
           page: socket.assigns.current_page
         ) do
      {:ok, %{rows: traces, total_count: total_count, page: page, per_page: limit}} ->
        socket
        |> assign(:traces, traces)
        |> assign(:total_count, total_count)
        |> assign(:current_page, page)
        |> assign(:limit, limit)

      {:error, _} ->
        socket
        |> assign(:traces, [])
        |> assign(:total_count, 0)
    end
  end

  defp load_trace_coverage(socket) do
    srql_query = Map.get(socket.assigns.srql || %{}, :query, "")

    case MtrData.trace_coverage(
           target_filter: socket.assigns.filter_target,
           agent_filter: socket.assigns.filter_agent,
           srql_query: srql_query
         ) do
      {:ok, coverage} -> assign(socket, :trace_coverage, coverage)
      {:error, _} -> assign(socket, :trace_coverage, Config.empty_trace_coverage())
    end
  end

  defp load_retention_status(socket) do
    assign(socket, :mtr_retention_status, MtrData.retention_status(socket.assigns.current_scope))
  end

  defp load_pending_jobs(socket) do
    case MtrData.list_pending_jobs(
           socket.assigns.current_scope,
           target_filter: socket.assigns.filter_target,
           agent_filter: socket.assigns.filter_agent
         ) do
      {:ok, jobs} ->
        assign(socket, :pending_jobs, MtrData.suppress_completed_pending_jobs(jobs, socket.assigns.traces))

      {:error, _} ->
        assign(socket, :pending_jobs, [])
    end
  end

  defp load_bulk_jobs(socket) do
    case MtrData.list_bulk_jobs(
           socket.assigns.current_scope,
           target_filter: socket.assigns.filter_target,
           agent_filter: socket.assigns.filter_agent
         ) do
      {:ok, jobs} -> assign(socket, :bulk_jobs, jobs)
      {:error, _} -> assign(socket, :bulk_jobs, [])
    end
  end
end
