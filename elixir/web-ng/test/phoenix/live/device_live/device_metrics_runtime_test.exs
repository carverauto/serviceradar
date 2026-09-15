defmodule ServiceRadarWebNGWeb.DeviceLive.DeviceMetricsRuntimeTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.DeviceMetricsRuntime

  @moduletag :db_free

  test "background refresh keeps the pending scan and Profiles discovery on any tab" do
    socket = socket()
    pending = DeviceMetricsRuntime.begin_refresh(socket, request(), loader())
    assert_receive {:metrics_started, task}
    request_ref = pending.assigns.device_metrics_request_ref

    assert pending.assigns.active_tab == "interfaces"
    assert pending.assigns.sysmon_presence
    assert pending.assigns.metric_sections == [:existing_section]

    assert DeviceMetricsRuntime.begin_refresh(pending, request(), loader()) == pending
    refute_receive {:metrics_started, _task}
    assert Process.alive?(task)

    send(task, {:finish, %{sysmon_presence: true, metric_sections: [:fresh_section]}})

    assert_receive {:phoenix, :async_result,
                    {:start, {_monitor, nil, {:device_metrics, "sr:synthetic-device", ^request_ref}, {:ok, result}}}}

    assert result.sysmon_presence
    assert result.metric_sections == [:fresh_section]
    assert DeviceMetricsRuntime.current_request?(pending, "sr:synthetic-device", request_ref)

    completed = DeviceMetricsRuntime.complete_refresh(pending)
    refute completed.assigns.metrics_loading
    assert is_nil(completed.assigns.device_metrics_request_ref)
    assert is_nil(completed.assigns.device_metrics_request)

    refreshed = DeviceMetricsRuntime.begin_refresh(completed, request(), loader())
    assert_receive {:metrics_started, next_task}
    refute refreshed.assigns.device_metrics_request_ref == request_ref
    send(next_task, {:finish, %{}})
  end

  test "explicit range change cancels the previous scan even after the selector assign changes" do
    pending = DeviceMetricsRuntime.begin_refresh(socket(), request(), loader())
    assert_receive {:metrics_started, old_task}
    monitor = Process.monitor(old_task)
    old_ref = pending.assigns.device_metrics_request_ref

    changed = Phoenix.Component.assign(pending, :sysmon_time_range, "last_1h")
    new_request = %{request() | time_range: "last_1h"}
    restarted = DeviceMetricsRuntime.begin_refresh(changed, new_request, loader())

    assert_receive {:DOWN, ^monitor, :process, ^old_task, {:shutdown, :cancel}}
    assert_receive {:metrics_started, task}
    refute restarted.assigns.device_metrics_request_ref == old_ref
    refute DeviceMetricsRuntime.current_request?(restarted, "sr:synthetic-device", old_ref)
    assert restarted.assigns.sysmon_time_range == "last_1h"
    send(task, {:finish, %{}})
  end

  test "a changed resolved identity replaces the pending request at the same range" do
    pending = DeviceMetricsRuntime.begin_refresh(socket(), request(), loader())
    assert_receive {:metrics_started, old_task}
    monitor = Process.monitor(old_task)

    new_request = %{request() | identity: %{device_uid: "sr:synthetic-device", agent_id: "agent-synthetic"}}
    restarted = DeviceMetricsRuntime.begin_refresh(pending, new_request, loader())

    assert_receive {:DOWN, ^monitor, :process, ^old_task, {:shutdown, :cancel}}
    assert_receive {:metrics_started, task}
    assert restarted.assigns.device_metrics_request == new_request
    send(task, {:finish, %{}})
  end

  test "device navigation cancels the task by its original UID and rejects stale results" do
    pending = DeviceMetricsRuntime.begin_refresh(socket(), request(), loader())
    assert_receive {:metrics_started, old_task}
    monitor = Process.monitor(old_task)
    old_ref = pending.assigns.device_metrics_request_ref

    changed = Phoenix.Component.assign(pending, :device_uid, "sr:other-synthetic-device")
    new_request = %{request() | uid: "sr:other-synthetic-device", identity: %{device_uid: "sr:other-synthetic-device"}}
    restarted = DeviceMetricsRuntime.begin_refresh(changed, new_request, loader())
    new_ref = restarted.assigns.device_metrics_request_ref

    assert_receive {:DOWN, ^monitor, :process, ^old_task, {:shutdown, :cancel}}
    assert_receive {:metrics_started, task}
    refute DeviceMetricsRuntime.current_request?(restarted, "sr:synthetic-device", old_ref)
    refute DeviceMetricsRuntime.current_request?(restarted, "sr:synthetic-device", new_ref)
    refute DeviceMetricsRuntime.current_request?(restarted, "sr:other-synthetic-device", old_ref)
    assert DeviceMetricsRuntime.current_request?(restarted, "sr:other-synthetic-device", new_ref)
    send(task, {:finish, %{}})
  end

  test "navigation cleanup clears pending state before another device starts loading" do
    pending = DeviceMetricsRuntime.begin_refresh(socket(), request(), loader())
    assert_receive {:metrics_started, task}
    monitor = Process.monitor(task)
    request_ref = pending.assigns.device_metrics_request_ref
    cancelled = DeviceMetricsRuntime.cancel_refresh(pending)

    assert_receive {:DOWN, ^monitor, :process, ^task, {:shutdown, :cancel}}
    refute cancelled.assigns.metrics_loading
    assert is_nil(cancelled.assigns.device_metrics_request)
    assert is_nil(cancelled.assigns.device_metrics_request_ref)
    refute DeviceMetricsRuntime.current_request?(cancelled, "sr:synthetic-device", request_ref)
    refute DeviceMetricsRuntime.current_request?(cancelled, "sr:synthetic-device", nil)
  end

  defp socket do
    Phoenix.Component.assign(%Phoenix.LiveView.Socket{transport_pid: self(), assigns: %{__changed__: %{}}},
      device_uid: "sr:synthetic-device",
      active_tab: "interfaces",
      sysmon_time_range: "last_24h",
      device_metrics_request_ref: nil,
      metrics_loading: false,
      metric_sections: [:existing_section],
      sysmon_presence: true
    )
  end

  defp request do
    %{
      uid: "sr:synthetic-device",
      identity: %{device_uid: "sr:synthetic-device"},
      time_range: "last_24h",
      anomaly_filters: %{},
      can_view_anomaly_capacity: false,
      scope: nil,
      srql_module: __MODULE__
    }
  end

  defp loader do
    test_pid = self()

    fn ->
      send(test_pid, {:metrics_started, self()})

      receive do
        {:finish, result} -> result
      after
        5_000 -> raise "synthetic metrics request was not released"
      end
    end
  end
end
