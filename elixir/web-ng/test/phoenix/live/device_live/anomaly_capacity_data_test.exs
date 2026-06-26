defmodule ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityDataTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityData

  @moduletag :db_free

  setup do
    if !Process.whereis(ServiceRadarWebNG.TaskSupervisor) do
      start_supervised!({Task.Supervisor, name: ServiceRadarWebNG.TaskSupervisor})
    end

    previous_pid = Application.get_env(:serviceradar_web_ng, :anomaly_capacity_data_test_pid)
    Application.put_env(:serviceradar_web_ng, :anomaly_capacity_data_test_pid, self())

    on_exit(fn ->
      restore_env(:anomaly_capacity_data_test_pid, previous_pid)
    end)

    :ok
  end

  defmodule FakeSRQL do
    @moduledoc false

    def query("in:events" <> _rest = query, _opts) do
      send(test_pid(), {:fake_query, query})

      if String.contains?(query, "stats:") do
        {:ok, %{"results" => [%{"total" => 1}]}}
      else
        {:ok,
         %{
           "results" => [
             %{
               "metric_class" => "cpu",
               "status" => "active",
               "time" => "2026-06-19T00:00:00Z"
             }
           ]
         }}
      end
    end

    def query("in:capacity_forecasts" <> _rest = query, _opts) do
      send(test_pid(), {:fake_query, query})
      {:ok, %{"results" => []}}
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_web_ng, :anomaly_capacity_data_test_pid)
    end
  end

  defmodule SNMPSRQL do
    @moduledoc false

    def query("in:events" <> _rest = query, _opts) do
      send(test_pid(), {:fake_query, query})

      if String.contains?(query, "stats:") do
        {:ok, %{"results" => [%{"total" => 1}]}}
      else
        {:ok,
         %{
           "results" => [
             %{
               "metric_class" => "snmp.if_octets",
               "status" => "active",
               "time" => "2026-06-19T00:00:00Z"
             }
           ]
         }}
      end
    end

    def query("in:capacity_forecasts" <> _rest = query, _opts) do
      send(test_pid(), {:fake_query, query})
      {:ok, %{"results" => []}}
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_web_ng, :anomaly_capacity_data_test_pid)
    end
  end

  defmodule NoFallbackSRQL do
    @moduledoc false

    def query("in:events" <> _rest = query, _opts) do
      send(test_pid(), {:fake_query, query})

      if String.contains?(query, "stats:") do
        {:ok, %{"results" => [%{"total" => 0}]}}
      else
        cond do
          String.contains?(query, ~s|service_radar_device_uid:"router-1"|) ->
            {:ok, %{"results" => []}}

          String.contains?(query, "agent_id:") or String.contains?(query, "host_id:") ->
            {:ok,
             %{
               "results" => [
                 %{
                   "metric_class" => "cpu",
                   "status" => "active",
                   "message" => "agent-scoped row must not leak into the device panel"
                 }
               ]
             }}

          true ->
            {:ok, %{"results" => []}}
        end
      end
    end

    def query("in:capacity_forecasts" <> _rest = query, _opts) do
      send(test_pid(), {:fake_query, query})
      {:ok, %{"results" => []}}
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_web_ng, :anomaly_capacity_data_test_pid)
    end
  end

  defmodule ProjectingSRQL do
    @moduledoc false

    def query("in:events" <> _rest = query, _opts) do
      send(test_pid(), {:fake_query, query})

      if String.contains?(query, "stats:") do
        send(test_pid(), {:count_query, query})
        {:ok, %{"results" => [%{"total" => 23}]}}
      else
        {:ok,
         %{
           "results" => [
             %{
               "id" => "event-1",
               "time" => "2026-06-19T00:00:00Z",
               "message" => "fallback message",
               "severity" => "High",
               "metric_name" => "cpu.usage_percent",
               "metric_value" => 97.5,
               "metadata" => %{
                 "finding_info" => %{"title" => "Nested title", "uid" => "finding-1"},
                 "service_radar" => %{
                   "effective_severity" => "warning",
                   "metric_class" => "cpu",
                   "peak_value" => 99.1,
                   "status" => "suppressed",
                   "series_key" => "partition:agent:cpu0",
                   "window_started_at" => "2026-06-18T23:55:00Z",
                   "window_ended_at" => "2026-06-19T00:05:00Z"
                 },
                 "anomaly" => %{
                   "disposition" => "acknowledged",
                   "reason" => "Maintenance window",
                   "score" => 4.2,
                   "threshold_value" => 90.0
                 }
               },
               "source_device_uid" => "router-1",
               "raw_data" => %{"metric_class" => "disk"},
               "unmapped" => %{"metric_class" => "memory"},
               "large_payload" => String.duplicate("x", 512)
             }
           ]
         }}
      end
    end

    def query("in:capacity_forecasts" <> _rest = query, _opts) do
      send(test_pid(), {:fake_query, query})
      send(test_pid(), {:capacity_query, query})

      {:ok,
       %{
         "results" => [
           %{
             "resource_label" => "Filesystem /",
             "resource_key" => "disk:/",
             "resource_id" => "router-1",
             "resource_type" => "disk",
             "metric_name" => "disk.used_percent",
             "metric_class" => "disk",
             "status" => "projected",
             "model" => "holt_winters",
             "sample_count" => 168,
             "forecasted_at" => "2026-06-19T00:00:00Z",
             "current_value" => 72.5,
             "projected_value" => 91.2,
             "projected_exhaustion_at" => "2026-06-20T00:00:00Z",
             "exhaustion_threshold" => 95.0,
             "confidence" => 0.82,
             "lower_bound" => 88.1,
             "upper_bound" => 93.4,
             "metadata" => %{"forecast_value_unit" => "percent"},
             "horizon_seconds" => 604_800,
             "horizon_ends_at" => "2026-06-26T00:00:00Z"
           },
           %{
             "resource_label" => "Impossible disk projection",
             "resource_key" => "disk:/bad",
             "resource_id" => "router-1",
             "resource_type" => "disk",
             "metric_name" => "disk.used_percent",
             "metric_class" => "disk",
             "status" => "projected",
             "forecasted_at" => "2026-06-19T00:00:00Z",
             "current_value" => 72.5,
             "projected_value" => 163.46,
             "projected_exhaustion_at" => "2026-06-20T00:00:00Z",
             "exhaustion_threshold" => 80.0,
             "metadata" => %{"forecast_value_unit" => "percent"}
           }
         ]
       }}
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_web_ng, :anomaly_capacity_data_test_pid)
    end
  end

  defmodule RaisingSRQL do
    @moduledoc false

    def query("in:events" <> _rest, _opts), do: raise("boom")
    def query("in:capacity_forecasts" <> _rest, _opts), do: {:ok, %{"results" => []}}
  end

  defmodule BlockingSRQL do
    @moduledoc false

    def query("in:events" <> _rest = query, _opts) do
      send(test_pid(), {:anomaly_query_started, query, self()})

      if String.contains?(query, "stats:") do
        {:ok, %{"results" => [%{"total" => 0}]}}
      else
        receive do
          :release_anomaly_query -> {:ok, %{"results" => []}}
        after
          2_000 -> {:error, :test_timeout}
        end
      end
    end

    def query("in:capacity_forecasts" <> _rest = query, _opts) do
      send(test_pid(), {:capacity_query_started, query, self()})
      {:ok, %{"results" => []}}
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_web_ng, :anomaly_capacity_data_test_pid)
    end
  end

  test "uses indexed device identity filters before agent and host fallbacks" do
    data = AnomalyCapacityData.load(FakeSRQL, %{device_uid: "router-1"}, nil)

    cpu = Enum.find(data.metric_statuses, &(&1.class == "cpu"))
    red = Enum.find(data.metric_statuses, &(&1.class == "red"))

    assert data.anomaly_filter == %{
             field: "service_radar_device_uid",
             label: "device",
             value: "router-1"
           }

    assert data.capacity_filter == %{field: "resource_id", label: "device", value: "router-1"}
    assert data.anomaly_query =~ ~s|service_radar_device_uid:"router-1"|
    assert data.capacity_query =~ ~s|resource_id:"router-1"|
    refute data.capacity_query =~ "resource_key:"
    refute data.anomaly_query =~ "agent_id:"
    refute data.anomaly_query =~ "host_id:"

    queries = drain_fake_queries()

    assert Enum.any?(queries, &String.contains?(&1, ~s|service_radar_device_uid:"router-1"|))
    assert Enum.any?(queries, &String.contains?(&1, ~s|resource_id:"router-1"|))
    assert cpu.status == "active"
    assert cpu.count == 1
    assert red.status == "normal"
    assert red.count == 0
  end

  test "SNMP metric subclasses are grouped into the SNMP anomaly status bucket" do
    data = AnomalyCapacityData.load(SNMPSRQL, %{device_uid: "router-1"}, nil)

    snmp = Enum.find(data.metric_statuses, &(&1.class == "snmp"))
    red = Enum.find(data.metric_statuses, &(&1.class == "red"))

    assert snmp.status == "active"
    assert snmp.count == 1
    assert red.status == "normal"
    assert red.count == 0
  end

  test "does not fall back to agent or host scoped anomaly findings when the canonical device has no rows" do
    data =
      AnomalyCapacityData.load(
        NoFallbackSRQL,
        %{device_uid: "router-1", agent_id: "agent-1", host_id: "router-host"},
        nil
      )

    queries = drain_fake_queries()
    anomaly_queries = Enum.filter(queries, &String.contains?(&1, "in:events"))

    assert data.anomaly_rows == []

    assert data.anomaly_filter == %{
             field: "service_radar_device_uid",
             label: "device",
             value: "router-1"
           }

    assert Enum.any?(
             anomaly_queries,
             &String.contains?(&1, ~s|service_radar_device_uid:"router-1"|)
           )

    refute Enum.any?(anomaly_queries, &String.contains?(&1, "agent_id:"))
    refute Enum.any?(anomaly_queries, &String.contains?(&1, "host_id:"))
  end

  test "limits queries and keeps only rendered anomaly and capacity fields" do
    data = AnomalyCapacityData.load(ProjectingSRQL, %{device_uid: "router-1"}, nil)

    anomaly_row = List.first(data.anomaly_rows)
    capacity_row = List.first(data.capacity_rows)

    assert length(data.capacity_rows) == 1

    assert anomaly_row == %{
             "id" => "event-1",
             "finding_uid" => "finding-1",
             "time" => "2026-06-19T00:00:00Z",
             "finding_title" => "Nested title",
             "message" => "fallback message",
             "metric_class" => "cpu",
             "metric_name" => "cpu.usage_percent",
             "metric_value" => 97.5,
             "peak_value" => 99.1,
             "threshold_value" => 90.0,
             "score" => 4.2,
             "window_started_at" => "2026-06-18T23:55:00Z",
             "window_ended_at" => "2026-06-19T00:05:00Z",
             "series_key" => "partition:agent:cpu0",
             "device_label" => "router-1",
             "severity" => "High",
             "effective_severity" => "warning",
             "disposition" => "acknowledged",
             "reason" => "Maintenance window",
             "status" => "suppressed"
           }

    assert capacity_row == %{
             "forecasted_at" => "2026-06-19T00:00:00Z",
             "resource_type" => "disk",
             "resource_label" => "Filesystem /",
             "resource_key" => "disk:/",
             "resource_id" => "router-1",
             "metric_name" => "disk.used_percent",
             "metric_class" => "disk",
             "value_unit" => "percent",
             "status" => "projected",
             "model" => "holt_winters",
             "sample_count" => 168,
             "horizon_seconds" => 604_800,
             "horizon_ends_at" => "2026-06-26T00:00:00Z",
             "current_value" => 72.5,
             "projected_value" => 91.2,
             "projected_exhaustion_at" => "2026-06-20T00:00:00Z",
             "exhaustion_threshold" => 95.0,
             "confidence" => 0.82,
             "lower_bound" => 88.1,
             "upper_bound" => 93.4
           }

    queries =
      for _ <- 1..2 do
        assert_receive {:fake_query, query}
        query
      end

    assert Enum.any?(queries, &(String.contains?(&1, "in:events") and not String.contains?(&1, "limit:")))
    assert data.anomaly_pagination["limit"] == 5
    assert data.anomaly_pagination["total_count"] == 23
    assert data.anomaly_pagination["page_count"] == 5
    assert_received {:count_query, _count_query}

    assert_received {:capacity_query, capacity_query}
    assert capacity_query =~ "time:last_24h"
    assert capacity_query =~ "limit:12"
  end

  test "applies cursor pagination options and anomaly filters to the SRQL query" do
    data =
      AnomalyCapacityData.load(ProjectingSRQL, %{device_uid: "router-1"}, nil,
        anomaly_cursor: "cursor-1",
        anomaly_severity: "high",
        anomaly_status: "open",
        anomaly_sort: "oldest"
      )

    queries = drain_fake_queries()
    anomaly_query = Enum.find(queries, &String.contains?(&1, "in:events"))

    assert data.anomaly_pagination["limit"] == 5
    refute anomaly_query =~ "limit:"
    assert anomaly_query =~ "severity:High"
    assert anomaly_query =~ "status:(active,open,anomaly_open)"
    assert anomaly_query =~ "sort:time:asc"

    assert_received {:count_query, count_query}
    assert count_query =~ "severity:High"
    assert count_query =~ "status:(active,open,anomaly_open)"
    refute count_query =~ "sort:"
  end

  test "SRQL task crashes return an error result without raising" do
    {data, log} =
      with_log(fn ->
        AnomalyCapacityData.load(RaisingSRQL, %{device_uid: "router-1"}, nil)
      end)

    assert data.status == :error
    assert data.anomaly_rows == []
    assert data.anomaly_error =~ "anomaly SRQL task failed"
    assert log =~ "anomaly SRQL task failed"
  end

  test "runs anomaly and capacity queries concurrently" do
    load_task =
      Task.async(fn ->
        AnomalyCapacityData.load(BlockingSRQL, %{device_uid: "router-1"}, nil)
      end)

    assert_receive {:anomaly_query_started, anomaly_query, anomaly_pid}
    assert anomaly_query =~ ~s|service_radar_device_uid:"router-1"|

    assert_receive {:capacity_query_started, capacity_query, _capacity_pid}
    assert capacity_query =~ ~s|resource_id:"router-1"|
    refute capacity_query =~ "resource_key:"

    send(anomaly_pid, :release_anomaly_query)
    assert %{status: :ok} = Task.await(load_task, 1_000)
  end

  defp drain_fake_queries(acc \\ []) do
    receive do
      {:fake_query, query} -> drain_fake_queries([query | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
