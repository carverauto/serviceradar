defmodule ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityDataTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityData

  @moduletag :db_free

  setup do
    start_supervised!({Task.Supervisor, name: ServiceRadarWebNG.TaskSupervisor})

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

    def query("in:capacity_forecasts" <> _rest = query, _opts) do
      send(test_pid(), {:fake_query, query})
      {:ok, %{"results" => []}}
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

  test "uses indexed device identity filters before agent and host fallbacks" do
    data = AnomalyCapacityData.load(FakeSRQL, %{device_uid: "router-1"}, nil)

    cpu = Enum.find(data.metric_statuses, &(&1.class == "cpu"))
    red = Enum.find(data.metric_statuses, &(&1.class == "red"))

    assert data.anomaly_filter == %{field: "device_uid_exact", label: "device", value: "router-1"}
    assert data.capacity_filter == %{field: "resource_id", label: "device", value: "router-1"}
    assert data.anomaly_query =~ ~s|device_uid_exact:"router-1"|
    assert data.capacity_query =~ ~s|resource_id:"router-1"|
    refute data.capacity_query =~ "resource_key:"
    refute data.anomaly_query =~ "agent_id:"
    refute data.anomaly_query =~ "host_id:"

    queries =
      for _ <- 1..2 do
        assert_receive {:fake_query, query}
        query
      end

    assert Enum.any?(queries, &String.contains?(&1, ~s|device_uid_exact:"router-1"|))
    assert Enum.any?(queries, &String.contains?(&1, ~s|resource_id:"router-1"|))
    assert cpu.status == "active"
    assert cpu.count == 1
    assert red.status == "normal"
    assert red.count == 0
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
    assert anomaly_query =~ ~s|device_uid_exact:"router-1"|

    assert_receive {:capacity_query_started, capacity_query, _capacity_pid}
    assert capacity_query =~ ~s|resource_id:"router-1"|
    refute capacity_query =~ "resource_key:"

    send(anomaly_pid, :release_anomaly_query)
    assert %{status: :ok} = Task.await(load_task, 1_000)
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
