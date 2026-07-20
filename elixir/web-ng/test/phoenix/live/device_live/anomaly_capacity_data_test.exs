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
    previous_source = Application.get_env(:serviceradar_web_ng, :anomaly_capacity_anomaly_source)
    Application.put_env(:serviceradar_web_ng, :anomaly_capacity_data_test_pid, self())
    Application.put_env(:serviceradar_web_ng, :anomaly_capacity_anomaly_source, :legacy_srql)

    on_exit(fn ->
      restore_env(:anomaly_capacity_data_test_pid, previous_pid)
      restore_env(:anomaly_capacity_anomaly_source, previous_source)
    end)

    :ok
  end

  defmodule FakeSRQL do
    @moduledoc false

    def query("in:events" <> _rest = query, _opts) do
      send(test_pid(), {:fake_query, query})

      {:ok,
       %{
         "results" => [
           %{
             "metric_class" => "cpu",
             "status" => "active",
             "time" => "2026-06-19T00:00:00Z",
             "anomaly_disposition" => %{"action" => "escalate"}
           }
         ]
       }}
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

      cond do
        String.contains?(query, ~s|service_radar_device_uid:"router-1"|) ->
          {:ok, %{"results" => []}}

        String.contains?(query, ~s|service_radar_device_uid:"router-host"|) ->
          {:ok, %{"results" => []}}

        String.contains?(query, ~s|service_radar_device_uid:"agent-1"|) or
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

    def query("in:capacity_forecasts" <> _rest = query, _opts) do
      send(test_pid(), {:fake_query, query})
      {:ok, %{"results" => []}}
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_web_ng, :anomaly_capacity_data_test_pid)
    end
  end

  defmodule PendingOnlySRQL do
    @moduledoc false

    def query("in:events" <> _rest = query, _opts) do
      send(test_pid(), {:fake_query, query})

      {:ok,
       %{
         "results" => [
           %{
             "metric_class" => "cpu",
             "severity" => "High",
             "time" => "2026-06-19T00:00:00Z",
             "message" => "breach pending confirmation at 1/5 consecutive anomalous slots",
             "metadata" => %{
               "finding_info" => %{
                 "dimensions" => %{
                   "state" => "pending_anomaly",
                   "episode_peak_value" => 29.3
                 }
               }
             }
           },
           %{
             "metric_class" => "cpu",
             "severity" => "High",
             "time" => "2026-06-19T00:05:00Z",
             "message" => "breach pending confirmation at 2/5 consecutive anomalous slots",
             "raw_data" => %{"anomaly" => %{"state" => "pending_confirmation"}}
           }
         ]
       }}
    end

    def query("in:capacity_forecasts" <> _rest = query, _opts) do
      send(test_pid(), {:fake_query, query})
      {:ok, %{"results" => []}}
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_web_ng, :anomaly_capacity_data_test_pid)
    end
  end

  defmodule CPUDispositionSRQL do
    @moduledoc false

    def query("in:events" <> _rest = query, _opts) do
      send(test_pid(), {:fake_query, query})

      {:ok,
       %{
         "results" => [
           %{
             "metric_class" => "cpu",
             "status" => "active",
             "severity" => "High",
             "time" => "2026-06-19T00:00:00Z",
             "message" => "undispositioned CPU finding stays visible"
           },
           %{
             "metric_class" => "cpu",
             "status" => "active",
             "severity" => "High",
             "time" => "2026-06-19T00:02:00Z",
             "message" => "explicitly routed CPU finding stays hidden",
             "anomaly_disposition" => %{"action" => "observe"}
           },
           %{
             "metric_class" => "cpu",
             "status" => "active",
             "severity" => "High",
             "time" => "2026-06-19T00:03:00Z",
             "message" => "suppressed CPU finding stays hidden",
             "anomaly_disposition" => %{"action" => "suppress"}
           },
           %{
             "metric_class" => "memory",
             "status" => "active",
             "severity" => "High",
             "time" => "2026-06-19T00:05:00Z",
             "message" => "non-CPU active finding remains visible"
           }
         ]
       }}
    end

    def query("in:capacity_forecasts" <> _rest = query, _opts) do
      send(test_pid(), {:fake_query, query})
      {:ok, %{"results" => []}}
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_web_ng, :anomaly_capacity_data_test_pid)
    end
  end

  defmodule HostAliasSRQL do
    @moduledoc false

    def query("in:events" <> _rest = query, _opts) do
      send(test_pid(), {:fake_query, query})

      cond do
        String.contains?(query, ~s|service_radar_device_uid:"sr-device-1"|) ->
          {:ok, %{"results" => []}}

        String.contains?(query, ~s|service_radar_device_uid:"k8s-cp3-worker1"|) ->
          {:ok,
           %{
             "results" => [
               %{
                 "id" => "worker-anomaly-1",
                 "metric_class" => "cpu",
                 "severity" => "High",
                 "status" => "open",
                 "anomaly_disposition" => %{"action" => "escalate"},
                 "message" => "breach confirmed after 5/5 consecutive anomalous slots",
                 "time" => "2026-06-27T00:07:02Z"
               }
             ]
           }}

        String.contains?(query, ~s|service_radar_device_uid:"agent-k8s-cp3-worker1"|) or
            String.contains?(query, "agent_id:") ->
          {:ok,
           %{
             "results" => [
               %{
                 "metric_class" => "snmp",
                 "status" => "open",
                 "message" => "agent scoped row must not leak into this device"
               }
             ]
           }}

        true ->
          {:ok, %{"results" => []}}
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

      {:ok,
       %{
         "results" => [
           %{
             "id" => "event-1",
             "time" => "2026-06-19T00:00:00Z",
             "message" => "fallback message",
             "severity" => "High",
             "metric_name" => "cpu.usage_percent",
             "metadata" => %{
               "finding_info" => %{
                 "title" => "Nested title",
                 "uid" => "finding-1",
                 "dimensions" => %{"sample_value" => 97.5}
               },
               "service_radar" => %{
                 "metric_class" => "cpu",
                 "status" => "suppressed",
                 "series_key" => "partition:agent:cpu0",
                 "anomaly_disposition" => %{
                   "action" => "escalate",
                   "seasonal_disposition" => "seasonal_breach",
                   "seasonal_status" => "breach",
                   "seasonal_score" => 4.8,
                   "seasonal_window_started_at" => "2026-06-19T00:00:00Z",
                   "seasonal_window_ended_at" => "2026-06-19T01:00:00Z",
                   "seasonal_evaluated_at" => "2026-06-19T01:05:00Z",
                   "reason" => "central_seasonal_breach"
                 }
               },
               "anomaly" => %{
                 "score" => 4.2,
                 "threshold_value" => 90.0,
                 "consecutive_anomalous" => 8,
                 "episode_started_at_unix_nano" => 1_718_755_200_000_000_000,
                 "episode_peak_at_unix_nano" => 1_718_755_440_000_000_000,
                 "episode_peak_value" => 97.5,
                 "observed_at_unix_nano" => 1_718_755_560_000_000_000,
                 "signals" => [
                   %{
                     "name" => "rolling_baseline",
                     "enabled" => true,
                     "ready" => true,
                     "breached" => true,
                     "score" => 4.2,
                     "threshold" => 3.0,
                     "sample_count" => 300,
                     "mean" => 12.0,
                     "stddev" => 2.0,
                     "reason" => "rolling_baseline z-score 4.200 breached 3.000"
                   }
                 ]
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

    def query("in:capacity_forecasts" <> _rest = query, _opts) do
      send(test_pid(), {:fake_query, query})

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
             "resource_label" => "Filesystem / older run",
             "resource_key" => "disk:/",
             "resource_id" => "router-1",
             "resource_type" => "disk",
             "metric_name" => "disk.used_percent",
             "metric_class" => "disk",
             "status" => "projected",
             "model" => "holt_winters",
             "sample_count" => 150,
             "forecasted_at" => "2026-06-18T00:00:00Z",
             "current_value" => 70.0,
             "projected_value" => 88.0,
             "projected_exhaustion_at" => "2026-06-21T00:00:00Z",
             "exhaustion_threshold" => 95.0,
             "confidence" => 0.8,
             "lower_bound" => 84.1,
             "upper_bound" => 91.4,
             "metadata" => %{"forecast_value_unit" => "percent"},
             "horizon_seconds" => 604_800,
             "horizon_ends_at" => "2026-06-25T00:00:00Z"
           },
           %{
             "resource_label" => "Memory outside horizon",
             "resource_key" => "memory:host",
             "resource_id" => "router-1",
             "resource_type" => "memory",
             "metric_name" => "memory.used_percent",
             "metric_class" => "memory",
             "status" => "projected",
             "model" => "linear",
             "sample_count" => 168,
             "forecasted_at" => "2026-06-19T00:00:00Z",
             "current_value" => 3.4,
             "projected_value" => 17.8,
             "projected_exhaustion_at" => "2028-03-06T23:53:27Z",
             "exhaustion_threshold" => 100.0,
             "confidence" => 0.95,
             "lower_bound" => 16.1,
             "upper_bound" => 19.4,
             "metadata" => %{"forecast_value_unit" => "percent"},
             "horizon_seconds" => 7_776_000,
             "horizon_ends_at" => "2026-10-03T00:00:00Z"
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

      receive do
        :release_anomaly_query -> {:ok, %{"results" => []}}
      after
        2_000 -> {:error, :test_timeout}
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

  defmodule EpisodeSource do
    @moduledoc false

    def load(_srql_module, %{value: value} = candidate, _scope, opts) do
      send(test_pid(), {:episode_source_query, candidate, opts})

      {:ok,
       %{
         query: ~s|in:anomaly_episodes device_uid:"#{value}" sort:last_seen_at:desc|,
         pagination: %{"next_cursor" => "offset:5", "limit" => 5},
         rows: [
           %{
             "episode_uid" => "episode-1",
             "finding_uid" => "finding-1",
             "metric_class" => "cpu",
             "metric_name" => "cpu.usage_percent",
             "series_key" => "v2|partition|cpu",
             "status" => "open",
             "state" => "confirmed",
             "severity" => "High",
             "time" => "2026-07-04T12:00:00Z",
             "message" => "host CPU saturation episode",
             "anomaly_disposition" => %{"action" => "escalate"}
           }
         ]
       }}
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_web_ng, :anomaly_capacity_data_test_pid)
    end
  end

  test "uses indexed device identity filters before agent and host fallbacks" do
    data = AnomalyCapacityData.load(FakeSRQL, %{device_uid: "router-1"}, nil)

    cpu = Enum.find(data.metric_statuses, &(&1.class == "cpu"))
    other = Enum.find(data.metric_statuses, &(&1.class == "other"))

    assert data.anomaly_filter == %{
             field: "service_radar_device_uid",
             label: "device",
             value: "router-1"
           }

    assert data.capacity_filter == %{field: "resource_id", label: "device", value: "router-1"}
    assert data.anomaly_query =~ ~s|service_radar_device_uid:"router-1"|
    assert data.capacity_query =~ ~s|resource_id:"router-1"|
    assert data.capacity_query =~ "status:projected"
    refute data.capacity_query =~ "at_risk"
    refute data.capacity_query =~ "exhaustion_projected"
    refute data.capacity_query =~ "resource_key:"
    refute data.anomaly_query =~ "agent_id:"
    refute data.anomaly_query =~ "host_id:"

    queries =
      for _ <- 1..2 do
        assert_receive {:fake_query, query}
        query
      end

    assert Enum.any?(queries, &String.contains?(&1, ~s|service_radar_device_uid:"router-1"|))
    assert Enum.any?(queries, &String.contains?(&1, ~s|resource_id:"router-1"|))
    assert cpu.status == "active"
    assert cpu.count == 1
    assert other.status == "normal"
    assert other.count == 0
  end

  test "loads anomaly rows from bounded episode source instead of raw event SRQL" do
    data =
      AnomalyCapacityData.load(FakeSRQL, %{device_uid: "router-1"}, nil, anomaly_source: EpisodeSource)

    assert_receive {:episode_source_query, %{field: "service_radar_device_uid", value: "router-1"}, opts}
    assert Keyword.get(opts, :limit) == 5

    queries = drain_fake_queries()
    refute Enum.any?(queries, &String.contains?(&1, "in:events"))
    assert Enum.any?(queries, &String.contains?(&1, "in:capacity_forecasts"))

    assert data.anomaly_query == ~s|in:anomaly_episodes device_uid:"router-1" sort:last_seen_at:desc|
    assert data.anomaly_pagination["next_cursor"] == "offset:5"
    assert [%{"episode_uid" => "episode-1", "metric_class" => "cpu", "severity" => "High"}] = data.anomaly_rows

    cpu = Enum.find(data.metric_statuses, &(&1.class == "cpu"))
    assert cpu.status == "confirmed"
    assert cpu.count == 1
  end

  test "episode projection overrides stale payload lifecycle fields" do
    source = fn _srql_module, _candidate, _scope, _opts ->
      {:ok,
       %{
         query: "in:anomaly_episodes",
         pagination: %{},
         rows: [
           %{
             "episode_uid" => "episode-stale-payload",
             "finding_uid" => "finding-stale-payload",
             "device_uid" => "router-1",
             "metric_class" => "cpu",
             "metric_name" => "cpu.usage_percent",
             "series_key" => "sr:router-1|cpu.usage_percent",
             "status" => "open",
             "severity_id" => 4,
             "peak_severity_id" => 4,
             "opened_at" => ~U[2026-07-04 12:00:00Z],
             "last_seen_at" => ~U[2026-07-04 12:10:00Z],
             "last_payload" => %{
               "anomaly" => %{
                 "state" => "anomaly_clear",
                 "status" => "inactive",
                 "reason" => "stale clear"
               }
             }
           }
         ]
       }}
    end

    data = AnomalyCapacityData.load(FakeSRQL, %{device_uid: "router-1"}, nil, anomaly_source: source)

    assert [row] = data.anomaly_rows
    assert row["status"] == "open"
    assert row["state"] == "confirmed"
  end

  test "SNMP metric subclasses are grouped into the SNMP anomaly status bucket" do
    data = AnomalyCapacityData.load(SNMPSRQL, %{device_uid: "router-1"}, nil)

    snmp = Enum.find(data.metric_statuses, &(&1.class == "snmp"))
    other = Enum.find(data.metric_statuses, &(&1.class == "other"))

    assert snmp.status == "active"
    assert snmp.count == 1
    assert other.status == "normal"
    assert other.count == 0
  end

  test "does not fall back to agent scoped anomaly findings when canonical and host aliases have no rows" do
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

    assert Enum.any?(
             anomaly_queries,
             &String.contains?(&1, ~s|service_radar_device_uid:"router-host"|)
           )

    refute Enum.any?(anomaly_queries, &String.contains?(&1, "agent_id:"))
    refute Enum.any?(anomaly_queries, &String.contains?(&1, "host_id:"))
    refute Enum.any?(anomaly_queries, &String.contains?(&1, ~s|service_radar_device_uid:"agent-1"|))
  end

  test "uses host service_radar_device_uid alias for sysmon anomalies when canonical device rows are absent" do
    data =
      AnomalyCapacityData.load(
        HostAliasSRQL,
        %{
          device_uid: "sr-device-1",
          agent_id: "agent-k8s-cp3-worker1",
          host_id: "k8s-cp3-worker1"
        },
        nil,
        anomaly_severity: "high"
      )

    queries = drain_fake_queries()
    anomaly_queries = Enum.filter(queries, &String.contains?(&1, "in:events"))

    assert data.anomaly_filter == %{
             field: "service_radar_device_uid",
             label: "host",
             value: "k8s-cp3-worker1"
           }

    assert [%{"id" => "worker-anomaly-1", "severity" => "High"}] = data.anomaly_rows

    assert Enum.any?(
             anomaly_queries,
             &String.contains?(&1, ~s|service_radar_device_uid:"sr-device-1"|)
           )

    assert Enum.any?(
             anomaly_queries,
             &String.contains?(&1, ~s|service_radar_device_uid:"k8s-cp3-worker1"|)
           )

    refute Enum.any?(anomaly_queries, &String.contains?(&1, ~s|service_radar_device_uid:"agent-k8s-cp3-worker1"|))
    refute Enum.any?(anomaly_queries, &String.contains?(&1, "agent_id:"))
  end

  test "hides pending edge spike warmup rows from the operator list and status cards" do
    data = AnomalyCapacityData.load(PendingOnlySRQL, %{device_uid: "router-1"}, nil)

    cpu = Enum.find(data.metric_statuses, &(&1.class == "cpu"))

    assert data.anomaly_rows == []
    assert data.anomaly_filter == %{field: "service_radar_device_uid", label: "device", value: "router-1"}
    assert cpu.status == "normal"
    assert cpu.count == 0

    queries = drain_fake_queries()
    assert Enum.any?(queries, &String.contains?(&1, ~s|service_radar_device_uid:"router-1"|))
  end

  test "shows CPU findings without a persisted disposition and hides explicitly routed ones" do
    data = AnomalyCapacityData.load(CPUDispositionSRQL, %{device_uid: "router-1"}, nil)

    cpu = Enum.find(data.metric_statuses, &(&1.class == "cpu"))
    memory = Enum.find(data.metric_statuses, &(&1.class == "memory"))

    assert Enum.map(data.anomaly_rows, & &1["message"]) == [
             "undispositioned CPU finding stays visible",
             "non-CPU active finding remains visible"
           ]

    assert cpu.status == "active"
    assert cpu.count == 1
    assert memory.status == "active"
    assert memory.count == 1
  end

  test "limits queries and keeps only rendered anomaly and capacity fields" do
    data = AnomalyCapacityData.load(ProjectingSRQL, %{device_uid: "router-1"}, nil)

    anomaly_row = List.first(data.anomaly_rows)
    capacity_row = List.first(data.capacity_rows)

    assert length(data.capacity_rows) == 1
    assert data.capacity_query =~ "sort:forecasted_at:desc"
    refute Enum.any?(data.capacity_rows, &(&1["resource_key"] == "memory:host"))

    assert anomaly_row == %{
             "id" => "event-1",
             "finding_uid" => "finding-1",
             "time" => "2026-06-19T00:00:00Z",
             "finding_title" => "Nested title",
             "message" => "fallback message",
             "metric_class" => "cpu",
             "metric_name" => "cpu.usage_percent",
             "metric_value" => 97.5,
             "sample_value" => 97.5,
             "threshold_value" => 90.0,
             "score" => 4.2,
             "series_key" => "partition:agent:cpu0",
             "device_label" => "router-1",
             "severity" => "High",
             "status" => "suppressed",
             "anomaly_disposition" => %{
               "action" => "escalate",
               "seasonal_disposition" => "seasonal_breach",
               "seasonal_status" => "breach",
               "seasonal_score" => 4.8,
               "seasonal_window_started_at" => "2026-06-19T00:00:00Z",
               "seasonal_window_ended_at" => "2026-06-19T01:00:00Z",
               "seasonal_evaluated_at" => "2026-06-19T01:05:00Z",
               "reason" => "central_seasonal_breach"
             },
             "consecutive_anomalous" => 8,
             "episode_started_at_unix_nano" => 1_718_755_200_000_000_000,
             "episode_peak_at_unix_nano" => 1_718_755_440_000_000_000,
             "episode_peak_value" => 97.5,
             "observed_at_unix_nano" => 1_718_755_560_000_000_000,
             "reason" => "fallback message",
             "signals" => [
               %{
                 "name" => "rolling_baseline",
                 "enabled" => true,
                 "ready" => true,
                 "breached" => true,
                 "score" => 4.2,
                 "threshold" => 3.0,
                 "sample_count" => 300,
                 "mean" => 12.0,
                 "stddev" => 2.0,
                 "reason" => "rolling_baseline z-score 4.200 breached 3.000"
               }
             ]
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

    assert Enum.any?(queries, &(String.contains?(&1, "in:events") and String.contains?(&1, "limit:5")))

    assert Enum.any?(
             queries,
             &(String.contains?(&1, "in:capacity_forecasts") and
                 String.contains?(&1, "time:last_24h") and String.contains?(&1, "limit:12"))
           )
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

  test "cleared episode projection prioritizes resolution without losing its opening trigger" do
    row =
      AnomalyCapacityData.project_episode(%{
        episode_uid: "episode-cleared-1",
        finding_uid: "finding-cleared-1",
        device_uid: "router-1",
        series_key: "v2|partition|interface|router-1|ifindex=3",
        metric_name: "ifOutUcastPkts",
        metric_class: "interface",
        detector: "drift",
        status: "cleared",
        severity_id: 2,
        peak_severity_id: 4,
        peak_score: 7.5,
        opened_at: ~U[2026-07-18 08:30:00Z],
        last_seen_at: ~U[2026-07-18 08:36:00Z],
        cleared_at: ~U[2026-07-18 08:36:00Z],
        clear_reason: "anomaly cleared: flap merged",
        occurrence_count: 2,
        reopen_count: 1,
        last_transition: "clear",
        last_payload: %{
          "finding_title" => "Interface packet-rate anomaly",
          "reason" => "breach confirmed after 5/5 consecutive anomalous slots"
        }
      })

    assert row["state"] == "cleared"
    assert row["message"] == "anomaly cleared: flap merged"
    assert row["reason"] == "anomaly cleared: flap merged"
    assert row["resolution_reason"] == "anomaly cleared: flap merged"
    assert row["opening_reason"] == "breach confirmed after 5/5 consecutive anomalous slots"
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
      0 -> Enum.reverse(acc)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
