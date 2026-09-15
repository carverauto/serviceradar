defmodule ServiceRadarWebNGWeb.DeviceLive.DeviceTabRuntimeTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.DeviceTabRuntime

  @moduletag :db_free

  def query(query, %{scope: %{test_pid: test_pid}}) do
    send(test_pid, {:interface_query, self(), query})

    receive do
      :finish -> {:ok, %{"results" => []}}
    after
      5_000 -> raise "synthetic interface query was not released"
    end
  end

  describe "interface metrics refresh lifecycle" do
    test "background refresh preserves an in-flight scan and its rendered charts" do
      socket = metrics_socket(%{panels: [:existing]})

      pending =
        DeviceTabRuntime.begin_interface_metrics_refresh(
          socket,
          "sr:synthetic-device",
          __MODULE__
        )

      assert_receive {:interface_query, task, _query}
      refute pending.assigns.interface_metrics_loading

      assert DeviceTabRuntime.begin_interface_metrics_refresh(
               pending,
               "sr:synthetic-device",
               __MODULE__
             ) == pending

      refute_receive {:interface_query, _task, _query}
      send(task, :finish)
    end

    test "a settings change cancels the old scan and starts one with the new selection" do
      pending =
        DeviceTabRuntime.begin_interface_metrics_refresh(
          metrics_socket(),
          "sr:synthetic-device",
          __MODULE__
        )

      assert_receive {:interface_query, old_task, old_query}
      assert old_query =~ "ifInOctets"
      monitor = Process.monitor(old_task)
      old_ref = pending.assigns.interface_metrics_request_ref

      [interface] = pending.assigns.network_interfaces

      changed =
        Phoenix.Component.assign(pending, :network_interfaces, [
          Map.put(interface, "metrics_selected", ["ifOutOctets"])
        ])

      restarted =
        DeviceTabRuntime.begin_interface_metrics_refresh(
          changed,
          "sr:synthetic-device",
          __MODULE__,
          force: true
        )

      assert_receive {:DOWN, ^monitor, :process, ^old_task, {:shutdown, :cancel}}
      assert_receive {:interface_query, new_task, new_query}
      assert new_query =~ "ifOutOctets"
      refute new_query =~ "ifInOctets"
      refute restarted.assigns.interface_metrics_request_ref == old_ref

      assert DeviceTabRuntime.finish_interface_metrics_refresh(
               restarted,
               "sr:synthetic-device",
               old_ref,
               %{
                 panels: [:stale]
               }
             ) == restarted

      send(new_task, :finish)
    end

    test "accepted completion clears the guard so the next refresh can run" do
      pending =
        DeviceTabRuntime.begin_interface_metrics_refresh(
          metrics_socket(),
          "sr:synthetic-device",
          __MODULE__
        )

      assert_receive {:interface_query, task, _query}
      request_ref = pending.assigns.interface_metrics_request_ref
      send(task, :finish)

      assert DeviceTabRuntime.finish_interface_metrics_refresh(
               pending,
               "sr:other-synthetic-device",
               request_ref,
               %{
                 panels: [:wrong_device]
               }
             ) == pending

      completed =
        DeviceTabRuntime.finish_interface_metrics_refresh(
          pending,
          "sr:synthetic-device",
          request_ref,
          %{
            panels: [:fresh]
          }
        )

      assert completed.assigns.interface_metrics == %{panels: [:fresh]}
      refute completed.assigns.interface_metrics_loading
      assert is_nil(completed.assigns.interface_metrics_request_ref)

      restarted =
        DeviceTabRuntime.begin_interface_metrics_refresh(
          completed,
          "sr:synthetic-device",
          __MODULE__
        )

      assert_receive {:interface_query, new_task, _query}
      refute restarted.assigns.interface_metrics_request_ref == request_ref
      send(new_task, :finish)
    end

    test "disconnected render does not start a scan" do
      socket = %{metrics_socket() | transport_pid: nil}

      assert DeviceTabRuntime.begin_interface_metrics_refresh(
               socket,
               "sr:synthetic-device",
               __MODULE__
             ) == socket

      refute_receive {:interface_query, _task, _query}
    end
  end

  defp metrics_socket(metrics \\ nil) do
    Phoenix.Component.assign(
      %Phoenix.LiveView.Socket{transport_pid: self(), assigns: %{__changed__: %{}}},
      current_scope: %{test_pid: self()},
      device_uid: "sr:synthetic-device",
      favorited_interfaces: MapSet.new(["ifindex:7"]),
      metrics_enabled_interfaces: MapSet.new(["ifindex:7"]),
      network_interfaces: [
        %{"interface_uid" => "ifindex:7", "if_index" => 7, "metrics_selected" => ["ifInOctets"]}
      ],
      interface_metrics: metrics,
      interface_metrics_loading: false,
      interface_metrics_request_ref: nil
    )
  end

  describe "tab_content_loading?/3" do
    test "shows the first-load spinner when details are still arriving and no rows exist" do
      assert DeviceTabRuntime.tab_content_loading?(false, true, [])
    end

    test "keeps already-loaded rows visible during a same-device details refresh" do
      refute DeviceTabRuntime.tab_content_loading?(false, true, [%{"if_name" => "eth0"}])
    end

    test "still honors the tab's own loading flag" do
      assert DeviceTabRuntime.tab_content_loading?(true, false, [%{"if_name" => "eth0"}])
    end
  end

  describe "reload_interfaces?/1" do
    test "reloads only when the tab is idle and empty" do
      assert DeviceTabRuntime.reload_interfaces?(%{
               interfaces_loading: false,
               network_interfaces: []
             })
    end

    test "does not wipe a table that already has rows" do
      refute DeviceTabRuntime.reload_interfaces?(%{
               interfaces_loading: false,
               network_interfaces: [%{"if_name" => "eth0"}]
             })
    end

    test "does not start a second load while one is in flight" do
      refute DeviceTabRuntime.reload_interfaces?(%{
               interfaces_loading: true,
               network_interfaces: []
             })
    end
  end
end
