defmodule ServiceRadarWebNGWeb.EventLive.ShowTest do
  @moduledoc """
  Tests for the Event Details LiveView (EventLive.Show), focused on the
  "Affected Device" link for device-scoped signals (e.g. Proxmox guest
  bottlenecks).
  """

  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  @device_uid "sr:5bf1b6f6-0e7c-43ac-b883-a13447199d85"
  @event_id "00000000-0000-0000-0000-0000000009a1"

  setup %{conn: conn} do
    old = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.EventShowSRQLStub)

    on_exit(fn ->
      if is_nil(old) do
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      else
        Application.put_env(:serviceradar_web_ng, :srql_module, old)
      end
    end)

    user =
      then(operator_user_fixture(), fn user ->
        Ash.update!(user, %{timezone: "America/Chicago"},
          action: :update_timezone_preference,
          actor: user
        )
      end)

    conn = log_in_user(conn, user)

    %{conn: conn}
  end

  test "renders an Affected Device link resolving a Proxmox guest bottleneck", %{conn: conn} do
    device = device_fixture(%{uid: @device_uid, hostname: "pve-node-01"})

    {:ok, lv, html} = live(conn, ~p"/events/#{@event_id}")

    # Links to the resolved device details page.
    assert has_element?(lv, "a[href='#{~p"/devices/#{@device_uid}"}']", "View device")
    # Surfaces the resolved device hostname and the guest identifier for context.
    assert html =~ "Affected device"
    assert html =~ device.hostname
    assert html =~ "qemu:116"
    assert html =~ @device_uid
  end

  @tag :web_ng_shared_fixture_db
  test "renders the event instant semantically in the authenticated timezone", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/events/#{@event_id}")

    assert has_element?(
             lv,
             ~s(time#event-detail-time[datetime="2026-07-04T12:00:00Z"][data-user-time-zone="America/Chicago"])
           )

    assert has_element?(
             lv,
             ~s(#event-stream time[datetime="2026-07-04T12:00:00Z"][data-user-time-zone="America/Chicago"])
           )

    assert has_element?(
             lv,
             ~s(time#event-additional-updated-at-time[datetime="2026-07-04T12:30:00Z"][data-user-time-zone="America/Chicago"])
           )

    for {key, instant} <- [
          event_time: "2026-07-04T12:01:00Z",
          observed_at: "2026-07-04T12:02:00Z",
          created_at: "2026-07-04T12:03:00Z",
          expires_at: "2026-07-04T12:04:00Z",
          timestamp: "2026-07-04T12:07:00Z"
        ] do
      id = key |> to_string() |> String.replace("_", "-")

      assert has_element?(
               lv,
               ~s(time#event-context-#{id}-time[datetime="#{instant}"][data-user-time-zone="America/Chicago"])
             )
    end

    assert has_element?(
             lv,
             ~s(time#event-signal-display-widget-3-field-1-time[datetime="2026-07-04T12:05:00Z"][data-user-time-zone="America/Chicago"])
           )

    refute has_element?(lv, "#event-context-note-time")
    refute has_element?(lv, "time#event-context-logged-time-time")
    assert render(lv) =~ "2026-07-04T12:06:30"
    refute render(lv) =~ "2026-07-04T12:06:30Z"
  end

  @tag :web_ng_shared_fixture_db
  test "renders projected exhaustion semantically in the authenticated timezone", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/events/capacity-forecast-1")

    assert has_element?(
             lv,
             ~s(time#event-projected-exhaustion-time[datetime="2026-08-30T18:45:00Z"][data-user-time-zone="America/Chicago"])
           )
  end

  test "still links by uid when the device cannot be resolved", %{conn: conn} do
    # No device fixture created: the uid is unknown/deleted, but the link and
    # guest label must still render (no crash, no broken page).
    {:ok, lv, html} = live(conn, ~p"/events/#{@event_id}")

    assert has_element?(lv, "a[href='#{~p"/devices/#{@device_uid}"}']", "View device")
    assert html =~ "qemu:116"
  end

  test "omits the Affected Device panel for a non-device signal", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/events/#{"no-device"}")

    refute html =~ "Affected device"
    refute has_element?(lv, "a[href='#{~p"/devices/#{@device_uid}"}']")
  end

  @tag :web_ng_shared_fixture_db
  test "SNMP anomaly finding shows device/interface/SNMP links and metric context", %{conn: conn} do
    _device = device_fixture(%{uid: @device_uid, hostname: "core-sw-01"})
    event_id = "snmp-anomaly-1"

    {:ok, lv, html} = live(conn, ~p"/events/#{event_id}")

    assert html =~ "Anomaly detection finding"
    assert html =~ "Affected device"
    assert html =~ "ifIndex 4"
    assert html =~ "ifHCInOctets"
    assert html =~ "Metric context"
    assert html =~ "Vertical marker is this event time"

    assert has_element?(lv, "a[href='#{~p"/devices/#{@device_uid}"}']", "View device")
    assert has_element?(lv, "a[href='#{~p"/devices/#{@device_uid}?tab=interfaces"}']", "Interfaces")
    assert has_element?(lv, "a[href='#{~p"/devices/#{@device_uid}?tab=interfaces"}']", "SNMP metrics")
    assert has_element?(lv, "a[href='#{~p"/devices/#{@device_uid}?tab=interfaces"}']", "SNMP metrics for interface")

    # Wait for async panels: a synchronous render() missed the crash when
    # metric_panels became non-empty.
    html_after = render_async(lv, 5_000)
    assert html_after =~ "Metric context"
    refute html_after =~ "Failed to load metric context"
    assert html_after =~ "event-anomaly-metric-0"
    assert html_after =~ ~s(data-timezone="America/Chicago")
  end

  defmodule EventShowSRQLStub do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    @device_uid "sr:5bf1b6f6-0e7c-43ac-b883-a13447199d85"

    def query(query) when is_binary(query), do: query(query, %{})

    @impl true
    def query(query, _opts) when is_binary(query) do
      cond do
        String.contains?(query, "in:logs") ->
          {:ok, %{"results" => [], "pagination" => %{}, "error" => nil}}

        String.contains?(query, "in:snmp_metrics") ->
          {:ok, %{"results" => snmp_metric_rows(), "pagination" => %{}, "error" => nil}}

        String.contains?(query, "in:events") and String.contains?(query, "no-device") ->
          {:ok, %{"results" => [non_device_event()], "pagination" => %{}, "error" => nil}}

        String.contains?(query, "in:events") and String.contains?(query, "snmp-anomaly-1") ->
          {:ok, %{"results" => [snmp_anomaly_event()], "pagination" => %{}, "error" => nil}}

        String.contains?(query, "in:events") and String.contains?(query, "capacity-forecast-1") ->
          {:ok, %{"results" => [capacity_forecast_event()], "pagination" => %{}, "error" => nil}}

        String.contains?(query, "in:events") ->
          {:ok, %{"results" => [proxmox_event()], "pagination" => %{}, "error" => nil}}

        true ->
          {:ok, %{"results" => [], "pagination" => %{}, "error" => nil}}
      end
    end

    def query(_query, _opts), do: {:error, :invalid_query}

    @impl true
    def query_request(%{"query" => query}) when is_binary(query), do: query(query, %{})
    def query_request(_payload), do: {:error, :invalid_request}

    defp proxmox_event do
      %{
        "id" => "00000000-0000-0000-0000-0000000009a1",
        "time" => "2026-07-04T12:00:00Z",
        "updated_at" => "2026-07-04T12:30:00Z",
        "severity" => "Critical",
        "log_provider" => "serviceradar-plugin",
        "message" => "Proxmox guest memory bottleneck 95%",
        "raw_data" => %{
          "event_time" => "2026-07-04T12:01:00Z",
          "observed_at" => "2026-07-04T12:02:00Z",
          "created_at" => "2026-07-04T12:03:00Z",
          "expires_at" => "2026-07-04T12:04:00Z",
          "timestamp" => "2026-07-04T12:07:00Z",
          "logged_time" => "2026-07-04T12:06:30",
          "note" => "2026-07-04T12:06:00Z"
        },
        "metadata" => %{
          "logged_time" => "2026-07-04T12:05:00Z",
          "service_radar" => %{
            "signal_schema" => %{
              "producer_id" => "proxmox-inventory",
              "producer_version" => "0.1.1",
              "schema_id" => "com.carverauto.proxmox.resource_event",
              "schema_version" => "1.0.0"
            }
          }
        },
        "unmapped" => %{
          "condition_key" => "proxmox:guest_memory:#{@device_uid}:qemu:116"
        }
      }
    end

    defp non_device_event do
      %{
        "id" => "no-device",
        "time" => "2026-07-04T12:00:00Z",
        "severity" => "Info",
        "log_provider" => "ns03",
        "message" => "RPZ blocked suspicious.example",
        "unmapped" => %{"condition_key" => "powerdns:rpz:suspicious.example"}
      }
    end

    defp snmp_anomaly_event do
      series_key =
        Enum.join(
          [
            "v2",
            component("partition", "demo"),
            component("class", "snmp"),
            component("family", "interface"),
            component("identity", @device_uid),
            component("if_index", "4"),
            component("metric", "ifHCInOctets"),
            tag_component("label", "Gi0/1")
          ],
          ":"
        )

      %{
        "id" => "snmp-anomaly-1",
        "time" => "2026-07-04T12:00:00Z",
        "severity" => "High",
        "log_provider" => "anomaly_detection",
        "message" => "Anomalous SNMP interface traffic on Gi0/1",
        "metadata" => %{
          "service_radar" => %{"source_type" => "anomaly_detection"},
          "detection_finding" => %{
            "type" => "anomaly",
            "series_key" => series_key,
            "metric_name" => "ifHCInOctets",
            "metric_class" => "snmp/interface",
            "state" => "open",
            "score" => "4.2",
            "reason" => "rate spike above baseline"
          },
          "finding_info" => %{
            "title" => "SNMP interface rate anomaly",
            "uid" => "finding-snmp-1"
          }
        }
      }
    end

    defp capacity_forecast_event do
      %{
        "id" => "capacity-forecast-1",
        "time" => "2026-08-30T18:00:00Z",
        "severity" => "High",
        "log_provider" => "capacity_forecasting",
        "message" => "Disk capacity forecast",
        "unmapped" => %{
          "event_type" => "capacity_forecast",
          "capacity_forecast" => %{
            "resource_label" => "disk /data",
            "metric_name" => "disk_used_percent",
            "status" => "projected",
            "projected_exhaustion_at" => "2026-08-30T18:45:00Z"
          }
        }
      }
    end

    defp snmp_metric_rows do
      [
        %{
          "timestamp" => "2026-07-04T11:00:00Z",
          "metric_name" => "ifHCInOctets",
          "value" => 1000.0,
          "if_index" => 4,
          "device_id" => @device_uid
        },
        %{
          "timestamp" => "2026-07-04T12:00:00Z",
          "metric_name" => "ifHCInOctets",
          "value" => 9000.0,
          "if_index" => 4,
          "device_id" => @device_uid
        },
        %{
          "timestamp" => "2026-07-04T13:00:00Z",
          "metric_name" => "ifHCInOctets",
          "value" => 1200.0,
          "if_index" => 4,
          "device_id" => @device_uid
        }
      ]
    end

    defp component(name, value), do: "#{name}=#{hex(value)}"
    defp tag_component(name, value), do: "tag_#{hex(name)}=#{hex(value)}"
    defp hex(value), do: value |> to_string() |> Base.encode16(case: :lower)
  end
end
