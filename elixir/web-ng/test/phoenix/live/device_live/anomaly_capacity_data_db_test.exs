defmodule ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityDataDBTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityData

  setup do
    if !Process.whereis(ServiceRadarWebNG.TaskSupervisor) do
      start_supervised!({Task.Supervisor, name: ServiceRadarWebNG.TaskSupervisor})
    end

    previous_pid = Application.get_env(:serviceradar_web_ng, :anomaly_capacity_data_db_test_pid)
    previous_source = Application.get_env(:serviceradar_web_ng, :anomaly_capacity_anomaly_source)
    Application.put_env(:serviceradar_web_ng, :anomaly_capacity_data_db_test_pid, self())
    Application.put_env(:serviceradar_web_ng, :anomaly_capacity_anomaly_source, :ash)

    on_exit(fn ->
      restore_env(:anomaly_capacity_data_db_test_pid, previous_pid)
      restore_env(:anomaly_capacity_anomaly_source, previous_source)
    end)

    :ok
  end

  defmodule CapacityOnlySRQL do
    @moduledoc false

    def query("in:capacity_forecasts" <> _rest = query, _opts) do
      send(test_pid(), {:capacity_query, query})
      {:ok, %{"results" => []}}
    end

    def query("in:events" <> _rest = query, _opts) do
      raise "device anomaly panel must read anomaly_episodes, not raw events: #{query}"
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_web_ng, :anomaly_capacity_data_db_test_pid)
    end
  end

  test "loads device anomaly rows from platform.anomaly_episodes through Ash" do
    insert_episode!(
      episode_uid: "episode-db-1",
      finding_uid: "finding-db-1",
      device_uid: "router-1",
      series_key: "v2|partition|cpu|router-1",
      metric_name: "cpu.usage_percent",
      metric_class: "cpu",
      detector: "spike",
      status: "open",
      severity_id: 4,
      peak_severity_id: 4,
      effect_size: 8.5,
      peak_score: 9.2,
      opened_at: ~U[2026-07-04 12:00:00.000000Z],
      last_seen_at: ~U[2026-07-04 12:05:00.000000Z],
      occurrence_count: 3,
      reopen_count: 0,
      producer_version: "0.2.0-test",
      last_transition: "open",
      last_payload: %{
        "message" => "host CPU saturation episode",
        "finding_title" => "Host CPU saturation",
        "reason" => "breach confirmed after 5/5 consecutive anomalous slots",
        "anomaly_disposition" => %{"action" => "escalate"},
        "metadata" => %{"source_identity" => %{"tag_label" => "host"}}
      }
    )

    insert_episode!(
      episode_uid: "episode-db-other-device",
      finding_uid: "finding-db-other-device",
      device_uid: "router-2",
      series_key: "v2|partition|cpu|router-2",
      metric_name: "cpu.usage_percent",
      metric_class: "cpu",
      detector: "spike",
      status: "open",
      severity_id: 4,
      peak_severity_id: 4,
      opened_at: ~U[2026-07-04 12:00:00.000000Z],
      last_seen_at: ~U[2026-07-04 12:06:00.000000Z],
      occurrence_count: 1,
      reopen_count: 0,
      last_payload: %{"message" => "other device row must not render"}
    )

    scope = Scope.for_user(%{id: "viewer-1", email: "viewer@example.test", role: :viewer})

    data =
      AnomalyCapacityData.load(CapacityOnlySRQL, %{device_uid: "router-1"}, scope, anomaly_source: :ash)

    assert_receive {:capacity_query, capacity_query}
    assert capacity_query =~ ~s|resource_id:"router-1"|

    assert data.status == :ok
    assert data.anomaly_filter == %{field: "service_radar_device_uid", label: "device", value: "router-1"}
    assert data.anomaly_query =~ "finding_rollup:health"
    assert data.anomaly_query =~ ~s|service_radar_device_uid:"router-1"|

    assert [row] = data.anomaly_rows

    assert Map.take(row, [
             "episode_uid",
             "finding_uid",
             "id",
             "finding_title",
             "metric_class",
             "metric_name",
             "series_key",
             "severity",
             "status",
             "state",
             "message",
             "reason",
             "score",
             "anomaly_disposition"
           ]) == %{
             "episode_uid" => "episode-db-1",
             "finding_uid" => "finding-db-1",
             "id" => "episode-db-1",
             "finding_title" => "Host CPU saturation",
             "metric_class" => "cpu",
             "metric_name" => "cpu.usage_percent",
             "series_key" => "v2|partition|cpu|router-1",
             "severity" => "High",
             "status" => "open",
             "state" => "confirmed",
             "message" => "breach confirmed after 5/5 consecutive anomalous slots",
             "reason" => "breach confirmed after 5/5 consecutive anomalous slots",
             "score" => 9.2,
             "anomaly_disposition" => %{"action" => "escalate"}
           }

    cpu = Enum.find(data.metric_statuses, &(&1.class == "cpu"))
    assert cpu.status == "confirmed"
    assert cpu.count == 1
  end

  test "projects cleared episode resolution separately from its opening trigger" do
    insert_episode!(
      episode_uid: "episode-db-cleared",
      finding_uid: "finding-db-cleared",
      device_uid: "router-cleared",
      series_key: "v2|partition|interface|router-cleared|ifindex=3",
      metric_name: "ifOutUcastPkts",
      metric_class: "interface",
      detector: "drift",
      status: "cleared",
      severity_id: 2,
      peak_severity_id: 4,
      peak_score: 7.5,
      opened_at: ~U[2026-07-18 08:30:00.000000Z],
      last_seen_at: ~U[2026-07-18 08:36:00.000000Z],
      cleared_at: ~U[2026-07-18 08:36:00.000000Z],
      clear_reason: "anomaly cleared: flap merged",
      occurrence_count: 2,
      reopen_count: 1,
      last_transition: "clear",
      last_payload: %{
        "finding_title" => "Interface packet-rate anomaly",
        "reason" => "breach confirmed after 5/5 consecutive anomalous slots"
      }
    )

    scope = Scope.for_user(%{id: "viewer-1", email: "viewer@example.test", role: :viewer})

    data =
      AnomalyCapacityData.load(
        CapacityOnlySRQL,
        %{device_uid: "router-cleared"},
        scope,
        anomaly_source: :ash
      )

    assert [row] = data.anomaly_rows
    assert row["state"] == "cleared"
    assert row["message"] == "anomaly cleared: flap merged"
    assert row["reason"] == "anomaly cleared: flap merged"
    assert row["resolution_reason"] == "anomaly cleared: flap merged"
    assert row["opening_reason"] == "breach confirmed after 5/5 consecutive anomalous slots"
  end

  defp insert_episode!(attrs) do
    defaults = [
      effect_size: nil,
      peak_score: nil,
      if_index: nil,
      cleared_at: nil,
      clear_reason: nil,
      producer_version: nil,
      last_transition: nil,
      last_payload: %{}
    ]

    attrs = Keyword.merge(defaults, attrs)

    Repo.query!(
      """
      INSERT INTO platform.anomaly_episodes (
        episode_uid,
        finding_uid,
        device_uid,
        series_key,
        metric_name,
        if_index,
        metric_class,
        detector,
        status,
        severity_id,
        peak_severity_id,
        effect_size,
        peak_score,
        opened_at,
        last_seen_at,
        cleared_at,
        clear_reason,
        occurrence_count,
        reopen_count,
        producer_version,
        last_transition,
        last_payload
      ) VALUES (
        $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11,
        $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22::jsonb
      )
      """,
      [
        attrs[:episode_uid],
        attrs[:finding_uid],
        attrs[:device_uid],
        attrs[:series_key],
        attrs[:metric_name],
        attrs[:if_index],
        attrs[:metric_class],
        attrs[:detector],
        attrs[:status],
        attrs[:severity_id],
        attrs[:peak_severity_id],
        attrs[:effect_size],
        attrs[:peak_score],
        attrs[:opened_at],
        attrs[:last_seen_at],
        attrs[:cleared_at],
        attrs[:clear_reason],
        attrs[:occurrence_count],
        attrs[:reopen_count],
        attrs[:producer_version],
        attrs[:last_transition],
        attrs[:last_payload]
      ]
    )
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
