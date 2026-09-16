defmodule ServiceRadarWebNGWeb.LogLive.NetflowRuntimeTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.LogLive.NetflowRuntime

  @moduletag :db_free

  test "a range change clears old charts immediately and cancels the old generation" do
    first = NetflowRuntime.begin_refresh(socket(), %{query: "in:flows time:last_7d"}, loader())
    assert_receive {:started, old_task}
    ref = first.assigns.netflow_request_ref
    assert first.assigns.netflow_loading
    assert first.assigns.netflow_timeseries.points == []
    monitor = Process.monitor(old_task)

    second = NetflowRuntime.begin_refresh(first, %{query: "in:flows time:last_30d"}, loader())
    assert_receive {:DOWN, ^monitor, :process, ^old_task, {:shutdown, :cancel}}
    assert_receive {:started, new_task}
    refute NetflowRuntime.current?(second, ref)
    assert NetflowRuntime.current?(second, second.assigns.netflow_request_ref)
    send(new_task, :finish)
  end

  test "the same in-flight request is not duplicated" do
    request = %{query: "in:flows time:last_7d"}
    pending = NetflowRuntime.begin_refresh(socket(), request, loader())
    assert_receive {:started, task}
    assert NetflowRuntime.begin_refresh(pending, request, loader()) == pending
    refute_receive {:started, _}
    send(task, :finish)
  end

  test "switching the view or graph cancels the prior panel request" do
    request = %{query: "in:flows time:last_7d", netflow_view: "overview", netflow_graph_mode: "stacked"}
    pending = NetflowRuntime.begin_refresh(socket(), request, loader())
    assert_receive {:started, task}
    monitor = Process.monitor(task)
    ref = pending.assigns.netflow_request_ref

    next_request = %{request | netflow_view: "topology", netflow_graph_mode: "sankey"}
    next = NetflowRuntime.begin_refresh(pending, next_request, loader())
    assert_receive {:DOWN, ^monitor, :process, ^task, {:shutdown, :cancel}}
    assert_receive {:started, next_task}
    refute NetflowRuntime.current?(next, ref)
    assert next.assigns.netflow_request == next_request
    send(next_task, :finish)
  end

  test "accepting newer navigation invalidates old results before the deferred load begins" do
    pending = NetflowRuntime.begin_refresh(socket(), %{query: "in:flows time:last_7d"}, loader())
    assert_receive {:started, task}
    monitor = Process.monitor(task)
    ref = pending.assigns.netflow_request_ref
    prepared = NetflowRuntime.prepare_refresh(pending)
    assert_receive {:DOWN, ^monitor, :process, ^task, {:shutdown, :cancel}}
    assert prepared.assigns.netflow_loading
    assert prepared.assigns.netflow_timeseries.points == []
    refute NetflowRuntime.current?(prepared, ref)
  end

  test "completion clears the guard and changing tabs rejects completion" do
    pending = NetflowRuntime.begin_refresh(socket(), %{query: "in:flows time:last_7d"}, loader())
    assert_receive {:started, task}
    ref = pending.assigns.netflow_request_ref
    other_tab = Phoenix.Component.assign(pending, :active_tab, "logs")
    refute NetflowRuntime.current?(other_tab, ref)
    completed = NetflowRuntime.complete(pending)
    refute completed.assigns.netflow_loading
    assert is_nil(completed.assigns.netflow_request_ref)
    send(task, :finish)
  end

  defp loader do
    owner = self()

    fn ->
      send(owner, {:started, self()})

      receive do
        :finish -> %{netflow_summary: %{total: 1200}}
      after
        1000 -> raise "synthetic query not released"
      end
    end
  end

  defp socket do
    Phoenix.Component.assign(%Phoenix.LiveView.Socket{transport_pid: self(), assigns: %{__changed__: %{}}},
      active_tab: "netflows",
      netflow_timeseries: %{bucket_seconds: 900, points: [%{bytes: 100}]}
    )
  end
end
