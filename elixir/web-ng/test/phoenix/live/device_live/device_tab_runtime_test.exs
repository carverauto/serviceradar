defmodule ServiceRadarWebNGWeb.DeviceLive.DeviceTabRuntimeTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.DeviceTabRuntime

  @moduletag :db_free

  def query(query, %{scope: %{test_pid: test_pid, loader: :availability}}) do
    if String.contains?(query, "metric_name:sweep.host.icmp_available") do
      {:ok, %{"results" => []}}
    else
      send(test_pid, {:availability_query, self(), query})

      receive do
        :finish ->
          {:ok,
           %{
             "results" => [
               %{
                 "series" => "sr:synthetic-device",
                 "value" => 1,
                 "timestamp" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -60, :second))
               }
             ]
           }}
      after
        5_000 -> raise "synthetic availability query was not released"
      end
    end
  end

  def query(query, %{scope: %{test_pid: test_pid}}) do
    send(test_pid, {:interface_query, self(), query})

    receive do
      :finish -> {:ok, %{"results" => []}}
    after
      5_000 -> raise "synthetic interface query was not released"
    end
  end

  describe "lazy availability refresh" do
    test "other tabs and disconnected renders do not query availability" do
      socket = availability_socket()

      for tab <- ["interfaces", "sysmon", "logs"] do
        assert DeviceTabRuntime.maybe_reload_availability_for_active_tab(socket, tab, "sr:synthetic-device", __MODULE__) ==
                 socket
      end

      disconnected = %{socket | transport_pid: nil}

      assert DeviceTabRuntime.maybe_reload_availability_for_active_tab(
               disconnected,
               "details",
               "sr:synthetic-device",
               __MODULE__
             ) == disconnected

      refute_receive {:availability_query, _task, _query}
    end

    test "opening Details starts one pending query and publishes its completed availability" do
      socket = availability_socket()
      pending = DeviceTabRuntime.reload_for_active_tab(socket, "details", "sr:synthetic-device", nil, __MODULE__, [])
      assert_receive {:availability_query, task, query}
      assert query =~ "metric_name:icmp_available"
      assert query =~ "bucket:30m agg:max"
      refute query =~ "icmp_response_time_ns"
      request_ref = pending.assigns.availability_request_ref
      assert is_reference(request_ref)
      assert pending.assigns.availability == socket.assigns.availability

      assert DeviceTabRuntime.maybe_reload_availability_for_active_tab(
               pending,
               "details",
               "sr:synthetic-device",
               __MODULE__
             ) == pending

      refute_receive {:availability_query, _task, _query}
      send(task, :finish)

      assert_receive {:phoenix, :async_result,
                      {:start,
                       {_monitor, nil, {:device_availability, "sr:synthetic-device", ^request_ref}, {:ok, availability}}}}

      assert availability.uptime_pct == 100.0
      assert availability.total_checks == 1

      completed =
        DeviceTabRuntime.finish_availability_refresh(pending, "sr:synthetic-device", request_ref, {:ok, availability})

      assert completed.assigns.availability == availability
      assert is_nil(completed.assigns.availability_request_ref)

      restarted =
        DeviceTabRuntime.maybe_reload_availability_for_active_tab(completed, "details", "sr:synthetic-device", __MODULE__)

      assert_receive {:availability_query, next_task, _query}
      refute restarted.assigns.availability_request_ref == request_ref
      send(next_task, :finish)
    end

    test "stale completion cannot replace the new device and failures allow a later retry" do
      request_ref = make_ref()
      pending = Phoenix.Component.assign(availability_socket(), :availability_request_ref, request_ref)

      assert DeviceTabRuntime.finish_availability_refresh(
               pending,
               "sr:other-synthetic-device",
               request_ref,
               {:ok, %{uptime_pct: 0}}
             ) == pending

      assert DeviceTabRuntime.finish_availability_refresh(
               pending,
               "sr:synthetic-device",
               make_ref(),
               {:ok, %{uptime_pct: 0}}
             ) == pending

      assert DeviceTabRuntime.finish_availability_refresh(
               pending,
               "sr:synthetic-device",
               make_ref(),
               {:exit, :synthetic_failure}
             ) == pending

      failed =
        DeviceTabRuntime.finish_availability_refresh(
          pending,
          "sr:synthetic-device",
          request_ref,
          {:exit, :synthetic_failure}
        )

      assert failed.assigns.availability == pending.assigns.availability
      assert is_nil(failed.assigns.availability_request_ref)
    end

    test "changing canonical agent cancels the old request and rejects its result" do
      original =
        Phoenix.Component.assign(availability_socket(), :device_row, %{"availability_source_agent_id" => "agent-original"})

      pending =
        DeviceTabRuntime.maybe_reload_availability_for_active_tab(original, "details", "sr:synthetic-device", __MODULE__)

      assert_receive {:availability_query, old_task, old_query}
      assert old_query =~ ~s(agent_id:"agent-original")
      assert old_query =~ "agg:min"
      old_ref = pending.assigns.availability_request_ref
      monitor = Process.monitor(old_task)

      changed = Phoenix.Component.assign(pending, :device_row, %{"availability_source_agent_id" => "agent-selected"})

      assert DeviceTabRuntime.finish_availability_refresh(
               changed,
               "sr:synthetic-device",
               old_ref,
               {:ok, %{uptime_pct: 0}}
             ) == changed

      restarted =
        DeviceTabRuntime.maybe_reload_availability_for_active_tab(changed, "details", "sr:synthetic-device", __MODULE__)

      assert_receive {:DOWN, ^monitor, :process, ^old_task, {:shutdown, :cancel}}
      assert_receive {:availability_query, new_task, query}
      assert query =~ ~s(agent_id:"agent-selected")
      refute query =~ "agent-original"
      assert is_nil(restarted.assigns.availability)
      refute restarted.assigns.availability_request_ref == old_ref

      assert DeviceTabRuntime.finish_availability_refresh(
               restarted,
               "sr:synthetic-device",
               old_ref,
               {:ok, %{uptime_pct: 0}}
             ) == restarted

      send(new_task, :finish)
    end

    test "explicit source invalidation cancels pending work before navigation reloads the device" do
      pending =
        DeviceTabRuntime.maybe_reload_availability_for_active_tab(
          availability_socket(),
          "details",
          "sr:synthetic-device",
          __MODULE__
        )

      assert_receive {:availability_query, task, _query}
      monitor = Process.monitor(task)
      ref = pending.assigns.availability_request_ref
      invalidated = DeviceTabRuntime.availability_source_updated(pending, "agent-selected")
      assert_receive {:DOWN, ^monitor, :process, ^task, {:shutdown, :cancel}}
      assert is_nil(invalidated.assigns.availability)
      assert is_nil(invalidated.assigns.availability_request_ref)
      assert invalidated.assigns.device_row["availability_source_agent_id"] == "agent-selected"

      assert DeviceTabRuntime.finish_availability_refresh(
               invalidated,
               "sr:synthetic-device",
               ref,
               {:ok, %{uptime_pct: 0}}
             ) == invalidated
    end

    test "source changes update the displayed results row together with the query source" do
      row = %{
        "uid" => "sr:synthetic-device",
        "hostname" => "host01.example.com",
        availability_source_agent_id: "agent-original",
        availability_source_profile_id: "synthetic-profile"
      }

      other = %{"uid" => "sr:other-device", "availability_source_agent_id" => "agent-unrelated"}
      socket = Phoenix.Component.assign(availability_socket(), device_row: row, results: [row, other])

      for agent_id <- ["agent-selected", nil] do
        updated = DeviceTabRuntime.availability_source_updated(socket, agent_id)
        [displayed, untouched] = updated.assigns.results
        assert displayed == updated.assigns.device_row
        assert displayed["availability_source_agent_id"] == agent_id
        assert is_nil(displayed["availability_source_profile_id"])
        refute Map.has_key?(displayed, :availability_source_agent_id)
        refute Map.has_key?(displayed, :availability_source_profile_id)
        assert displayed["hostname"] == "host01.example.com"
        assert untouched == other
      end
    end

    test "clearing the selected source removes stale atom keys and reloads fallback policy" do
      socket =
        Phoenix.Component.assign(availability_socket(), :device_row, %{
          "hostname" => "host01.example.com",
          availability_source_agent_id: "agent-selected",
          availability_source_profile_id: "synthetic-profile"
        })

      cleared = DeviceTabRuntime.availability_source_updated(socket, nil)
      assert is_nil(cleared.assigns.device_row["availability_source_agent_id"])
      assert is_nil(cleared.assigns.device_row["availability_source_profile_id"])
      refute Map.has_key?(cleared.assigns.device_row, :availability_source_agent_id)
      assert cleared.assigns.device_row["hostname"] == "host01.example.com"

      pending =
        DeviceTabRuntime.maybe_reload_availability_for_active_tab(cleared, "details", "sr:synthetic-device", __MODULE__)

      assert_receive {:availability_query, task, query}
      assert query =~ "agg:max"
      refute query =~ "agent_id:"
      assert pending.assigns.availability_request_source == {"sr:synthetic-device", nil}
      send(task, :finish)
    end
  end

  defp availability_socket do
    Phoenix.Component.assign(metrics_socket(),
      current_scope: %{test_pid: self(), loader: :availability},
      availability: %{uptime_pct: 75.0},
      availability_request_ref: nil,
      availability_request_source: {"sr:synthetic-device", nil}
    )
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
